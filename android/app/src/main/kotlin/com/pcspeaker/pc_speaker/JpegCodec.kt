package com.pcspeaker.pc_speaker

import android.util.Log

/**
 * 原生 JPEG 编码器 —— libjpeg-turbo（带 NEON 加速），JNI 封装。
 *
 * ### 为什么要有它
 * 采集链路里最贵的一步就是把相机给的 NV21 压成 JPEG。Android 自带的
 * `YuvImage.compressToJpeg` 在 720p 上实测要 50~90 ms/帧，A53 上光编码就
 * 吃掉一个核，帧率被编码卡住而不是被相机卡住（相机本身能给到 30 fps）。
 * libjpeg-turbo 的 DCT/Huffman 有 AArch64 NEON 实现，同样画质通常快 3~6 倍。
 *
 * ### 健壮性
 * 这个类是"可选加速"：任何一步失败（so 没打进包、指令集不兼容、自检没过、
 * 编码报错）都返回 null，调用方退回原来的 `YuvImage` 路径。**永远不会因为
 * 引入了原生库而开不了相机** —— 引库是提速，不是加依赖。
 */
object JpegCodec {
    private const val TAG = "JpegCodec"

    @Volatile
    private var available = false

    /** 结果缓存：自检只做一次，失败也不再重试（省得每帧都去抛异常） */
    private var checked = false

    /** 编码失败只提醒一次，不让 24 fps 的日志把 logcat 冲掉 */
    @Volatile
    private var warned = false

    /** 原生自检：编一张 16x16 的图，确认编码器真能出数据。1=可用 */
    private external fun selfTest(): Int

    /**
     * NV21 → JPEG。返回 null 表示这一步没能走原生（调用方请回退）。
     * 宽高必须是偶数（4:2:0 半平面拆分的硬性要求）。
     */
    private external fun encode(nv21: ByteArray, width: Int, height: Int, quality: Int): ByteArray?

    /**
     * NV21 → 带方向标记的 JPEG（帧 = 1 字节方向 + JPEG）。
     *
     * 跟 encode() 的区别只是标记字节由原生直接写进缓冲区头部，Kotlin 侧
     * 就不用再"新建大 1 字节的数组 + 整帧拷一遍"了 —— 720p 一帧约 100 KB，
     * 24 fps 下每秒能省 2.4 MB 的纯拷贝和一次数组分配（GC 压力）。
     */
    private external fun encodeTagged(
        nv21: ByteArray, width: Int, height: Int, quality: Int, orient: Int
    ): ByteArray?

    @Synchronized
    private fun ensure(): Boolean {
        if (checked) return available
        checked = true
        available = try {
            System.loadLibrary("pcspeaker-jpeg")
            selfTest() == 1
        } catch (e: Throwable) {
            Log.w(TAG, "原生编码器不可用，退回 YuvImage：${e.message}")
            false
        }
        Log.i(
            TAG,
            if (available) "原生 JPEG 编码器就绪（libjpeg-turbo + NEON）"
            else "原生 JPEG 编码器不可用，使用 YuvImage 兜底"
        )
        return available
    }

    /**
     * 尝试用原生编码。拿不到结果就返回 null，调用方负责兜底。
     * 故意吞掉所有异常：编码失败最多是慢一点，不该把采集线程搞崩。
     */
    fun tryEncode(nv21: ByteArray, width: Int, height: Int, quality: Int): ByteArray? {
        if (!ensure()) return null
        if (width <= 0 || height <= 0) return null
        // 4:2:0 的色度半平面要求宽高都是偶数，奇数尺寸原生侧直接拒绝
        if (width and 1 != 0 || height and 1 != 0) return null
        return try {
            encode(nv21, width, height, quality)
        } catch (e: Throwable) {
            warnOnce(e)
            null
        }
    }

    /**
     * 同上，但产出的是**已经带好方向标记**的帧（协议格式：1 字节方向 + JPEG）。
     * 采集热路径应该用这个：省掉 Kotlin 侧再套一层 withOrientTag 的整帧拷贝。
     */
    fun tryEncodeTagged(
        nv21: ByteArray, width: Int, height: Int, quality: Int, orient: Int
    ): ByteArray? {
        if (!ensure()) return null
        if (width <= 0 || height <= 0) return null
        if (width and 1 != 0 || height and 1 != 0) return null
        return try {
            encodeTagged(nv21, width, height, quality, orient)
        } catch (e: Throwable) {
            warnOnce(e)
            null
        }
    }

    private fun warnOnce(e: Throwable) {
        // 只报一次就够，否则 24 fps 下会把 logcat 刷爆
        if (!warned) {
            warned = true
            Log.w(TAG, "原生编码失败，改用 YuvImage：${e.message}")
        }
    }
}
