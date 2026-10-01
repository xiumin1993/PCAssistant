package com.pcspeaker.pc_speaker.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * AudioPlayer —— PC → 手机 的音频播放（手机当扬声器）
 * ----------------------------------------------------------------------------
 * 一进一出一个 AudioTrack：PC 端送来的 PCM 直接写进去播。
 *
 * 关键设计（别乱改，都是踩过的坑）：
 * - 不用 isWriting 标志丢包（之前丢包导致波形断裂 → 噪音）
 * - 不调 flush()（流式播放时 flush 会丢弃缓冲区中还没播放的数据）
 * - 直接提交到单线程执行器，阻塞写入自然形成背压
 * - 执行器保证顺序，不会并发写入
 */
class AudioPlayer {

    private var audioTrack: AudioTrack? = null

    /** 单线程执行器：保证写入顺序，阻塞写入自然形成背压，不丢包 */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    fun setup(sampleRate: Int, channels: Int) {
        release()

        val channelConfig = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }

        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        // 使用 2 倍最小缓冲区，减少欠载（underrun）导致的杂音
        val bufferSize = minBufferSize * 2

        val audioAttributes = AudioAttributes.Builder()
            .setLegacyStreamType(AudioManager.STREAM_MUSIC)
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            audioAttributes.setFlags(AudioAttributes.FLAG_LOW_LATENCY)
        }

        audioTrack = AudioTrack(
            audioAttributes.build(),
            AudioFormat.Builder()
                .setChannelMask(channelConfig)
                .setEncoding(audioFormat)
                .setSampleRate(sampleRate)
                .build(),
            bufferSize,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
    }

    fun write(data: ByteArray) {
        executor.execute {
            // write() 是阻塞的：缓冲区满时等待，自然限速
            audioTrack?.write(data, 0, data.size)
        }
    }

    fun play() {
        audioTrack?.play()
    }

    fun pause() {
        audioTrack?.pause()
    }

    fun stop() {
        audioTrack?.stop()
    }

    fun release() {
        audioTrack?.release()
        audioTrack = null
    }
}
