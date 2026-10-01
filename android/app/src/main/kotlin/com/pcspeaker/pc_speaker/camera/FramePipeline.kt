package com.pcspeaker.pc_speaker.camera

import android.media.Image
import java.util.TreeMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * FramePipeline —— 从"相机送来一帧"到"一帧 JPEG 发给 Flutter"之间的全部工序
 * ----------------------------------------------------------------------------
 * 它把四件事收在一处，两条采集路径（Camera1 / Camera2）共用：
 *
 *   1. 车道管理：最多 PIPELINE_WORKERS 帧同时在飞，满了就丢帧 ——
 *      宁可跳帧也绝不排队（排队 = 越堆越高的延迟，实时流的大忌）。
 *   2. 编码线程池：压缩不在采集线程上做，避免拖慢取帧。
 *   3. 保序输出：并行后完成顺序会乱，直接发会出现"画面回跳"，这里排回原序。
 *   4. 性能统计：每 2 秒一行 CamPerf。
 *
 * 采集侧只需要三句话：满了没？→ 占车道提交 → 完事归还相机缓冲。
 */
internal class FramePipeline(
    /** 每帧的方向标记由它提供（编码之后才取，见 CameraOrientation.withTag） */
    private val orientation: CameraOrientation
) {

    private val stats = FrameStats()

    /**
     * 【v3.8.2】帧处理线程池。
     * 原来是「单线程 + jpegBusy 互斥门」——不管这台机有多少核，一次只跑 1 帧，
     * 一帧 82ms 期间其余核全在睡觉，实测吞吐只有 6fps。
     * 现在改成 PIPELINE_WORKERS 路并行（核数的一半，见 CameraConfig）：
     * 单帧耗时不变但吞吐 ×N（帧与帧之间没有数据依赖，天然可并行）。
     */
    private val executor: ExecutorService =
        Executors.newFixedThreadPool(CameraConfig.PIPELINE_WORKERS)

    /** 并发门：还在流水线里的帧数。满了才丢帧（保实时、不排队）。 */
    private val inFlight = AtomicInteger(0)

    /** 帧的出口（MainActivity 里转发给 EventChannel）。null = 停止采集后的帧不再发 */
    var consumer: ((ByteArray) -> Unit)? = null

    /** 采集进行中才真正往外发帧（stop() 之后残余帧丢掉，避免"停了还在出画面"） */
    @Volatile
    var enabled = false

    // ── 保序输出（v3.8.2）──────────────────────────────────────────
    // 多帧并行后各帧完成时间会有先后差异，直接 onFrame 会出现"画面回跳"。
    // 做法：每帧在采集线程领一个自增序号，完成后进 pending 暂存，
    // 只按序号从小到大的顺序往外发；早到的帧等前面的补齐后再一起发出。
    private val frameSeq = AtomicLong(0)
    private var nextEmitSeq = 0L
    private val pending = TreeMap<Long, ByteArray>()
    private val emitLock = Any()

    /** 流水线是否满了。满了就该丢帧，绝不排队。 */
    val saturated: Boolean
        get() = inFlight.get() >= CameraConfig.PIPELINE_WORKERS

    fun onCallback() = stats.onCallback()
    fun onArrived() = stats.onArrived()
    fun onDropped() = stats.onDropped()

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
        executor.execute {
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
            try {
                val convStartNs = System.nanoTime()
                val nv21 = YuvConverter.toNv21(image)
                stats.addConv(System.nanoTime() - convStartNs)

                val startNs = System.nanoTime()
                // 【v3.10】这里【不再】做方向补偿 —— 编码原始朝向的 NV21，
                // 方向通过一个标记字节交给 PC 与手机预览各自处理。
                val jpeg = YuvConverter.nv21ToJpeg(
                    nv21, image.width, image.height, CameraConfig.JPEG_QUALITY
                )
                val endNs = System.nanoTime()
                emit(seq, orientation.withTag(jpeg))
                stats.onFrame(startNs, endNs, image.width, image.height, api)
            } catch (_: Exception) {
                emit(seq, CameraConfig.EMPTY_JPEG)
            } finally {
                // 相机缓冲在工作线程归还同样合法（v3.8.4：拷贝已搬到这里）
                onDone()
                inFlight.decrementAndGet()
            }
        }
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
    }
}
