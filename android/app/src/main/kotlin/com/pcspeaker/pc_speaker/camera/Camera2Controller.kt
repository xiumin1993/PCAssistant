package com.pcspeaker.pc_speaker.camera

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.graphics.ImageFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Camera2Controller —— Camera2 采集路径（非 LEGACY 设备走这条）
 * ----------------------------------------------------------------------------
 * 职责边界与 Camera1Controller 一致：【只管把相机硬件跑起来、把帧交给
 * FramePipeline】。取帧之后的事（格式转换、编码、保序、统计）一概不碰。
 *
 * Camera2 的打开/建会话全是**异步**的（回调式），但 Flutter 的 MethodChannel
 * 期望"调用→返回结果"。这里用 CountDownLatch（倒计时门闩）把异步包装成同步：
 * 发起操作后 await 在门闩上（最多等 3 秒），系统回调里 countDown() 放行。
 */
internal class Camera2Controller(
    private val cameraManager: CameraManager,
    private val state: CameraState,
    private val pipeline: FramePipeline,
    private val preview: PreviewTexture
) {

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null

    /** 起相机并开始出帧。返回 null = 成功，否则是错误码。 */
    fun start(camId: String): String? {
        // 第一步：起一条后台消息线程。
        // Camera2 要求回调在某个 Handler 的线程上执行；放在独立线程
        // 就不阻塞界面（Flutter UI）线程。
        val thread = HandlerThread("cam-bg")
        thread.start()
        bgThread = thread
        bgHandler = Handler(thread.looper)

        // 第二步：建 ImageReader —— 相机帧的"取件柜"。
        // v3.8.2：槽位从 2 提到 PIPELINE_WORKERS+2。
        // 原来只有 2 个槽，流水线多路并行时柜子不够用 → 相机会因为"取件柜满了"
        // 反过来降速（backpressure），这也是实测只有 6fps 的一部分原因。
        // 我们每取一张都要 close() 归还，配合丢帧策略保实时。
        //
        // 槽位数按分辨率自适应（因为现在不再封顶 1080p，可能遇到 4K）：
        // 单帧 YUV 内存 = w*h*1.5 字节，4K 时一帧就 12.4MB —— 槽位开满会吃
        // 掉几十 MB 的 native 内存。所以大分辨率时少开一个槽（仍 ≥ 并行度+1，
        // 否则又会造成 backpressure）。
        val framePx = state.width * state.height
        val slots = if (framePx > 8_000_000)
            CameraConfig.PIPELINE_WORKERS + 1
        else
            CameraConfig.PIPELINE_WORKERS + 2
        imageReader = ImageReader.newInstance(
            state.width, state.height, ImageFormat.YUV_420_888, slots
        )

        // 第三步：真正打开相机（异步）
        val openLatch = CountDownLatch(1)
        var openError: String? = null
        try {
            cameraManager.openCamera(
                camId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        cameraDevice = device
                        openLatch.countDown() // 放行：打开成功
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        // 相机被系统收回（如别的 App 抢走了）
                        device.close()
                        cameraDevice = null
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        cameraDevice = null
                        openError = "OPEN_ERROR_$error"
                        openLatch.countDown() // 放行：带错误码
                    }
                },
                bgHandler
            )
        } catch (_: SecurityException) {
            stop()
            return "PERMISSION_DENIED"
        } catch (_: Exception) {
            stop()
            return "OPEN_ERROR"
        }

        if (!openLatch.await(3, TimeUnit.SECONDS)) {
            stop()
            return "OPEN_TIMEOUT"
        }
        if (openError != null || cameraDevice == null) {
            val err = openError ?: "OPEN_ERROR"
            stop()
            return err
        }

        // 第四步：建立"会话"（capture session）——
        // Camera2 里所有拍照/预览请求都要先建会话，
        // 相当于跟相机"约好：帧统一送到 ImageReader 这个取件柜"。
        val reader = imageReader!!
        reader.setOnImageAvailableListener({ r ->
            // 【v3.8.5】先记"HAL 叫了我几次"，取帧成功与否都算（见 FrameStats 注释）
            pipeline.onCallback()
            // v3.8.4：占满判断挪到【取帧之前】—— 原来先取出再判断，
            // 等于每次都白拿一张（还占着一个取件柜槽位）。
            if (pipeline.saturated) {
                // 流水线车道都占满了 → 这一帧丢掉，绝不排队（宁可跳帧也不堆延迟）
                r.acquireLatestImage()?.close()
                pipeline.onDropped()
                return@setOnImageAvailableListener
            }
            // 取最新一张，旧的直接作废（acquireLatestImage 自带丢旧帧行为）
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            pipeline.onArrived()
            pipeline.submitImage(image, "C2") { image.close() }
        }, bgHandler)

        val sessionLatch = CountDownLatch(1)
        var sessionOk = false
        val device = cameraDevice!!
        // 【v3.11】把预览纹理一并挂进会话：相机同时往"取帧柜(ImageReader)"和
        // "预览纹理"送同一批帧，后者由 GPU 直接采样 —— Dart 侧不再解码 JPEG。
        // 拿不到纹理时列表里就只有取帧柜，行为与改动前完全一致。
        val previewSt = preview.acquire(state.width, state.height)
        val targets = ArrayList<Surface>(2).apply {
            add(reader.surface)
            if (previewSt != null) add(Surface(previewSt))
        }
        @Suppress("DEPRECATION")
        device.createCaptureSession(
            targets,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    sessionOk = true
                    sessionLatch.countDown()
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    sessionLatch.countDown()
                }
            },
            bgHandler
        )
        if (!sessionLatch.await(3, TimeUnit.SECONDS) || !sessionOk) {
            stop()
            return "SESSION_FAILED"
        }

        // 第五步：发出"持续出帧"请求（repeating request）。
        // 【v3.8.4 关键】模板由 TEMPLATE_PREVIEW 改为 TEMPLATE_RECORD。
        // 为什么改：实测（Redmi 4X / 骁龙 435，960×720）相机稳定只给 ~11fps，
        // 而三个"想当然"的解释全被数据排除：
        //   · 环境由暗转亮 → 帧率纹丝不动（11.7 → 10.6，甚至略降），
        //     排除"暗光下自动曝光拉长"；
        //   · 把 conv 从 44ms 优化到 8.8ms、4 条车道理论吞吐 50fps →
        //     帧率仍 11fps 且 drop=0，排除"我们处理慢造成背压"；
        //   · CamPerf 日志已确认下发的就是 AE 区间 (30,30)。
        // 剩下最吻合的解释：PREVIEW 模板下 HAL 会做【自动帧率/省电优化】，
        // 把输出压到 10~15fps。这对"给眼睛看预览"够用，对我们要【持续上行
        // 30fps 给 PC 当摄像头】的场景却是致命的。RECORD 模板才是为持续
        // 录像/推流设计的，会锁定目标帧率。
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(reader.surface)
            // 再把"这是录像/推流"明确告诉 HAL：有些 HAL 光看模板还不够，
            // CAPTURE_INTENT 是它判断场景的另一个依据（录像场景通常不再降帧）。
            // 设不了就算了（个别老设备没这个 key），绝不能因此打不开相机。
            try {
                builder.set(
                    CaptureRequest.CONTROL_CAPTURE_INTENT,
                    CameraCharacteristics.CONTROL_CAPTURE_INTENT_VIDEO_RECORD
                )
            } catch (_: Exception) {
                // 不支持就算了，模板本身已经切到 RECORD
            }
            // v3.8：以前这里写 Range(currentFps, currentFps) —— 意思是
            // "强制相机只跑这一个帧率"。当时 currentFps 被封死在 30 以内，没问题；
            // 现在帧率改成跟着设备走了（可能是 60 / 120），再这么写就危险：
            // 若这段 fps 不在该设备的 AE 可用区间里，setRepeatingRequest 会直接
            // 抛 IllegalArgumentException → 走到下面 catch → 返回 SESSION_FAILED
            // → 表现就是"摄像头彻底打不开"。所以改为【查设备支持的区间再锁】：
            //   ① 优先挑"容纳得下目标帧率、且区间最窄"的那段（最贴合目标）；
            //   ② 一段都容纳不下（这台机跑不了这么快）→ 退它能跑最快的那段。
            val target = state.fps
            val ranges = try {
                cameraManager.getCameraCharacteristics(camId).get(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                )
            } catch (_: Exception) {
                null
            }
            var bestFit: Range<Int>? = null
            var fastest: Range<Int>? = null
            if (ranges != null) {
                for (r in ranges) {
                    if (fastest == null || r.upper > fastest.upper) fastest = r
                    if (r.lower <= target && target <= r.upper) {
                        if (bestFit == null ||
                            (r.upper - r.lower) < (bestFit.upper - bestFit.lower)
                        ) bestFit = r
                    }
                }
            }
            val chosen: Range<Int>? = bestFit ?: fastest
            // 【v3.8.4】把"目标帧率 / 设备全部可选区间 / 最终下发哪一段"打进日志。
            // 为什么必须打：CamPerf 显示 cam≈12fps 但 drop=0，说明不是我们处理慢，
            // 是相机自己只肯出 12fps。这里有两种截然不同的原因，只有看日志能分：
            //   (a) 我们挑的区间下界太低（如 7–30），相机被允许自由滑到 12fps
            //       → 代码问题，改挑选策略即可修；
            //   (b) 下发的是 (30,30)，HAL 仍因暗光拉长曝光降到 12fps
            //       → 物理限制，只能靠环境变亮解决，别再改代码。
            Log.i(
                "CamPerf",
                "AE target=" + target + "fps available=" +
                        (ranges?.joinToString(",") { "(${it.lower},${it.upper})" } ?: "null") +
                        " chosen=" + (chosen?.let { "(${it.lower},${it.upper})" } ?: "null")
            )
            if (chosen != null) {
                builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, chosen)
            } else {
                // 设备干脆没报可用区间（部分老 HAL1 机型）：退回老写法，靠外层 try 兜底
                builder.set(
                    CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                    Range(target, target)
                )
            }

            // 【v3.14】自动对焦：与 Camera1 同一套优先级（见 Camera1Controller 注释），
            // 同样只从【设备上报的】CONTROL_AF_AVAILABLE_MODES 里挑，绝不写死。
            val afModes = try {
                cameraManager.getCameraCharacteristics(camId)
                    .get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
            } catch (_: Exception) {
                null
            }
            val af = pickAfMode(afModes)
            if (af != null) {
                try {
                    builder.set(CaptureRequest.CONTROL_AF_MODE, af)
                    // CONTROL_MODE=AUTO 是 3A 能跑起来的前提（OFF 时 HAL 会锁死对焦）
                    builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                } catch (_: Exception) {
                    // 设不了就算了，绝不能因为对焦设不上就打不开相机
                }
            }
            Log.i(
                "CamPerf",
                "Camera2 对焦 supported=" + (afModes?.joinToString(",") ?: "null") +
                        " chosen=" + (af?.toString() ?: "none")
            )
            captureSession!!.setRepeatingRequest(builder.build(), null, bgHandler)
            // 单次对焦模式必须显式下发一次触发，否则镜头压根不动
            if (af == CaptureRequest.CONTROL_AF_MODE_AUTO) {
                try {
                    val trig = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                    trig.addTarget(reader.surface)
                    trig.set(CaptureRequest.CONTROL_AF_MODE, af)
                    trig.set(
                        CaptureRequest.CONTROL_AF_TRIGGER,
                        CaptureRequest.CONTROL_AF_TRIGGER_START
                    )
                    captureSession!!.capture(trig.build(), null, bgHandler)
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
            stop()
            return "SESSION_FAILED"
        }

        state.running = true
        return null // 成功
    }

    /** 停止并释放这条路径上的一切。按"请求→会话→设备→线程"的顺序逐层关好 */
    fun stop() {
        try {
            captureSession?.stopRepeating()
        } catch (_: Exception) {
        }
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null
        preview.release() // 【v3.11】预览纹理也要还回去
        // 退出后台线程。quitSafely：把手头消息跑完再退，不丢中间状态
        try {
            bgThread?.quitSafely()
        } catch (_: Exception) {
        }
        bgThread = null
        bgHandler = null
    }

    /** 这条路径是否在跑（CameraEngine.stop() 要用它判断要不要调 stop） */
    fun isActive(): Boolean = cameraDevice != null

    /** 对焦模式挑选：与 Camera1 同一套优先级，同样只认设备上报值。 */
    private fun pickAfMode(modes: IntArray?): Int? {
        if (modes == null || modes.isEmpty()) return null
        fun has(v: Int) = modes.any { it == v }
        return when {
            has(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) ->
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            has(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) ->
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            has(CaptureRequest.CONTROL_AF_MODE_AUTO) ->
                CaptureRequest.CONTROL_AF_MODE_AUTO
            has(CaptureRequest.CONTROL_AF_MODE_MACRO) ->
                CaptureRequest.CONTROL_AF_MODE_MACRO
            has(CaptureRequest.CONTROL_AF_MODE_EDOF) ->
                CaptureRequest.CONTROL_AF_MODE_EDOF
            else -> null
        }
    }
}
