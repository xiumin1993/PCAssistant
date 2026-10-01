package com.pcspeaker.pc_speaker.camera

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.nio.ByteBuffer

/**
 * MediaCodec 硬件编码器（H.264 / H.265）—— 走 ByteBuffer 输入，不走 Surface。
 *
 * ### 为什么用 ByteBuffer 而不是 Surface
 * 常见做法是给编码器一块 Surface，让相机画面经 EGL 直接画进去。那样确实更"零拷贝"，
 * 但它要求相机输出也走 Surface —— 而我们【同时】还要：
 *   · 把画面送给 Flutter 的预览纹理（v3.11 起就是 GPU 直通，预览不解码）；
 *   · 拿到 NV21 字节流做 JPEG 兜底编码。
 * 走 Surface 就得把相机画面在 GPU 上分支两次（多一套 EGL 上下文与 blit 程序，
 * 约 150~250 行 GL 代码，且老设备的 GL 行为差异很难兜）。
 * 走 ByteBuffer 则完全不动预览链路：相机照旧给 NV21，我们转成 NV12 喂给编码器。
 * 代价是一次 NV21→NV12 的遍历（NEON 一次 32 字节，1280×720 实测个位数毫秒），
 * 换来的是预览零风险 + 代码量小一个数量级。
 *
 * ### 为什么设成【全 I 帧】（每帧都是关键帧）
 *   · 延迟最低：编码器不需要攒够一个 GOP 才能出帧；
 *   · 抗丢帧：实时流中间帧本来就会被丢（邮箱只留最新一帧），有帧间依赖的话
 *     丢一帧会让后面几帧跟着解错，全 I 帧则每帧独立，下一帧立刻恢复；
 *   · PC 端正好配合：vcodec.rs 每帧新建一个解码器（无状态），
 *     前提是每帧自带参数集 —— 所以下面每个输出帧前面都会拼上 SPS/PPS。
 *
 * ### 线程
 * MediaCodec 实例不是线程安全的，输入必须串行。调用方（FramePipeline）负责
 * 用【单线程】调 offer()，不要丢进并行线程池 —— 那是给 JPEG 路径用的。
 */
internal class VideoEncoder {
    private val tag = "CamEncoder"

    private var codec: MediaCodec? = null
    private var info = MediaCodec.BufferInfo()

    /**
     * 参数集（H.264 的 SPS/PPS，H.265 的 VPS/SPS/PPS）。
     * 编码器会在开流时单独给一次（带 CODEC_CONFIG 标志），之后每个关键帧
     * 都要跟着它 —— 因为 PC 端是每帧新建解码器的，缺了参数集就解不出画面。
     * 参数集只有几十字节，每帧带上很便宜。
     */
    @Volatile
    private var configBytes: ByteArray? = null

    private var ptsUs = 0L
    private val frameUs: Long get() = 1_000_000L / fps.coerceAtLeast(1)
    private var fps = 24

    @Volatile
    private var running = false

    /**
     * 起编码器。返回 null = 成功；返回字符串 = 错误原因（调用方据此回退 JPEG）。
     */
    fun start(
        codec: VideoCodec, width: Int, height: Int, fps: Int, colorFormat: Int
    ): String? {
        val mime = codec.mime ?: return "NO_MIME"
        if (width <= 0 || height <= 0) return "BAD_SIZE"
        this.fps = fps

        val bitrate = VideoCodecCaps.bitrateFor(width, height, fps)
        val fmt = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 全 I 帧，理由见类注释
            // 低延迟模式（Android 11+）：让编码器尽早吐帧而不是攒着优化
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                } catch (_: Exception) {
                }
            }
        }
        VideoCodecCaps.probeColorAspects(fmt)

        return try {
            val c = MediaCodec.createEncoderByType(mime)
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            this.codec = c
            this.configBytes = null
            this.ptsUs = 0L
            this.running = true
            Log.i(
                tag,
                "硬件编码器就绪 ${codec.name} ${width}x${height}@${fps} " +
                    "bitrate=${bitrate / 1000}kbps 全I帧 color=$colorFormat"
            )
            null
        } catch (e: Exception) {
            this.running = false
            Log.w(tag, "硬件编码器启动失败 ${codec.name}: ${e.message}")
            "START_FAILED"
        }
    }

    /**
     * 喂一帧 NV12，取回编码后的码流。
     *
     * @param nv12 直接缓冲，position=0、limit=帧大小（Y 平面 + 交错的 UV）
     * @return 这一帧的码流（已拼好参数集）；null = 这一轮没有输出
     *         （编码器还在预热，或参数集还没到 —— 都不算错误，下一帧再来）
     */
    fun offer(nv12: ByteBuffer, size: Int): ByteArray? {
        val c = codec ?: return null
        if (!running) return null

        // ── 1. 输入：拿不到空位就直接放弃这一帧 ──────────────────────
        // 实时流的规矩：宁可丢帧也绝不排队等待（排队 = 延迟越堆越高）。
        val inIdx = try {
            c.dequeueInputBuffer(0)
        } catch (_: Exception) {
            return null
        }
        if (inIdx < 0) return null
        val inBuf = try {
            c.getInputBuffer(inIdx)
        } catch (_: Exception) {
            null
        }
        if (inBuf == null) return null
        try {
            inBuf.clear()
            val src = nv12.duplicate()
            src.position(0)
            src.limit(size)
            inBuf.put(src)
            c.queueInputBuffer(inIdx, 0, size, ptsUs, 0)
            ptsUs += frameUs
        } catch (_: Exception) {
            return null
        }

        // ── 2. 输出：把这一轮能取到的都取走 ─────────────────────────
        // 硬件编码有 1~2 帧的管线延迟，第一次调用常常什么都拿不到，这很正常。
        // 这里最多等 40ms（一帧预算 41ms），够把刚喂进去的帧逼出来，
        // 又不至于把编码线程卡死。
        var result: ByteArray? = null
        val deadline = System.nanoTime() + 40_000_000L
        while (System.nanoTime() < deadline) {
            val outIdx = try {
                c.dequeueOutputBuffer(info, 5_000)
            } catch (_: Exception) {
                return result
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (result != null) break
                    continue
                }

                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                outIdx < 0 -> continue
            }
            val buf = try {
                c.getOutputBuffer(outIdx)
            } catch (_: Exception) {
                null
            }
            if (buf != null && info.size > 0) {
                val bytes = ByteArray(info.size)
                try {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    buf.get(bytes)
                } catch (_: Exception) {
                    bytes.fill(0)
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    // 参数集：存下来，之后每个输出帧前面都带上
                    configBytes = bytes
                } else {
                    val cfg = configBytes
                    result = if (cfg != null && cfg.isNotEmpty()) {
                        val joined = ByteArray(cfg.size + bytes.size)
                        System.arraycopy(cfg, 0, joined, 0, cfg.size)
                        System.arraycopy(bytes, 0, joined, cfg.size, bytes.size)
                        joined
                    } else {
                        bytes
                    }
                }
            }
            try {
                c.releaseOutputBuffer(outIdx, false)
            } catch (_: Exception) {
            }
            if (result != null) break
        }
        return result
    }

    /** 停编码器并释放。可以重复调用。 */
    fun stop() {
        running = false
        val c = codec ?: return
        codec = null
        try {
            c.stop()
        } catch (_: Exception) {
        }
        try {
            c.release()
        } catch (_: Exception) {
        }
        configBytes = null
    }

    /** 参数集是否已拿到。没拿到之前发上去的帧 PC 端解不出来，先别发。 */
    val hasConfig: Boolean get() = configBytes != null
}
