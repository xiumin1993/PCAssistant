package com.pcspeaker.pc_speaker.camera

/**
 * 上行画面的编码方式。
 *
 * ⚠【跨端协议】这里的 `id` 会写进每一帧的头字节（高 4 位），PC 端
 * `AudioServer/src/vcodec.rs` 里的 CODEC_JPEG / CODEC_H264 / CODEC_H265
 * 必须与它逐一对齐，改任一端的编号而另一端不跟 = 画面直接解不出来。
 *
 * 排序即「清晰度优先级」：HEVC > AVC > JPEG。自动选档就从前往后找第一个
 * 硬件真支持的（见 VideoCodecCaps）。JPEG 永远垫底 —— 它是软件编码，
 * 任何设备都能跑，是最后的兜底。
 */
internal enum class VideoCodec(
    /** 写进帧头高 4 位的编号（与 PC 端 vcodec.rs 对齐） */
    val id: Int,
    /** MediaCodec 的 MIME；null = 不走 MediaCodec（JPEG 由 libjpeg-turbo 编） */
    val mime: String?
) {
    /** MJPEG：每帧独立压缩，兼容性最好，但同码率下画质最差、体积最大 */
    JPEG(0, null),

    /** H.264/AVC：硬件编码，同画质比 MJPEG 省 2~3 倍码率 */
    H264(1, "video/avc"),

    /** H.265/HEVC：硬件编码，比 H.264 再省 30~50%；只有较新的 SoC 有编码器 */
    H265(2, "video/hevc");

    companion object {
        /** 按帧头里解出来的编号反查；未知编号一律当 JPEG（最保守的解法） */
        fun of(id: Int): VideoCodec = entries.firstOrNull { it.id == id } ?: JPEG
    }
}

/**
 * 一帧上行数据的头部构造。
 *
 * 帧布局（WebSocket Binary 帧去掉 4 字节 "CAM" 魔术头之后）：
 * ```text
 * [0]  (codec.id << 4) | orient
 * [1..] 编码数据
 * ```
 * orient 的语义没变：bit0~1 = 顺时针 90° 次数，bit2 = 水平镜像。
 *
 * 之所以能不动老协议就扩展：老手机发的是裸 JPEG，第 0 字节是 JPEG 自己的
 * SOI(0xFF)；我们自己的头字节里 orient 只取 0~7、codec 只取 0~2，
 * 凑出来永远不等于 0xFF —— PC 端靠"首字节是不是 FF"就能分辨新旧包。
 */
internal object FrameHeader {
    /** 拼出头字节。orient 只允许 0~7（bit0~2），多的位会被掩掉。 */
    fun byte(codec: VideoCodec, orient: Int): Byte =
        ((codec.id shl 4) or (orient and 0x0F)).toByte()

    /** 把头字节套到数据前面（用于硬件编码器：它吐出的码流不带我们的头） */
    fun wrap(codec: VideoCodec, orient: Int, body: ByteArray): ByteArray {
        val out = ByteArray(body.size + 1)
        out[0] = byte(codec, orient)
        System.arraycopy(body, 0, out, 1, body.size)
        return out
    }
}
