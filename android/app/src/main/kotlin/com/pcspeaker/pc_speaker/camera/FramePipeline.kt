package com.pcspeaker.pc_speaker.camera

import android.media.Image
import com.pcspeaker.pc_speaker.JpegCodec
import java.nio.ByteBuffer
import java.util.TreeMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * FramePipeline —— 从"相机送来一帧"到"一帧编码数据发给 Flutter"之间的全部工序
 * ----------------------------------------------------------------------------
 * 它把几件事收在一处，两条采集路径（Camera1 / Camera2）共用：
 *
 *   1. 车道管理：最多 N 帧同时在飞，满了就丢帧 ——
 *      宁可跳帧也绝不排队（排队 = 越堆越高的延迟，实时流的大忌）。
 *   2. 编码线程池：压缩不在采集线程上做，避免拖慢取帧。
 *   3. 保序输出：并行后完成顺序会乱，直接发会出现"画面回跳"，这里排回原序。
 *   4. 编码方式：JPEG 走多核并行，H.264/H.265 走硬件编码器（必须串行）。
 *   5. 性能统计：每 2 秒一行 CamPerf。
 *
 * 采集侧只需要三句话：满了没？→ 占车道提交 → 完事归还相机缓冲。
 */
internal class FramePipeline(
    /** 每帧的方向标记由它提供（编码之后才取，见 CameraOrientation.withTag） */
    private val orientation: CameraOrientation
) {

    private val stats = FrameStats()

    /**
     * 【v3.8.2】JPEG 编码线程池。
     * 原来是「单线程 + jpegBusy 互斥门」——不管这台机有多少核，一次只跑 1 帧，
     * 一帧 82ms 期间其余核全在睡觉，实测吞吐只有 6fps。
     * 现在改成 PIPELINE_WORKERS 路并行（核数的一半，见 CameraConfig）：
     * 单帧耗时不变但吞吐 ×N（帧与帧之间没有数据依赖，天然可并行）。
     */
    private val executor: ExecutorService =
        Executors.newFixedThreadPool(CameraConfig.ACTIVE_WORKERS)

    /**
     * 【v3.16】硬件编码专用线程：单线程，必须串行。
     * MediaCodec 实例不是线程安全的，两次 offer() 不能交叠；而且硬件编码器
     * 一条流水线的吞吐本来就够 24fps，排队只会增加延迟，不需要并行。
     */
    private val codecExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 并发门：还在流水线里的帧数。满了才丢帧（保实时、不排队）。 */
    private val inFlight = AtomicInteger(0)

    /** 帧的出口（MainActivity 里转发给 EventChannel）。null = 停止采集后的帧不再发 */
    var consumer: ((ByteArray) -> Unit)? = null

    /** 采集进行中才真正往外发帧（stop() 之后残余帧丢掉，避免"停了还在出画面"） */
    @Volatile
    var enabled = false

    // ── 编码方式（v3.16）──────────────────────────────────────────────
    /** 当前在用的编码方式。默认 JPEG（最保守、任何设备都能跑）。 */
    @Volatile
    var codec: VideoCodec = VideoCodec.JPEG
        private set

    private var encoder: VideoEncoder? = null

    /** 硬件编码的输入缓冲（NV12），按帧大小分配一次后一直复用 */
    private var nv12Buf: ByteBuffer? = null

    // ── 保序输出（v3.8.2）──────────────────────────────────────────
    // 多帧并行后各帧完成时间会有先后差异，直接 onFrame 会出现"画面回跳"。
    // 做法：每帧在采集线程领一个自增序号，完成后进 pending 暂存，
    // 只按序号从小到大的顺序往外发；早到的帧等前面的补齐后再一起发出。
    private val frameSeq = AtomicLong(0)
    private var nextEmitSeq = 0L
    private val pending = TreeMap<Long, ByteArray>()
    private val emitLock = Any()

    /**
     * 流水线是否满了。满了就该丢帧，绝不排队。
     * 硬件编码只有一条串行流水线，在飞 1 帧就够了（多提交也是排队）。
     */
    val saturated: Boolean
        get() = inFlight.get() >= if (codec == VideoCodec.JPEG)
            CameraConfig.ACTIVE_WORKERS else 1

    fun onCallback() = stats.onCallback()
    fun onArrived() = stats.onArrived()
    fun onDropped() = stats.onDropped()

    /**
     * 切换编码方式。返回 null = 成功；非空 = 失败原因（调用方据此回退 JPEG）。
     *
     * 必须在【采集线程之外】调用：MediaCodec 的 start/stop 不能在帧回调里做。
     * 拿不到硬件编码器（设备不支持 / 启动失败）时会自动把 codec 退回 JPEG，
     * 所以调用方只要看返回值决定要不要报给用户，链路本身不会断。
     */
    @Synchronized
    fun useCodec(codec: VideoCodec, width: Int, height: Int, fps: Int): String? {
        encoder?.stop()
        encoder = null
        nv12Buf = null
        this.codec = VideoCodec.JPEG
        if (codec == VideoCodec.JPEG) return null

        val probe = VideoCodecCaps.probe(codec, width, height, fps)
            ?: return "设备不支持 ${codec.name}"
        val enc = VideoEncoder()
        val err = enc.start(codec, width, height, fps, probe.colorFormat)
        if (err != null) {
            enc.stop()
            return "硬件编码器启动失败（$err）"
        }
        encoder = enc
        this.codec = codec
        return null
    }

    /** 停掉硬件编码器（切回 JPEG、停止采集、销毁时都要调） */
    @Synchronized
    fun releaseEncoder() {
        encoder?.stop()
        encoder = null
        nv12Buf = null
        codec = VideoCodec.JPEG
    }

    /**
     * 交一帧 NV21 给流水线（Camera1 路径：HAL 直接给的就是 NV21，连转换都省了）。
     *
     * @param onDone 帧处理完（或失败）后回调，采集侧在这里把缓冲还给相机
     */
    fun submitNv21(nv21: ByteArray, w: Int, h: Int, api: String, onDone: () -> Unit) {
        // 序号必须在这里、在【采集线程】上取：放到工作线程取会乱序，
        // 保序队列就失去意义了。
        val seq = frameSeq.getAndIncrement()
        inFlight.incrementAndGet()
        dispatch(seq, nv21, w, h, api, onDone)
    }

    /**
     * 交一帧 Camera2 的 Image 给流水线。
     *
     * 【v3.8.4】YUV→NV21 这一步特意放在【工作线程】而不是采集回调里：
     * 原来它在 cam-bg 回调线程上【串行】执行，对 960×720 要搬上百万字节 ——
     * 回调线程被占住，相机送帧就被整体拖慢（实测 cam≈11.7fps，而 drop=0、
     * 车道从未占满，慢的正是这一段）。
     */
    fun submitImage(image: Image, api: String, onDone: () -> Unit) {
        val seq = frameSeq.getAndIncrement()
        inFlight.incrementAndGet()
        executor.execute {
            val (w, h) = image.width to image.height
            val nv21 = try {
                val convStartNs = System.nanoTime()
                val buf = YuvConverter.toNv21(image)
                stats.addConv(System.nanoTime() - convStartNs)
                buf
            } catch (_: Exception) {
                null
            }
            if (nv21 == null) {
                // 转换失败：发空帧占位（不然保序队列会永远等这个序号）
                emit(seq, CameraConfig.EMPTY_JPEG)
                onDone()
                inFlight.decrementAndGet()
                return@execute
            }
            // 转换完再决定走哪条编码路径（硬件路径会接力到 codecExecutor）
            dispatch(seq, nv21, w, h, api, onDone)
        }
    }

    /** 按当前编码方式把帧派到对应的线程上 */
    private fun dispatch(
        seq: Long, nv21: ByteArray, w: Int, h: Int, api: String, onDone: () -> Unit
    ) {
        if (codec != VideoCodec.JPEG && encoder != null) {
            codecExecutor.execute { encodeHardware(seq, nv21, w, h, api, onDone) }
        } else {
            executor.execute { encodeJpeg(seq, nv21, w, h, api, onDone) }
        }
    }

    /** JPEG 路径：libjpeg-turbo 软件编码（多核并行） */
    private fun encodeJpeg(
        seq: Long, nv21: ByteArray, w: Int, h: Int, api: String, onDone: () -> Unit
    ) {
        try {
            val startNs = System.nanoTime()
            val jpeg = YuvConverter.nv21ToJpeg(nv21, w, h, CameraConfig.JPEG_QUALITY)
            val endNs = System.nanoTime()
            emit(seq, orientation.withTag(jpeg))
            stats.onFrame(startNs, endNs, w, h, api)
        } catch (_: Exception) {
            // 单帧失败无所谓，但要占位发出去 —— 否则保序队列会永远等这个序号
            emit(seq, CameraConfig.EMPTY_JPEG)
        } finally {
            onDone()
            inFlight.decrementAndGet()
        }
    }

    /**
     * 硬件编码路径：NV21 → NV12 → MediaCodec。
     *
     * 注意相机缓冲的归还时机：一旦 NV12 拷进自有缓冲，相机那块就可以立刻还回去
     * （MediaCodec 有自己的输入缓冲，不会引用它）。这样相机侧不缺缓冲，
     * 不会因为等编码完成而降帧。
     */
    private fun encodeHardware(
        seq: Long, nv21: ByteArray, w: Int, h: Int, api: String, onDone: () -> Unit
    ) {
        var released = false
        try {
            val enc = encoder
            if (enc == null) {
                emit(seq, CameraConfig.EMPTY_JPEG)
                return
            }
            val frameSize = w * h * 3 / 2
            val buf = ensureNv12(frameSize)
            val ok = JpegCodec.tryNv21ToNv12(nv21, buf, w, h)

            // 无论转换成功与否，相机缓冲都不再需要（成功=已拷贝，失败=放弃这帧）
            released = true
            onDone()

            if (!ok) {
                emit(seq, CameraConfig.EMPTY_JPEG)
                return
            }
            val startNs = System.nanoTime()
            val body = enc.offer(buf, frameSize)
            val endNs = System.nanoTime()
            if (body == null) {
                // 编码器还在预热 / 参数集没到 —— 发空帧占位，不能让保序队列卡住。
                // 这不是错误：硬件编码器头几帧就是没输出，下一帧就好了。
                emit(seq, CameraConfig.EMPTY_JPEG)
            } else {
                val out = FrameHeader.wrap(codec, orientation.orientFlags(), body)
                emit(seq, out)
                stats.onFrame(startNs, endNs, w, h, "$api/${codec.name}")
            }
        } catch (_: Exception) {
            emit(seq, CameraConfig.EMPTY_JPEG)
        } finally {
            if (!released) onDone()
            inFlight.decrementAndGet()
        }
    }

    /** 复用同一块直接缓冲给硬件编码器当输入；尺寸变了才重新分配 */
    private fun ensureNv12(size: Int): ByteBuffer {
        var b = nv12Buf
        if (b == null || b.capacity() < size) {
            b = ByteBuffer.allocateDirect(size)
            nv12Buf = b
        }
        return b
    }

    /**
     * 按序号把帧排回原序再发出去。
     * 多帧并行后完成顺序会乱，直接发会出现"画面回跳"；这里让早到的帧
     * 等前面的补齐后一起按顺序发出。
     */
    private fun emit(seq: Long, payload: ByteArray) {
        val toSend = ArrayList<ByteArray>(2)
        synchronized(emitLock) {
            pending[seq] = payload
            while (true) {
                val b = pending.remove(nextEmitSeq) ?: break
                if (b.isNotEmpty()) toSend.add(b) // 空帧=该帧处理失败，跳过不卡队
                nextEmitSeq++
            }
            // 兜底：万一某帧永久丢失（线程被强杀等），队列会越堆越长 → 强制前进
            if (pending.size > 12) {
                pending.clear()
                nextEmitSeq = seq + 1
            }
        }
        if (enabled) for (b in toSend) consumer?.invoke(b)
    }

    /** App 退出时调用：关掉压缩线程池 */
    fun shutdown() {
        executor.shutdownNow()
        codecExecutor.shutdownNow()
        releaseEncoder()
    }
}
