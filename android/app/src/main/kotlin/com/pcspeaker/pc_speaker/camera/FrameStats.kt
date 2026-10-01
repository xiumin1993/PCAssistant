package com.pcspeaker.pc_speaker.camera

import android.util.Log
import java.util.concurrent.atomic.LongAdder

/** 性能日志用：保留 1 位小数 */
internal fun Double.format1(): String = String.format("%.1f", this)

/**
 * FrameStats —— 采集链路的"仪表盘"，每 2 秒打一行 CamPerf
 * ----------------------------------------------------------------------------
 * 【v3.9】Camera1 与 Camera2 两条路径共用【同一份口径】的日志，
 * 换路径前后直接看同一行数字就知道有没有变快。
 *
 * 多帧并行后这些计数器会被多个线程同时累加 → 统一用 LongAdder
 * （高并发累加比 AtomicLong 更快）。
 */
internal class FrameStats {

    /** 窗口内完成编码的帧数 */
    private val frames = LongAdder()
    /** JPEG 编码累计耗时 */
    private val jpegNs = LongAdder()
    /** 单帧进流水线到出 JPEG 的墙钟耗时 */
    private val totalNs = LongAdder()

    /**
     * 【v3.8.5】onImageAvailable / onPreviewFrame 被回调的【原始次数】
     * （取帧之前就计数）。
     *
     * 它和 arrived 的差值能一锤定音地区分两种完全不同的瓶颈：
     *   · cb ≈ cam ≈ 10fps → 相机 HAL 真的只出 10fps，改我们自己的代码没用；
     *   · cb ≈ 30fps 而 cam ≈ 10fps → 帧在到达时被合并掉了
     *     （回调线程来不及取），瓶颈在回调线程，是代码问题、可修。
     */
    private val cbInvoked = LongAdder()
    /** 相机实际送进流水线的帧数 */
    private val arrived = LongAdder()
    /** 【v3.8.4】YUV→NV21 拷贝累计耗时（Camera1 路径恒为 0：它直接给 NV21） */
    private val convNs = LongAdder()
    /** 因流水线占满而被丢掉的帧数 */
    private val dropped = LongAdder()

    private var lastPrint = 0L
    private val printLock = Any() // 保护 lastPrint（多线程会同时到达）

    fun onCallback() = cbInvoked.increment()
    fun onArrived() = arrived.increment()
    fun onDropped() = dropped.increment()
    fun addConv(ns: Long) = convNs.add(ns)

    /**
     * 记一帧并（可能）打印本窗口的统计行。
     *
     * @param startNs 编码开始时刻
     * @param endNs   编码结束时刻
     * @param api     "C1" / "C2"，用来区分当前跑的是哪条采集路径
     */
    fun onFrame(startNs: Long, endNs: Long, cw: Int, ch: Int, api: String) {
        frames.increment()
        // 【v3.10】方向补偿已迁到 PC 端，手机上不再做像素重排，
        // 所以整帧耗时就是 JPEG 编码耗时 —— 这里留着 total 只为日志口径不变
        //（看到两个值不一样就说明有别的开销混进来了）。
        jpegNs.add(endNs - startNs)
        totalNs.add(endNs - startNs)

        val winNs = synchronized(printLock) {
            if (lastPrint == 0L) {
                lastPrint = endNs; 0L
            } else if (endNs - lastPrint >= 2_000_000_000L) {
                val w = endNs - lastPrint
                lastPrint = endNs
                w
            } else 0L
        }
        if (winNs <= 0L) return

        // out = 真正发出去的帧率；cam = 相机送来的帧率；cb = HAL 叫我们的次数。
        //   · cam≈30 而 out 低  → 我们处理慢（看 jpeg）
        //   · cb≈30 而 cam 低   → 帧在取帧时被合并，回调线程来不及
        //   · cb≈cam≈10         → 相机真的只出 10fps
        val f = frames.sumThenReset().coerceAtLeast(1)
        val winMs = winNs / 1_000_000.0
        val cam = arrived.sumThenReset()
        val drop = dropped.sumThenReset()
        val cb = cbInvoked.sumThenReset()
        Log.i(
            "CamPerf",
            "api=" + api +
                    " out=" + (f * 1000.0 / winMs).format1() + "fps" +
                    " cam=" + (cam * 1000.0 / winMs).format1() + "fps" +
                    " cb=" + (cb * 1000.0 / winMs).format1() + "fps" +
                    " drop=" + drop +
                    " conv=" + (convNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " jpeg=" + (jpegNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " total=" + (totalNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " size=" + cw + "x" + ch
        )
    }
}
