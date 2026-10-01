package com.pcspeaker.pc_speaker.camera

import android.content.Context
import android.view.Surface
import android.view.WindowManager

/**
 * CameraOrientation —— "这一帧该怎么摆正"
 * ----------------------------------------------------------------------------
 * 相机吐出来的画面是【传感器原始朝向】，横竖取决于镜头怎么装、手机怎么拿。
 * 这一坨计算原来散在 CameraEngine 里，与采集、编码混在一起；拆出来之后
 * 采集链路只管出帧，方向是独立的一件事。
 *
 * 【v3.10】手机端【不再做像素级旋转】：这里只算出一个 1 字节标记，
 * 真正的旋转交给 ① PC 端（解码成 RGBA 后做，算力富余）
 * ② 手机自己的预览（Flutter 用 RotatedBox/Transform 走 GPU，同样免费）。
 *
 * 背景：之前每帧在手机上做像素重排（orientInto，实测 27~28ms/帧），
 * 还顺带把画面塞回"横向画布"等比缩放 —— 960×720 旋转后塞回 960×720，
 * 实际内容只剩 540×720，白白丢掉约 44% 的像素。现在只发标记，零成本。
 */
internal class CameraOrientation(
    private val context: Context,
    private val state: CameraState
) {

    /**
     * 手机当前的"持握角度"（0/90/180/270，顺时针）。
     * 从 WindowManager 拿屏幕旋转状态：竖屏=0、向左横躺=90、倒竖=180、向右横躺=270。
     * 拿不到（个别机型/时机）就当竖屏 0，画面顶多转错方向但不会崩。
     */
    fun displayRotationDegrees(): Int {
        return try {
            val rot = (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .defaultDisplay.rotation
            when (rot) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
        } catch (_: Exception) {
            0
        }
    }

    /**
     * 每帧需要"顺时针再转多少度"才是正的。
     * 这是 Android 相机官方公式（Camera2 文档 JPEG_ORIENTATION 一节）：
     *   后置：(传感器安装角 - 持握角 + 360) % 360
     *   前置：(传感器安装角 + 持握角) % 360   ← 前置还要再水平镜像（见下）
     * 例：后置安装角 90、竖屏持握(0) → 需要顺时针转 90°，横拍原图就变竖屏正像。
     */
    fun rotationNeededDegrees(): Int {
        val dev = displayRotationDegrees()
        val auto = if (state.facing == "front")
            (state.sensorOrientation + dev) % 360
        else
            (state.sensorOrientation - dev + 360) % 360
        // v3.4.1：自动摆正之后，再叠加用户手动"旋转90°"的偏移
        return (auto + state.manualRotation) % 360
    }

    /**
     * 生成 1 字节方向标记：
     *   bit0~1 = 需要【顺时针】转几个 90°（0~3）
     *   bit2   = 1 表示还要水平镜像（前置镜头自拍视角）
     */
    fun orientFlags(): Int {
        val q = rotationNeededDegrees() / 90
        return (q and 0x3) or (if (state.facing == "front") 0x4 else 0)
    }

    /**
     * 在 JPEG 前面拼 1 字节方向标记，得到"上行帧载荷"。
     * 布局：[flags][JPEG...] —— Dart 侧在它前面再加 4 字节 CAM 魔术头；
     * 手机预览用 `sublistView(bytes, 1)` 零拷贝地跳过这一字节。
     */
    fun withTag(jpeg: ByteArray): ByteArray {
        // 标记在【编码之后】才取：旋转角会随手机持握方向变，取晚了会滞后一帧。
        val out = ByteArray(jpeg.size + 1)
        out[0] = orientFlags().toByte()
        System.arraycopy(jpeg, 0, out, 1, jpeg.size)
        return out
    }
}
