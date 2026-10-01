package com.pcspeaker.pc_speaker.camera

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import com.pcspeaker.pc_speaker.JpegCodec
import java.io.ByteArrayOutputStream

/**
 * YuvConverter —— 像素格式转换 + JPEG 编码
 * ----------------------------------------------------------------------------
 * 采集链路里唯一跟"像素怎么摆"有关的地方，与相机 API（Camera1/Camera2）
 * 完全无关，所以单独拎出来：换采集路径时这段代码一行都不用动。
 */
internal object YuvConverter {

    /**
     * YUV_420_888 → NV21 字节数组。
     *
     * 背景知识：相机给的不是 RGB，而是 YUV（亮度 Y + 色度 U/V），
     * 因为人眼对亮度敏感、对颜色不敏感，YUV 可以省带宽。
     * YUV_420_888 = 每 4 个 Y 共享一对 UV（色度分辨率减半）。
     * NV21 = Android 老标准格式：先整块 Y，再 V/U 交错排成一块。
     * 编码器只认 NV21，所以要做这次"重新摆放字节"。
     *
     * 关键坑：每行像素之间可能有 padding（rowStride > width），
     * 而且行内相邻像素间隔不一定是 1（pixelStride），
     * 必须按步长取字节，不能整块 copyOfRange —— 否则画面错位/绿条。
     */
    fun toNv21(image: Image): ByteArray {
        val w = image.width
        val h = image.height
        val ySize = w * h
        val out = ByteArray(ySize + ySize / 2) // NV21 总大小 = w*h*3/2

        // ── Y 平面 ──
        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer
        val yRowStride = yPlane.rowStride
        if (yRowStride == w && yPlane.pixelStride == 1) {
            // 最快路径：行连续无 padding，整块拷贝
            yBuf.get(out, 0, ySize)
        } else if (yPlane.pixelStride == 1) {
            // v3.8.1：有行 padding 但像素连续 —— 逐行整块拷贝。
            // 原来这里逐字节循环（w*h ≈ 69 万次 JNI 边界读），~15ms/帧；
            // position+bulk get 把 JNI 往返从 69 万次减到 h 次，~2ms/帧。
            var dst = 0
            for (row in 0 until h) {
                yBuf.position(row * yRowStride)
                yBuf.get(out, dst, w)
                dst += w
            }
        } else {
            // 逐像素拷贝（pixelStride≠1 的罕见布局才走）
            var dst = 0
            for (row in 0 until h) {
                for (col in 0 until w) {
                    out[dst++] = yBuf[row * yRowStride + col * yPlane.pixelStride]
                }
            }
        }

        // ── U/V 平面（半分辨率）──
        // NV21 的顺序是 V 在前、U 在后（VU 交错）
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        var dst = ySize
        // 【v3.8.4 关键优化】这里原本在双重循环里直接 vBuf[i] / uBuf[i] 取字节：
        // 960×720 一帧要取 2 × 360 × 480 ≈ 34.5 万次，而 ByteBuffer 每次索引都带
        // 边界检查（direct buffer 还要多走一次 JNI 读），CamPerf 实测 conv≈40ms
        // 几乎全花在这——它是整条流水线里最慢的一段，比 JPEG 压缩还贵。
        // 改法：先【整块 bulk get 到普通 ByteArray】（每个平面仅 1 次调用），
        // 循环体退化成两次纯内存数组寻址，没有 JNI、没有 ByteBuffer 检查。
        // 部分机型 V 平面比 U 平面短一截（奇数尺寸/驱动怪癖），所以长度和下标
        // 都夹住：越界就重复最后一个字节，绝不崩溃（行为与优化前一致）。
        val uvRows = h / 2
        val uvCols = w / 2
        // 最后一个像素的字节下标 + 1 = 这一帧真正需要的字节数
        val need = (uvRows - 1) * uvRowStride + (uvCols - 1) * uvPixelStride + 1
        val uLen = need.coerceAtMost(uBuf.remaining())
        val vLen = need.coerceAtMost(vBuf.remaining())
        val uArr = ByteArray(uLen)
        val vArr = ByteArray(vLen)
        uBuf.get(uArr, 0, uLen)
        vBuf.get(vArr, 0, vLen)
        val uMax = uLen - 1
        val vMax = vLen - 1
        for (row in 0 until uvRows) {
            val rowOff = row * uvRowStride
            for (col in 0 until uvCols) {
                val uvIndex = rowOff + col * uvPixelStride
                out[dst++] = vArr[if (uvIndex > vMax) vMax else uvIndex]
                out[dst++] = uArr[if (uvIndex > uMax) uMax else uvIndex]
            }
        }
        return out
    }

    /**
     * NV21 → JPEG 字节数组。
     *
     * 【v3.13】优先走原生 libjpeg-turbo（NEON 加速，见 JpegCodec 的说明）。
     * 它比下面这条 YuvImage 路径快 3~6 倍 —— 这一步原本是整条采集链路里
     * 最贵的一环（720p 上 50~90 ms/帧），也是帧率上不去的直接原因。
     *
     * 原生拿不到结果（so 缺失 / 自检不过 / 尺寸奇数 / 编码报错）时
     * 一律退回 YuvImage：慢一点，但绝不会因为引了原生库就出不了画面。
     */
    fun nv21ToJpeg(nv21: ByteArray, w: Int, h: Int, quality: Int): ByteArray {
        JpegCodec.tryEncode(nv21, w, h, quality)?.let { return it }

        val yuv = YuvImage(nv21, ImageFormat.NV21, w, h, null)
        val baos = ByteArrayOutputStream(w * h / 4) // 预分配 1/4 面积，减少扩容
        yuv.compressToJpeg(Rect(0, 0, w, h), quality, baos)
        return baos.toByteArray()
    }
}
