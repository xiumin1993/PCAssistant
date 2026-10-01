package com.pcspeaker.pc_speaker.audio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MicRecorder —— 手机 → PC 的音频采集（手机当麦克风）
 * ----------------------------------------------------------------------------
 * 一个 AudioRecord + 一条读线程。读到的 PCM 通过 [onPcm] 往外送
 * （由调用方决定怎么推给 Flutter：EventChannel 必须在主线程推送）。
 *
 * 音频源用 VOICE_COMMUNICATION（通话模式）：
 *   1. 系统会优先走回声消除（AEC）链路 —— 手机外放 PC 声音的同时
 *      麦克风还能"滤掉"扬声器里的 PC 声，避免啸叫（全双工关键）；
 *   2. 配合显式创建的 AcousticEchoCanceler / NoiseSuppressor 效果器。
 */
class MicRecorder(
    /** 由调用方提供权限判断（录音权限归 Activity 管） */
    private val permissionGranted: () -> Boolean,
    /** 采到一包 PCM 就回调（注意：会在采集线程上调用） */
    private val onPcm: (ByteArray) -> Unit
) {

    private var audioRecord: AudioRecord? = null
    private var micThread: Thread? = null

    /** AtomicBoolean：多线程读写的布尔开关（true = 正在采集） */
    private val running = AtomicBoolean(false)

    val isRunning: Boolean get() = running.get()

    /**
     * 开始采集。返回 null = 成功；返回字符串 = 错误码（Flutter 层翻译成中文提示）。
     */
    fun start(sampleRate: Int, channels: Int): String? {
        if (running.get()) return null // 已在采集，幂等返回成功
        if (!permissionGranted()) return "PERMISSION_DENIED"

        val channelConfig = if (channels == 1) {
            AudioFormat.CHANNEL_IN_MONO
        } else {
            AudioFormat.CHANNEL_IN_STEREO
        }
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) return "BAD_BUFFER"
        // 读块 = 2 倍最小缓冲：48kHz/16bit/mono 下约 10~20ms 一包
        val bufSize = minBuf * 2

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRate,
                channelConfig,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize
            )
        } catch (_: SecurityException) {
            return "PERMISSION_DENIED"
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return "INIT_FAILED"
        }

        // 显式挂上回声消除与降噪（设备支持才创建，不支持静默跳过）
        if (AcousticEchoCanceler.isAvailable()) {
            AcousticEchoCanceler.create(record.audioSessionId)?.enabled = true
        }
        if (NoiseSuppressor.isAvailable()) {
            NoiseSuppressor.create(record.audioSessionId)?.enabled = true
        }

        audioRecord = record
        running.set(true)

        // 独立采集线程：read() 阻塞式取数据，天然按实时节奏产出
        micThread = Thread {
            try {
                record.startRecording()
                val chunk = ByteArray(bufSize)
                while (running.get()) {
                    val n = record.read(chunk, 0, chunk.size)
                    if (n > 0) {
                        onPcm(chunk.copyOf(n))
                    } else if (n < 0) {
                        break // 读错误（设备被抢占等），结束循环
                    }
                }
            } finally {
                try {
                    record.stop()
                } catch (_: IllegalStateException) {
                }
                record.release()
                running.set(false)
            }
        }.also { it.start() }

        return null
    }

    fun stop() {
        running.set(false)
        // 采集线程的 finally 里会 stop/release，这里只等它收尾
        try {
            micThread?.join(500)
        } catch (_: InterruptedException) {
        }
        micThread = null
        audioRecord = null
    }
}
