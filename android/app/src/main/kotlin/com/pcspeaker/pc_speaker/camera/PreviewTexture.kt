package com.pcspeaker.pc_speaker.camera

import android.graphics.SurfaceTexture
import android.util.Log
import io.flutter.view.TextureRegistry

/**
 * PreviewTexture —— 手机端取景预览用的那块 GPU 纹理
 * ----------------------------------------------------------------------------
 * 【v3.11】预览走"相机 → GPU 纹理 → 屏幕合成"，彻底干掉了
 * "每帧解码一张 JPEG"的老路子：
 *
 *   改之前：HAL → CPU 压 JPEG(51ms) → 传给 Dart → Dart 解码成位图（约 2.7MB）
 *           → 缩放 → 上传纹理 → 下一帧丢弃。
 *           每秒 24 次 × 2.7MB 位图分配，A53 上光解码就吃掉一个核 + GC 抖动。
 *   改之后：HAL → GPU 纹理 → Flutter 光栅化。相机本来就要往某个 Surface 送
 *           预览帧（Camera1 不挂承载根本不出帧），我们只是把那个"丢弃画面的
 *           黑洞"换成 Flutter 注册的纹理 —— 硬件多做的事为零。
 *
 * 方向不在这里处理：纹理里是传感器原始朝向，摆正交给 Dart 的
 * RotatedBox/Transform（GPU 合成，免费），与 PC 端 orient 标记同源。
 */
internal class PreviewTexture(
    private val registry: TextureRegistry?
) {

    /**
     * 已申请的纹理句柄。
     * ⚠ 必须【持有引用】：SurfaceTexture 靠 finalize 释放显存，只 new 出来不存
     * 的话随时可能被 GC 回收 → 相机拿到一块已释放的纹理，表现为"预览跑一会儿
     * 就报错/黑屏"，而且极难复现。
     */
    private var entry: TextureRegistry.SurfaceTextureEntry? = null

    /**
     * 申请一块 Flutter 预览纹理（尺寸按当前实际生效的采集尺寸）。
     * 返回 null 表示"这台机没走纹理通道"，调用方应退回离屏承载
     *（那时预览走 Dart 侧 JPEG 解码的老路径）。
     *
     * 尺寸要用【HAL 回读之后的实际尺寸】：个别机器会把请求的尺寸悄悄改成
     * 它支持的最近一档，纹理缓冲尺寸对不上会造成画面拉伸/裁切。
     */
    fun acquire(w: Int, h: Int): SurfaceTexture? {
        val reg = registry ?: return null
        return try {
            release()
            val e = reg.createSurfaceTexture()
            entry = e
            val st = e.surfaceTexture()
            // 必须显式声明缓冲尺寸：不设的话部分 HAL 会按默认的小尺寸写入，
            // Flutter 端看到的就是一张被拉伸/裁切的画面。
            st.setDefaultBufferSize(w, h)
            Log.i("CamPerf", "预览纹理就绪 id=" + e.id() + " " + w + "x" + h)
            st
        } catch (e: Exception) {
            // 纹理拿不到不是致命错误 —— 预览退回 JPEG 解码路径，采集照常
            Log.w("CamPerf", "预览纹理创建失败，退回 JPEG 预览: " + e)
            release()
            null
        }
    }

    /** 释放纹理（切换镜头/停止采集时调用；已经空了则是空操作） */
    fun release() {
        try {
            entry?.release()
        } catch (_: Exception) {
        }
        entry = null
    }

    /** 纹理 id，交给 Dart 的 `Texture(textureId:)`。null = 没有纹理通道。 */
    fun id(): Long? = entry?.id()
}
