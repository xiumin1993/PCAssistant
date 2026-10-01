package com.pcspeaker.pc_speaker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.util.Range
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * v3.1 麦克风守护前台服务
 * ----------------------------------------------------------------------------
 * 作用：手机连上电脑后，把这个服务挂成"前台服务"（带一条常驻通知），
 * Android 就不会在息屏/后台时杀掉 App 进程 —— 这样 PC 端的唤醒指令
 * （mic_state）随时能送达、麦克风随时能启动，行为接近真实麦克风。
 *
 * 注意省电策略：本服务只负责"保命"（进程不被杀），
 * 并不开录音。真正的 AudioRecord 只在 PC 应用用到麦克风时才启动，
 * 用完即关 —— 耗电大户是麦克风硬件，不是这条通知。
 */
class MicForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        // START_STICKY：万一被系统回收，会尝试重建服务
        return START_STICKY
    }

    private fun startAsForeground() {
        val channelId = "mic_standby"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // v3.7 国际化：文案不写死中文，统一从资源表取（values/ = 英文，
        // values-zh/ = 中文），再由 localized() 按 App 内选的语言挑一份。
        // 已知限制：通知【渠道】名在渠道创建那刻就被系统记住了，之后换语言
        // 只会改通知的标题和正文，设置页里那条渠道名要等重装 App 才更新 ——
        // 这是安卓的硬规则（渠道删了不能再建同名），不是我们的疏忽。
        val ctx = localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW：通知栏常驻但无声无震动，不打扰
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    ctx.getString(R.string.notif_mic_channel),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(ctx.getString(R.string.notif_mic_title))
            .setContentText(ctx.getString(R.string.notif_mic_text))
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .build()
        startForeground(1002, notification)
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}

/**
 * v3.4 摄像头守护前台服务
 * ----------------------------------------------------------------------------
 * 与 MicForegroundService 同理：连上电脑后挂常驻通知保住进程，
 * 息屏时 PC 的 cam_state 指令才能唤醒相机。
 * 服务本身不开相机 —— 真正的 Camera2 只在 PC 应用观看时才打开。
 * Android 14 起相机类前台服务要求 foregroundServiceType="camera"（见 Manifest）。
 */
class CamForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_STICKY
    }

    private fun startAsForeground() {
        val channelId = "cam_standby"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // 同 MicForegroundService：文案进资源表，语言跟着 App 内设置走
        val ctx = localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    ctx.getString(R.string.notif_cam_channel),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(ctx.getString(R.string.notif_cam_title))
            .setContentText(ctx.getString(R.string.notif_cam_text))
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()
        startForeground(1003, notification)
    }
}

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.pcspeaker/audio"
    private var audioTrack: AudioTrack? = null
    // 单线程执行器：保证写入顺序，阻塞写入自然形成背压，不丢包
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    // ── v3 麦克风上行（手机 → PC）──────────────────────────────
    private val MIC_DATA_CHANNEL = "com.pcspeaker/mic_data"
    private var audioRecord: AudioRecord? = null
    private var micThread: Thread? = null
    // AtomicBoolean：多线程读写的布尔开关（true = 正在采集）
    private val micRunning = AtomicBoolean(false)
    // EventChannel 的"出水口"，采集线程把 PCM 字节从这里推给 Flutter
    private var micEventSink: EventChannel.EventSink? = null
    // 系统权限弹窗是异步的：用户点"允许/拒绝"前，先记住 Flutter 的回调
    private var pendingPermResult: MethodChannel.Result? = null
    private val PERM_REQUEST_CODE = 42

    // v3.1：麦克风守护前台服务的启停句柄（连上电脑=启动，断开=停止）
    private var micServiceStarted = false

    // ── v3.4 摄像头上行（手机 → PC）──────────────────────────
    private val CAM_DATA_CHANNEL = "com.pcspeaker/cam_data"
    // Camera2 采集引擎（见 CameraEngine.kt），懒加载：用到摄像头才创建
    private var camEngine: CameraEngine? = null
    // EventChannel 的"出水口"，采集线程把 JPEG 帧推给 Flutter
    private var camEventSink: EventChannel.EventSink? = null
    // 相机权限异步弹窗的回调暂存
    private var pendingCamPermResult: MethodChannel.Result? = null
    private val CAM_PERM_REQUEST_CODE = 43
    // 摄像头守护前台服务句柄
    private var camServiceStarted = false

    // 【v3.11】Flutter 引擎句柄：预览纹理要从它的 renderer 上申请
    // （TextureRegistry）。configureFlutterEngine 里赋值，那时引擎已就绪。
    private var flutterEngineRef: io.flutter.embedding.engine.FlutterEngine? = null

    private fun engine(): CameraEngine {
        return camEngine ?: CameraEngine(this, flutterEngineRef?.renderer).also { camEngine = it }
    }

    private fun startCamGuardService() {
        if (camServiceStarted) return
        val intent = Intent(this, CamForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        camServiceStarted = true
    }

    private fun stopCamGuardService() {
        if (!camServiceStarted) return
        stopService(Intent(this, CamForegroundService::class.java))
        camServiceStarted = false
    }

    private fun startMicStandbyService() {
        if (micServiceStarted) return
        val intent = Intent(this, MicForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        micServiceStarted = true
    }

    private fun stopMicStandbyService() {
        if (!micServiceStarted) return
        stopService(Intent(this, MicForegroundService::class.java))
        micServiceStarted = false
    }

    /**
     * v3.7 国际化：语言切换后，把"已经在挂着"的常驻通知重发一遍。
     *
     * 为什么需要这一步：前台服务的通知是在 onStartCommand 里用当时的语言建好的，
     * 之后 App 内换语言并不会自动回去改它 —— 不重发就会出现"界面已中文、
     * 通知栏还是英文"的割裂，只有断开重连才纠正。
     *
     * 为什么直接再 startService 就够：服务已在运行时，startService 不会重建服务，
     * 只是再回调一次 onStartCommand；而 startForeground(同一个 id, 新通知)
     * 的语义就是"原地更新这条通知"。所以状态机（有没有在录音/开相机）完全不受影响。
     *
     * 为什么用 flag 判断而不是查系统：micServiceStarted / camServiceStarted 就是
     * 本 App 自己启停这两个服务的唯一入口，它们为 true 等价于服务在跑，
     * 比反射查 ActivityManager 轻得多也可靠得多。
     */
    private fun refreshGuardNotifications() {
        // 仍走 O+ 分支：对已运行的服务，startForegroundService 同样安全，
        // 且能避免万一进程刚被回收时踩到后台启动限制。
        fun again(cls: Class<out Service>) {
            val intent = Intent(this, cls)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        }
        if (micServiceStarted) again(MicForegroundService::class.java)
        if (camServiceStarted) again(CamForegroundService::class.java)
    }

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 【v3.11】留住引擎：CameraEngine 要向它的 renderer 申请预览纹理
        flutterEngineRef = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setup" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                    val channels = call.argument<Int>("channels") ?: 2
                    setupAudio(sampleRate, channels)
                    result.success(true)
                }
                "write" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data != null) {
                        writeAudio(data)
                        result.success(true)
                    } else {
                        result.error("INVALID_DATA", "No data provided", null)
                    }
                }
                "start" -> {
                    audioTrack?.play()
                    result.success(true)
                }
                "pause" -> {
                    audioTrack?.pause()
                    result.success(true)
                }
                "stop" -> {
                    stopAudio()
                    result.success(true)
                }
                "release" -> {
                    releaseAudio()
                    result.success(true)
                }

                // ── 麦克风相关方法（v3 新增）──

                // 查询是否已授予录音权限（不弹窗）
                "checkMicPermission" -> {
                    result.success(hasMicPermission())
                }
                // 请求录音权限：已授予直接返回 true；否则弹系统窗，
                // 结果在 onRequestPermissionsResult 里通过 pendingPermResult 回传
                "requestMicPermission" -> {
                    if (hasMicPermission()) {
                        result.success(true)
                    } else {
                        pendingPermResult = result
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERM_REQUEST_CODE)
                    }
                }
                // 开始采集：成功返回 null，失败返回错误码字符串（Flutter 据此提示）
                "startMic" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                    val channels = call.argument<Int>("channels") ?: 1
                    result.success(startMic(sampleRate, channels))
                }
                "stopMic" -> {
                    stopMic()
                    result.success(true)
                }
                // v3.1：麦克风守护服务（前台通知保活，息屏时进程不被杀）
                "startMicStandby" -> {
                    startMicStandbyService()
                    result.success(true)
                }
                "stopMicStandby" -> {
                    stopMicStandbyService()
                    result.success(true)
                }

                // ── 摄像头相关方法（v3.4 新增）──

                // 静默查询相机权限（能力探测/自动待命用，不弹窗）
                "checkCamPermission" -> {
                    result.success(hasCamPermission())
                }
                // 请求相机权限（用户点按钮时才调）
                "requestCamPermission" -> {
                    if (hasCamPermission()) {
                        result.success(true)
                    } else {
                        pendingCamPermResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.CAMERA), CAM_PERM_REQUEST_CODE
                        )
                    }
                }
                // 能力探测：返回 [{facing, sizes:[{width,height,maxFps}]}]，
                // Flutter 据此把"手机最高支持什么画质"发给 PC 自动选档
                "getCameraCaps" -> {
                    result.success(engine().getCapabilities())
                }
                // 打开相机开始上行。成功返回 null，失败返回错误码
                "startCamera" -> {
                    val facing = call.argument<String>("facing") ?: "back"
                    val width = call.argument<Int>("width") ?: 640
                    val height = call.argument<Int>("height") ?: 480
                    val fps = call.argument<Int>("fps") ?: 30
                    val err = engine().start(facing, width, height, fps) { jpeg ->
                        // 采集线程回调来一帧 JPEG → EventChannel 推给 Flutter（主线程）
                        runOnUiThread { camEventSink?.success(jpeg) }
                    }
                    result.success(err)
                }
                // 【v3.11】查询预览纹理的 id / 摆正方式 / 实际尺寸：
                //   · 有 id → Dart 用 Texture(textureId) 直接采样 GPU 画面（零解码）
                //   · 没有 → 这台机没走纹理通道，Dart 退回原来的 JPEG 解码预览
                // 为什么单独开一个方法而不是塞进 startCamera 的返回值：
                // 切镜头会重建纹理（id 变），Dart 侧要能在【任意时刻】重新查。
                "getPreviewTextureId" -> {
                    result.success(engine().previewTextureInfo() ?: mapOf("id" to -1L))
                }
                "stopCamera" -> {
                    engine().stop()
                    result.success(true)
                }
                // 切换前/后置（内部 stop→start，沿用当前分辨率）；返回新 facing
                "switchCamera" -> {
                    result.success(engine().switchLens())
                }
                // v3.4.1：手动顺时针旋转 90°（0→90→180→270 循环）
                // 只改引擎里的一个角度数字，下一帧立即生效，不重启相机；
                // 返回新角度给 Flutter 更新按钮文案
                "rotateCamera" -> {
                    result.success(engine().rotateManual())
                }
                // 摄像头守护服务（前台通知保活）
                "startCamStandby" -> {
                    startCamGuardService()
                    result.success(true)
                }
                "stopCamStandby" -> {
                    engine().stop()
                    stopCamGuardService()
                    result.success(true)
                }

                // v3.4.2：首页按返回键不再"退出应用"，而是回到手机桌面，
                // App 退到后台继续活着（守护前台服务保活，连接/推流不中断）。
                // 原理：发一个"桌面"Intent（ACTION_MAIN + CATEGORY_HOME），
                // 相当于用户按了手机的 Home 键——我们的 Activity 只是被
                // 盖到后面，并没有 finish()，进程和 WebSocket 都不受影响。
                "goHome" -> {
                    val home = Intent(Intent.ACTION_MAIN).apply {
                        addCategory(Intent.CATEGORY_HOME)
                        // 从非 Activity 上下文/频道回调里启动 Activity，
                        // 必须加 NEW_TASK 标记，否则系统会抛异常
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(home)
                    result.success(true)
                }

                // v3.7 国际化：Flutter 切换界面语言时同步过来，让通知栏文案
                // 与 App 内语言一致（code = "auto" / "en" / "zh"）。
                "setLocale" -> {
                    // 顺序不能反：先落盘，再刷新 —— refreshGuardNotifications()
                    // 里的 localized() 要读到刚存的这个值。
                    AppLocale.save(this, call.argument<String>("code"))
                    refreshGuardNotifications()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // EventChannel：原生层 → Flutter 的单向数据流（麦克风 PCM 帧）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, MIC_DATA_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    micEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    micEventSink = null
                }
            })

        // v3.4：摄像头 JPEG 帧水管（结构与 mic_data 完全一样）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CAM_DATA_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    camEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    camEventSink = null
                }
            })
    }

    // ── 播放（v2 原有，未改动）──────────────────────────────────

    private fun setupAudio(sampleRate: Int, channels: Int) {
        releaseAudio()

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

    /**
     * 写入音频数据到 AudioTrack。
     *
     * 关键设计：
     * - 不用 isWriting 标志丢包（之前丢包导致波形断裂 → 噪音）
     * - 不调 flush()（流式播放时 flush 会丢弃缓冲区中还没播放的数据）
     * - 直接提交到单线程执行器，阻塞写入自然形成背压
     * - 执行器保证顺序，不会并发写入
     */
    private fun writeAudio(data: ByteArray) {
        executor.execute {
            // write() 是阻塞的：缓冲区满时等待，自然限速
            audioTrack?.write(data, 0, data.size)
        }
    }

    private fun stopAudio() {
        audioTrack?.stop()
    }

    private fun releaseAudio() {
        audioTrack?.release()
        audioTrack = null
    }

    // ── 麦克风采集（v3 新增）────────────────────────────────────

    private fun hasMicPermission(): Boolean {
        return checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    }

    /** v3.4：静默查询相机权限（不弹系统窗） */
    private fun hasCamPermission(): Boolean {
        return checkSelfPermission(Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
    }

    /**
     * 开始麦克风采集。
     * 返回 null = 成功；返回字符串 = 错误码（Flutter 层翻译成中文提示）。
     *
     * 音频源用 VOICE_COMMUNICATION（通话模式）：
     *   1. 系统会优先走回声消除（AEC）链路 —— 手机外放 PC 声音的同时
     *      麦克风还能"滤掉"扬声器里的 PC 声，避免啸叫（全双工关键）；
     *   2. 配合显式创建的 AcousticEchoCanceler / NoiseSuppressor 效果器。
     */
    private fun startMic(sampleRate: Int, channels: Int): String? {
        if (micRunning.get()) return null // 已在采集，幂等返回成功
        if (!hasMicPermission()) return "PERMISSION_DENIED"

        val channelConfig = if (channels == 1) {
            AudioFormat.CHANNEL_IN_MONO
        } else {
            AudioFormat.CHANNEL_IN_STEREO
        }
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT)
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
        } catch (e: SecurityException) {
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
        micRunning.set(true)

        // 独立采集线程：read() 阻塞式取数据，天然按实时节奏产出
        micThread = Thread {
            try {
                record.startRecording()
                val chunk = ByteArray(bufSize)
                while (micRunning.get()) {
                    val n = record.read(chunk, 0, chunk.size)
                    if (n > 0) {
                        val copy = chunk.copyOf(n)
                        // EventChannel 必须在主线程推送
                        runOnUiThread { micEventSink?.success(copy) }
                    } else if (n < 0) {
                        break // 读错误（设备被抢占等），结束循环
                    }
                }
            } finally {
                try { record.stop() } catch (_: IllegalStateException) {}
                record.release()
                micRunning.set(false)
            }
        }.also { it.start() }

        return null
    }

    private fun stopMic() {
        micRunning.set(false)
        // 采集线程的 finally 里会 stop/release，这里只等它收尾
        try { micThread?.join(500) } catch (_: InterruptedException) {}
        micThread = null
        audioRecord = null
    }

    /** 系统权限弹窗的用户答复在这里回到 Flutter */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERM_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermResult?.success(granted)
            pendingPermResult = null
        }
        // v3.4：相机权限弹窗的答复（requestCamPermission 走这里）
        if (requestCode == CAM_PERM_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingCamPermResult?.success(granted)
            pendingCamPermResult = null
        }
    }
}
