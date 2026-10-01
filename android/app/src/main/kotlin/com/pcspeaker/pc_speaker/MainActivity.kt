package com.pcspeaker.pc_speaker

import android.Manifest
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.pcspeaker.pc_speaker.audio.AudioPlayer
import com.pcspeaker.pc_speaker.audio.MicRecorder
import com.pcspeaker.pc_speaker.platform.ForegroundGuard
import com.pcspeaker.pc_speaker.platform.PermissionRequester

/**
 * MainActivity —— Flutter 与原生的接线盒
 * ----------------------------------------------------------------------------
 * 这个文件【只做两件事】：
 *   1. 把 Flutter 的方法调用翻译成对某个组件的调用（音频播放 / 麦克风采集 /
 *      摄像头采集 / 前台服务 / 权限）；
 *   2. 把原生产生的数据流（PCM、JPEG 帧）通过 EventChannel 推回去。
 *
 * 具体的活都在别处：
 *   audio/AudioPlayer          扬声器（AudioTrack）
 *   audio/MicRecorder          麦克风（AudioRecord）
 *   camera/CameraEngine 及其子包  摄像头采集
 *   platform/ForegroundGuard   两条保命通知的开关
 *   platform/PermissionRequester  运行时权限的问与答
 *   service/ 下的两个前台服务本体
 *
 * 【v3.15】原来 620 行里塞了两个 Service 类、音频播放、麦克风采集和一堆
 * 相机方法分发；现在拆完只剩接线，每个方法体基本都是"取参数 → 调一下 → 回结果"。
 */
class MainActivity : FlutterActivity() {

    // ── 通道名 ────────────────────────────────────────────────────
    private val CHANNEL = "com.pcspeaker/audio"
    private val MIC_DATA_CHANNEL = "com.pcspeaker/mic_data"
    private val CAM_DATA_CHANNEL = "com.pcspeaker/cam_data"

    /** 权限请求码：一个给麦克风、一个给相机（系统回调靠它区分是谁的回答） */
    private val PERM_REQUEST_CODE = 42
    private val CAM_PERM_REQUEST_CODE = 43

    // ── 各领域的组件 ──────────────────────────────────────────────
    private val permissions = PermissionRequester(this)
    private val guard = ForegroundGuard(this)
    private val player = AudioPlayer()

    private val recorder = MicRecorder(
        permissionGranted = { permissions.has(Manifest.permission.RECORD_AUDIO) },
        // EventChannel 必须在主线程推送 —— 采集线程先把数据交给主线程
        onPcm = { pcm -> runOnUiThread { micEventSink?.success(pcm) } }
    )

    // 摄像头采集引擎（见 CameraEngine），懒加载：用到摄像头才创建
    private var camEngine: CameraEngine? = null

    /**
     * 【v3.11】Flutter 引擎句柄：预览纹理要从它的 renderer 上申请
     *（TextureRegistry）。configureFlutterEngine 里赋值，那时引擎已就绪。
     */
    private var flutterEngineRef: io.flutter.embedding.engine.FlutterEngine? = null

    // ── EventChannel 的"出水口" ───────────────────────────────────
    private var micEventSink: EventChannel.EventSink? = null
    private var camEventSink: EventChannel.EventSink? = null

    private fun engine(): CameraEngine =
        camEngine ?: CameraEngine(this, flutterEngineRef?.renderer).also { camEngine = it }

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 【v3.11】留住引擎：CameraEngine 要向它的 renderer 申请预览纹理
        flutterEngineRef = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ── 播放（PC → 手机）──
                    "setup" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 2
                        player.setup(sampleRate, channels)
                        result.success(true)
                    }
                    "write" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data != null) {
                            player.write(data)
                            result.success(true)
                        } else {
                            result.error("INVALID_DATA", "No data provided", null)
                        }
                    }
                    "start" -> {
                        player.play()
                        result.success(true)
                    }
                    "pause" -> {
                        player.pause()
                        result.success(true)
                    }
                    "stop" -> {
                        player.stop()
                        result.success(true)
                    }
                    "release" -> {
                        player.release()
                        result.success(true)
                    }

                    // ── 麦克风（手机 → PC）──

                    // 查询是否已授予录音权限（不弹窗）
                    "checkMicPermission" -> result.success(
                        permissions.has(Manifest.permission.RECORD_AUDIO)
                    )
                    // 请求录音权限：已授予直接返回 true；否则弹系统窗，
                    // 结果在 onRequestPermissionsResult 里回传
                    "requestMicPermission" -> permissions.request(
                        Manifest.permission.RECORD_AUDIO, PERM_REQUEST_CODE, result
                    )
                    // 开始采集：成功返回 null，失败返回错误码字符串（Flutter 据此提示）
                    "startMic" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 1
                        result.success(recorder.start(sampleRate, channels))
                    }
                    "stopMic" -> {
                        recorder.stop()
                        result.success(true)
                    }
                    // v3.1：麦克风守护服务（前台通知保活，息屏时进程不被杀）
                    "startMicStandby" -> {
                        guard.startMic()
                        result.success(true)
                    }
                    "stopMicStandby" -> {
                        guard.stopMic()
                        result.success(true)
                    }

                    // ── 摄像头（手机 → PC）──

                    // 静默查询相机权限（能力探测/自动待命用，不弹窗）
                    "checkCamPermission" -> result.success(
                        permissions.has(Manifest.permission.CAMERA)
                    )
                    // 请求相机权限（用户点按钮时才调）
                    "requestCamPermission" -> permissions.request(
                        Manifest.permission.CAMERA, CAM_PERM_REQUEST_CODE, result
                    )
                    // 能力探测：返回 [{facing, sizes:[{width,height,maxFps}]}]，
                    // Flutter 据此把"手机最高支持什么画质"发给 PC 自动选档
                    "getCameraCaps" -> result.success(engine().getCapabilities())
                    // 打开相机开始上行。成功返回 null，失败返回错误码
                    "startCamera" -> {
                        val facing = call.argument<String>("facing") ?: "back"
                        val width = call.argument<Int>("width") ?: 640
                        val height = call.argument<Int>("height") ?: 480
                        val fps = call.argument<Int>("fps") ?: 30
                        // 【v3.16】codec 由 Flutter 指定：null = 自动（按硬件挑最清楚的）
                        val codec = call.argument<String>("codec")
                        engine().selectCodec(codec)
                        val err = engine().start(facing, width, height, fps) { jpeg ->
                            // 采集线程回调来一帧 → EventChannel 推给 Flutter（主线程）
                            runOnUiThread { camEventSink?.success(jpeg) }
                        }
                        result.success(err)
                    }
                    // 【v3.16】这台机在给定画质下可用的编码方式（按清晰度从高到低）
                    "getCodecOptions" -> result.success(
                        engine().availableCodecs(
                            call.argument<Int>("width") ?: 1280,
                            call.argument<Int>("height") ?: 720,
                            call.argument<Int>("fps") ?: 30
                        )
                    )
                    // 切换编码方式；传 null = 回到自动。
                    // 返回 null=成功，非空=失败原因（设备不支持时链路自动留在 JPEG）
                    "setCodec" -> result.success(
                        engine().selectCodec(call.argument<String>("codec"))
                    )
                    // 当前实际在用的编码方式（"JPEG" / "H264" / "H265"）
                    "getCodec" -> result.success(engine().currentCodec())
                    // 【v3.11】查询预览纹理的 id / 摆正方式 / 实际尺寸：
                    //   · 有 id → Dart 用 Texture(textureId) 直接采样 GPU 画面（零解码）
                    //   · 没有 → 这台机没走纹理通道，Dart 退回原来的 JPEG 解码预览
                    // 为什么单独开一个方法而不是塞进 startCamera 的返回值：
                    // 切镜头会重建纹理（id 变），Dart 侧要能在【任意时刻】重新查。
                    "getPreviewTextureId" -> result.success(
                        engine().previewTextureInfo() ?: mapOf("id" to -1L)
                    )
                    "stopCamera" -> {
                        engine().stop()
                        result.success(true)
                    }
                    // 切换前/后置（内部 stop→start，沿用当前分辨率）；返回新 facing
                    "switchCamera" -> result.success(engine().switchLens())
                    // v3.4.1：手动顺时针旋转 90°（0→90→180→270 循环）
                    // 只改引擎里的一个角度数字，下一帧立即生效，不重启相机；
                    // 返回新角度给 Flutter 更新按钮文案
                    "rotateCamera" -> result.success(engine().rotateManual())
                    // 摄像头守护服务（前台通知保活）
                    "startCamStandby" -> {
                        guard.startCam()
                        result.success(true)
                    }
                    "stopCamStandby" -> {
                        engine().stop()
                        guard.stopCam()
                        result.success(true)
                    }

                    // ── 其它 ──

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
                        // 顺序不能反：先落盘，再刷新 —— guard.refresh() 里的
                        // localized() 要读到刚存的这个值。
                        AppLocale.save(this, call.argument<String>("code"))
                        guard.refresh()
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

    /** 系统权限弹窗的用户答复在这里回到 Flutter */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        this.permissions.onResult(requestCode, grantResults)
    }
}
