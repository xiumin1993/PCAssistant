package com.pcspeaker.pc_speaker.camera

import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log

/**
 * 问设备："这台机能硬件编码哪些格式？"
 *
 * ### 为什么必须问，不能猜
 * 硬件编码器是 SoC 厂商提供的，能力千差万别：
 *   · 有没有 H.265 编码器，取决于 SoC 年代（2016 年前后的中低端芯片基本没有）；
 *   · 就算有编码器，它接受的输入像素格式也各不相同 —— 我们只能给它 NV12
 *     （半平面 YUV），但有的设备只认别的排布，有的只认"flexible"格式。
 * 所以这里一律用 MediaCodecList 逐项试，绝不写死机型名单或型号前缀
 * （项目铁律：测试机只是测试载体，APP 要跑在任意手机上）。
 *
 * ### 探测怎么做
 * `MediaCodecList.findEncoderForFormat(fmt)` 会拿着一个完整的 MediaFormat
 * 去匹配所有编码器，返回能用的那个的名字；返回 null 就是没人接得住。
 * 它对 color-format 很敏感，所以我们对每个格式遍历候选的输入格式逐个试。
 */
internal object VideoCodecCaps {
    private const val TAG = "CamCaps"

    /** MediaFormat 里"YUV 4:2:0 半平面（NV12）"的标准编号 */
    private const val COLOR_NV12 = MediaCodecInfo_ColorFormat.YUV420SemiPlanar

    /**
     * 候选的输入像素格式，按偏好排序。
     * 只有第一个（NV12 / SemiPlanar）是我们真能零成本喂进去的：
     * 相机给 NV21，把色度交错的 V/U 换成 U/V 就是 NV12 —— 一次 NEON 遍历搞定。
     * 后面的 PackedSemiPlanar / Flexible 排在后面只是"万一有设备只认它"时的备选，
     * 真选到它们的话我们仍按 NV12 的排布喂（flexible 就是这个语义），
     * 实测绝大多数设备第一个就命中。
     */
    private val COLOR_CANDIDATES = intArrayOf(
        COLOR_NV12,                                            // 21
        MediaCodecInfo_ColorFormat.YUV420PackedSemiPlanar,     // 39
        MediaCodecInfo_ColorFormat.YUV420Flexible              // 0x7F420888
    )

    /** 内部小容器：把 MediaCodecInfo 的常量抄一份，省得写超长的限定名 */
    private object MediaCodecInfo_ColorFormat {
        const val YUV420SemiPlanar = 21
        const val YUV420PackedSemiPlanar = 39
        const val YUV420Flexible = 0x7F420888.toInt()
    }

    /** 一次探测的结果：这个格式能用吗、用哪个输入像素格式、哪个编码器 */
    data class Probe(
        val codec: VideoCodec,
        val colorFormat: Int,
        val encoderName: String
    )

    /**
     * 估算码率。"自动选最高清晰度"给的就是这个数。
     *
     * 经验系数 0.25 bit/像素：H.264 高质量动态画面通常 0.1~0.2 就够，
     * 但我们是【全 I 帧】（每帧都当关键帧压，没有帧间压缩可借力），
     * 所以要比常规视频给得更足。1280×720@24fps 算出来约 5.5 Mbps，
     * 局域网 WiFi 完全无压力（改之前 MJPEG quality 90 是 34 Mbps）。
     *
     * 上下限是防异常阀，不是"替设备做主"：2 Mbps 保证再小的画面也不至于糊，
     * 20 Mbps 防止高分辨率高帧率组合把码率顶到 WiFi 扛不住的量级。
     */
    fun bitrateFor(width: Int, height: Int, fps: Int): Int {
        val raw = (width.toLong() * height * fps * 0.25).toLong()
        return raw.coerceIn(2_000_000L, 20_000_000L).toInt()
    }

    /**
     * 探测某个编码格式在给定分辨率/帧率下能不能用。
     * 返回 null = 不可用（设备没这个编码器，或不接受我们的输入格式）。
     */
    fun probe(codec: VideoCodec, width: Int, height: Int, fps: Int): Probe? {
        val mime = codec.mime ?: return null
        if (width <= 0 || height <= 0) return null
        val bitrate = bitrateFor(width, height, fps)

        // findEncoderForFormat 要求 format 里带上它会检查的键，缺一个就可能匹配不上
        for (color in COLOR_CANDIDATES) {
            val fmt = MediaFormat.createVideoFormat(mime, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, color)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                // 全 I 帧：见 VideoEncoder 里的说明（低延迟 + 丢帧可恢复）
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                probeColorAspects(this)
            }
            val name = try {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(fmt)
            } catch (_: Exception) {
                null
            }
            if (name != null) {
                Log.i(TAG, "编码能力 ${codec.name}: 支持 (encoder=$name, color=$color)")
                return Probe(codec, color, name)
            }
        }
        Log.i(TAG, "编码能力 ${codec.name}: 不支持")
        return null
    }

    /**
     * 列出这台机在给定画质下【全部可用】的编码方式，按清晰度优先级排好
     * （H.265 > H.264 > JPEG）。界面下拉框直接用这个列表。
     * JPEG 永远在最后一位 —— 它是软件编码，任何机器都能跑。
     */
    fun available(width: Int, height: Int, fps: Int): List<VideoCodec> {
        val out = ArrayList<VideoCodec>(3)
        if (probe(VideoCodec.H265, width, height, fps) != null) out.add(VideoCodec.H265)
        if (probe(VideoCodec.H264, width, height, fps) != null) out.add(VideoCodec.H264)
        out.add(VideoCodec.JPEG)
        return out
    }

    /**
     * 声明色彩标准是 BT.601 limited range。
     *
     * 为什么写死这个：PC 端 `vcodec.rs` 的 YUV→RGB 用的就是 BT.601
     * limited-range 系数。两边不一致的话，画面整体会偏亮/偏暗（黑不黑、白不白），
     * 而且这种偏差很难一眼看出是"色彩矩阵不对"。
     * 这几个键只是元数据（写进 SPS 的 VUI 里），Android 7.0 以下没有，
     * 没有就不写 —— 不写时编码器按默认处理，而摄像头原始 YUV 本来就是 BT.601，
     * 与 PC 端仍然对得上。
     */
    fun probeColorAspects(fmt: MediaFormat) {
        if (Build.VERSION.SDK_INT < 24) return
        try {
            fmt.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT601_NTSC)
            fmt.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        } catch (_: Exception) {
            // 个别设备不接受这几个键：忽略即可，只是元数据，不影响能不能编
        }
    }
}
