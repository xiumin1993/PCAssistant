package com.pcspeaker.pc_speaker

import android.content.Context
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
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.view.Surface
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.util.Arrays
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * v3.4 摄像头采集引擎（Camera2 直连版）
 * ============================================================================
 * 职责：打开手机相机 → 持续拿到 YUV 画面 → 压缩成 JPEG → 通过回调扔给上层。
 *
 *   Camera2 采集(YUV_420_888) → ImageReader(后台线程) → 转 NV21
 *        → 线程池压缩 JPEG → onFrame(字节) → MainActivity → Flutter → 网络
 *
 * 为什么不用 CameraX 库？
 *   CameraX 更简单，但要额外引入几个依赖、APK 体积明显变大。
 *   本项目只需要"预览流 + 取帧"，Camera2（Android 系统自带 API）足够，
 *   零新依赖 —— 这也是用户"APK 尽量精简"的偏好。
 *
 * 为什么拿 YUV 而不是直接拿 JPEG？
 *   很多低端机的 ImageReader 不支持直接输出 JPEG 大图，
 *   YUV_420_888 是所有设备保证支持的格式；YUV→JPEG 用系统自带的
 *   YuvImage.compressToJpeg 即可完成，兼容性好。
 *
 * 帧率策略（丢帧保实时）：
 *   JPEG 压缩是 CPU 密集型操作，手机如果压缩不过来，
 *   宁可"跳帧"也不能让画面堆积延迟 —— 所以用 jpegBusy 开关：
 *   上一帧还在压，这一帧直接丢弃。摄像头永远只送"最新画面"。
 * ============================================================================
 */
class CameraEngine(private val context: Context) {

    private val cameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    // ── 当前工作状态 ──────────────────────────────────────────
    @Volatile private var running = false
    private var currentFacing = "back"          // 当前用的镜头："back" / "front"
    private var currentWidth = 640
    private var currentHeight = 480
    private var currentFps = 30

    // 传感器"安装角度"：这个镜头拍出的画面相对手机自然方向顺时针装了多少度。
    // 后置一般 90、前置一般 270（从系统查，不要写死）。
    // 用它 + 手机当前持握角度，才能算出"每帧该再转多少度才是正的"。
    private var sensorOrientation = 90

    // 每压好一帧 JPEG 就回调它（MainActivity 里转发给 EventChannel）
    private var onFrame: ((ByteArray) -> Unit)? = null

    // ── Camera2 相关对象（start 时创建，stop 时全部释放）──────
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null

    // JPEG 压缩专用单线程池：压缩不在采集线程上做，避免拖慢取帧
    private val compressExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // "上一帧还在压缩"标志 —— true 时新帧直接丢弃（保实时）
    private val jpegBusy = AtomicBoolean(false)

    // ── v3.4.1：手动旋转偏移（0/90/180/270，顺时针）──────────────
    // 自动摆正（传感器角+持握角）之外，再叠加用户手动点"旋转90°"的偏移。
    // @Volatile：采集/压缩线程每帧都要读它，Flutter 主线程写它，
    // 加 Volatile 保证写完立刻对其它线程可见（不需要锁，读频极高）。
    // 它不随 stop() 清零 —— 用户设定一次，断线重连/切镜头都继续生效。
    @Volatile private var manualRotation = 0

    val isRunning: Boolean get() = running

    /** 当前镜头朝向："back" 或 "front"（Flutter 层据此显示切换按钮文案） */
    fun facing(): String = currentFacing

    /**
     * v3.4.1：手动再顺时针转 90°（0→90→180→270→0 循环）。
     * 只改一个数字，下一帧压缩时自动套用 —— 实时生效、不重启相机。
     * 返回设置后的新角度，Flutter 按钮文案用它。
     */
    fun rotateManual(): Int {
        manualRotation = (manualRotation + 90) % 360
        return manualRotation
    }

    /** 读当前手动偏移角（Flutter 查询/恢复按钮文案用） */
    fun manualRotationDegrees(): Int = manualRotation

    // ══════════════════════════════════════════════════════════
    // 能力探测：告诉 PC "这台手机最高能开什么画质"
    // ══════════════════════════════════════════════════════════
    //
    // 返回形如：
    // [ {facing:"back",  sizes:[{width:1280,height:720,maxFps:30}, ...]},
    //   {facing:"front", sizes:[{width:640, height:480,maxFps:30}, ...]} ]
    //
    // CameraCharacteristics = 相机的"身份证+说明书"，
    // 不用打开相机就能查它支持哪些分辨率、每种分辨率最高多少帧。
    // 探测是纯读操作，无权限要求，App 启动时即可调用。
    fun getCapabilities(): List<Map<String, Any>> {
        val result = ArrayList<Map<String, Any>>()
        try {
            for (id in cameraManager.cameraIdList) {
                val ch = cameraManager.getCameraCharacteristics(id)
                val facingInt = ch.get(CameraCharacteristics.LENS_FACING) ?: continue
                val facing = when (facingInt) {
                    CameraCharacteristics.LENS_FACING_BACK -> "back"
                    CameraCharacteristics.LENS_FACING_FRONT -> "front"
                    else -> "external" // 外接摄像头（极少见），也支持
                }
                // 拿到"输出流配置"表：YUV_420_888 格式下相机支持的尺寸清单
                val map = ch.get(
                    CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
                ) ?: continue
                val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)
                    // 我们只需要网络传输：上限 1280×720 足够（更高分辨率
                    // 带宽和压缩都扛不住），过滤后按像素面积从大到小排
                    .filter { it.width.toLong() * it.height <= 1280L * 720 }
                    .sortedByDescending { it.width.toLong() * it.height }
                    .take(8) // 最多报 8 档，避免 JSON 过大
                    .map {
                        val minDur = try {
                            // 该尺寸下"两帧之间最少要间隔多少纳秒" → 换算最高帧率
                            map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, it)
                        } catch (_: IllegalArgumentException) {
                            33_000_000L // 查不到就按 30fps 保守报
                        }
                        val maxFps = if (minDur <= 0) 30
                        else (1_000_000_000.0 / minDur).toInt().coerceIn(1, 60)
                        mapOf(
                            "width" to it.width,
                            "height" to it.height,
                            "maxFps" to maxFps,
                        )
                    }
                if (sizes.isNotEmpty()) {
                    result.add(mapOf("facing" to facing, "sizes" to sizes))
                }
            }
        } catch (_: Exception) {
            // 个别机型查询会抛异常，返回已收集到的部分即可，不崩溃
        }
        return result
    }

    // ══════════════════════════════════════════════════════════
    // 打开相机开始采集
    // ══════════════════════════════════════════════════════════
    //
    // 返回 null = 成功；返回错误码字符串 = 失败（约定与麦克风 startMic 一致，
    // Flutter 层把错误码翻译成中文提示）。
    //
    // Camera2 的打开/建会话全是**异步**的（回调式），
    // 但 Flutter 的 MethodChannel 期望"调用→返回结果"。
    // 解决办法：CountDownLatch（倒计时门闩）——
    //   发起异步操作后，当前线程 await 在门闩上（最多等 3 秒），
    //   系统回调里 countDown() 放行。这样异步就"包装"成了同步返回。
    fun start(facing: String, width: Int, height: Int, fps: Int, onFrame: (ByteArray) -> Unit): String? {
        if (running) return null // 幂等：已在采集直接算成功

        this.onFrame = onFrame
        this.currentFacing = facing
        this.currentWidth = width
        this.currentHeight = height
        this.currentFps = fps.coerceIn(1, 30) // 网络场景 30fps 封顶

        // 第一步：按朝向找到相机 id（"0" 通常是后置，"1" 前置，但不保证，
        // 正确做法是遍历 characteristics 比对 LENS_FACING）
        val camId = findCameraId(facing) ?: return "NO_CAMERA"

        // 查一下这个镜头的安装角度（查不到按 90 保守处理，绝大多数手机如此）
        sensorOrientation = try {
            cameraManager.getCameraCharacteristics(camId)
                .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        } catch (_: Exception) {
            90
        }

        // 第二步：起一条后台消息线程。
        // Camera2 要求回调在某个 Handler 的线程上执行；放在独立线程
        // 就不阻塞界面（Flutter UI）线程。
        val thread = HandlerThread("cam-bg")
        thread.start()
        bgThread = thread
        bgHandler = Handler(thread.looper)

        // 第三步：建 ImageReader —— 相机帧的"取件柜"。
        // maxImages=2：柜子里最多放 2 张待取照片，
        // 我们每取一张都要 close() 归还，配合丢帧策略保实时。
        imageReader = ImageReader.newInstance(
            currentWidth, currentHeight, ImageFormat.YUV_420_888, 2
        )

        // 第四步：真正打开相机（异步）
        val openLatch = CountDownLatch(1)
        var openError: String? = null
        try {
            // 无 SurfaceTexture 的纯取流模式不需要额外权限声明外的东西，
            // 但 checkSelfPermission 已由 Flutter 层保证过了
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
            cleanup()
            return "PERMISSION_DENIED"
        } catch (_: Exception) {
            cleanup()
            return "OPEN_ERROR"
        }

        if (!openLatch.await(3, TimeUnit.SECONDS)) {
            cleanup()
            return "OPEN_TIMEOUT"
        }
        if (openError != null || cameraDevice == null) {
            val err = openError ?: "OPEN_ERROR"
            cleanup()
            return err
        }

        // 第五步：建立"会话"（capture session）——
        // Camera2 里所有拍照/预览请求都要先建会话，
        // 相当于跟相机"约好：帧统一送到 ImageReader 这个取件柜"。
        val reader = imageReader!!
        reader.setOnImageAvailableListener({ r ->
            // 取最新一张，旧的直接作废（acquireLatestImage 自带丢旧帧行为）
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            if (jpegBusy.get()) {
                image.close() // 上一帧还在压 → 这一帧丢掉，绝不排队
                return@setOnImageAvailableListener
            }
            jpegBusy.set(true)
            // 先在这条线程把 YUV 转成 NV21 字节（快），
            // 马上 close() 归还相机缓冲，再做耗时的 JPEG 压缩
            val nv21 = try {
                yuvToNv21(image)
            } catch (_: Exception) {
                jpegBusy.set(false)
                image.close()
                return@setOnImageAvailableListener
            }
            image.close()

            compressExecutor.execute {
                try {
                    // ── 方向补偿流水线（每帧在压缩线程做，不碰采集线程）──
                    // 1) 按"传感器安装角 + 手机持握角"把 NV21 转正（竖着拿 → 竖屏正像）
                    // 2) 前置镜头再水平镜像（自拍视角，和手机屏幕预览一致）
                    // 3) 统一装进"横向画布"（PC 会话尺寸，如 960×720）：
                    //    竖屏内容居中、左右加黑边 —— 电脑端虚拟摄像头格式恒定，
                    //    任何应用打开都不会因分辨率变化而黑屏
                    var fw = currentWidth
                    var fh = currentHeight
                    var data = nv21
                    val deg = rotationNeededDegrees()
                    if (deg != 0) {
                        val r = rotateNv21(data, fw, fh, deg)
                        data = r.first; fw = r.second; fh = r.third
                    }
                    if (currentFacing == "front") {
                        data = mirrorNv21(data, fw, fh)
                    }
                    // 画布 = 会话协商的横向尺寸（宽≥高）
                    val cw = maxOf(currentWidth, currentHeight)
                    val ch = minOf(currentWidth, currentHeight)
                    if (fw != cw || fh != ch) {
                        data = fitNv21Into(data, fw, fh, cw, ch)
                        fw = cw; fh = ch
                    }
                    val jpeg = nv21ToJpeg(data, fw, fh, 60)
                    if (running) onFrame?.invoke(jpeg)
                } catch (_: Exception) {
                    // 单帧压缩失败无所谓，丢掉继续
                } finally {
                    jpegBusy.set(false) // 开门放下一帧
                }
            }
        }, bgHandler)

        val sessionLatch = CountDownLatch(1)
        var sessionOk = false
        val device = cameraDevice!!
        @Suppress("DEPRECATION")
        device.createCaptureSession(
            listOf(reader.surface),
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
            cleanup()
            return "SESSION_FAILED"
        }

        // 第六步：发出"持续预览"请求（repeating request）。
        // TEMPLATE_PREVIEW 是低延迟预览模板；
        // 锁定自动曝光帧率范围，让相机尽量按目标 fps 出帧。
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(reader.surface)
            builder.set(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                Range(currentFps, currentFps)
            )
            captureSession!!.setRepeatingRequest(builder.build(), null, bgHandler)
        } catch (_: Exception) {
            cleanup()
            return "SESSION_FAILED"
        }

        running = true
        return null // 成功
    }

    /**
     * 切换前/后置镜头：停掉当前 → 用同样的分辨率/帧率打开另一个。
     * 返回切换后的 facing（"back"/"front"），Flutter 据此更新按钮文案。
     */
    fun switchLens(): String {
        if (!running) return currentFacing
        val target = if (currentFacing == "back") "front" else "back"
        // 没有另一个镜头就别切
        if (findCameraId(target) == null) return currentFacing
        val cb = onFrame ?: return currentFacing
        val w = currentWidth
        val h = currentHeight
        val f = currentFps
        stop()
        start(target, w, h, f, cb) // 失败也返回目标朝向？不：以实际为准
        return currentFacing
    }

    /** 停止采集并释放所有相机资源（幂等：没开就直接返回） */
    fun stop() {
        if (!running && cameraDevice == null) {
            onFrame = null
            return
        }
        running = false
        cleanup()
        onFrame = null
    }

    /** 内部清理：按"请求→会话→设备→线程"的顺序逐层关好 */
    private fun cleanup() {
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        try { cameraDevice?.close() } catch (_: Exception) {}
        cameraDevice = null
        try { imageReader?.close() } catch (_: Exception) {}
        imageReader = null
        // 退出后台线程。quitSafely：把手头消息跑完再退，不丢中间状态
        try { bgThread?.quitSafely() } catch (_: Exception) {}
        bgThread = null
        bgHandler = null
    }

    // ══════════════════════════════════════════════════════════
    // 工具方法
    // ══════════════════════════════════════════════════════════

    /** 按朝向（"back"/"front"）查相机 id，找不到返回 null */
    private fun findCameraId(facing: String): String? {
        val want = when (facing) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            "external" -> CameraCharacteristics.LENS_FACING_EXTERNAL
            else -> CameraCharacteristics.LENS_FACING_BACK
        }
        try {
            for (id in cameraManager.cameraIdList) {
                val f = cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)
                if (f != null && f == want) return id
            }
        } catch (_: Exception) {}
        return null
    }

    /**
     * YUV_420_888 → NV21 字节数组。
     *
     * 背景知识：相机给的不是 RGB，而是 YUV（亮度 Y + 色度 U/V），
     * 因为人眼对亮度敏感、对颜色不敏感，YUV 可以省带宽。
     * YUV_420_888 = 每 4 个 Y 共享一对 UV（色度分辨率减半）。
     * NV21 = Android 老标准格式：先整块 Y，再 V/U 交错排成一块。
     * compressToJpeg 只认 NV21，所以要做这次"重新摆放字节"。
     *
     * 关键坑：每行像素之间可能有 padding（rowStride > width），
     * 而且行内相邻像素间隔不一定是 1（pixelStride），
     * 必须按步长取字节，不能整块 copyOfRange —— 否则画面错位/绿条。
     */
    private fun yuvToNv21(image: Image): ByteArray {
        val w = image.width
        val h = image.height
        val ySize = w * h
        val out = ByteArray(ySize + ySize / 2) // NV21 总大小 = w*h*3/2

        // ── Y 平面 ──
        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer
        val yRowStride = yPlane.rowStride
        if (yRowStride == w && yPlane.pixelStride == 1) {
            // 最快路径：行连续无 padding，整块拷贝
            yBuf.get(out, 0, ySize)
        } else {
            // 逐行拷贝，跳过行尾 padding
            var dst = 0
            for (row in 0 until h) {
                for (col in 0 until w) {
                    out[dst++] = yBuf[row * yRowStride + col * yPlane.pixelStride]
                }
            }
        }

        // ── U/V 平面（半分辨率）──
        // NV21 的顺序是 V 在前、U 在后（VU 交错）
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        var dst = ySize
        // 部分机型 V 平面比 U 平面短一截（奇数尺寸/驱动怪癖），
        // 所以下标统一 coerceAtMost 夹住，越界就重复最后一字节，绝不崩溃
        val uMax = uBuf.capacity() - 1
        val vMax = vBuf.capacity() - 1
        for (row in 0 until h / 2) {
            for (col in 0 until w / 2) {
                val uvIndex = row * uvRowStride + col * uvPixelStride
                out[dst++] = vBuf[uvIndex.coerceAtMost(vMax)]
                out[dst++] = uBuf[uvIndex.coerceAtMost(uMax)]
            }
        }
        return out
    }

    /**
     * 手机当前的"持握角度"（0/90/180/270，顺时针）。
     * 从 WindowManager 拿屏幕旋转状态：竖屏=0、向左横躺=90、倒竖=180、向右横躺=270。
     * 拿不到（个别机型/时机）就当竖屏 0，画面顶多转错方向但不会崩。
     */
    private fun displayRotationDegrees(): Int {
        return try {
            val rot = (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .defaultDisplay.rotation
            when (rot) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
        } catch (_: Exception) {
            0
        }
    }

    /**
     * 每帧需要"顺时针再转多少度"才是正的。
     * 这是 Android 相机官方公式（Camera2 文档 JPEG_ORIENTATION 一节）：
     *   后置：(传感器安装角 - 持握角 + 360) % 360
     *   前置：(传感器安装角 + 持握角) % 360   ← 前置还要再水平镜像（见下）
     * 例：后置安装角 90、竖屏持握(0) → 需要顺时针转 90°，横拍原图就变竖屏正像。
     */
    private fun rotationNeededDegrees(): Int {
        val dev = displayRotationDegrees()
        val auto = if (currentFacing == "front")
            (sensorOrientation + dev) % 360
        else
            (sensorOrientation - dev + 360) % 360
        // v3.4.1：自动摆正之后，再叠加用户手动"旋转90°"的偏移
        return (auto + manualRotation) % 360
    }

    /**
     * NV21 整体顺时针旋转 90/180/270 度。
     *
     * NV21 内存布局：前 w*h 字节是 Y（每像素 1 字节），
     * 后 w*h/2 字节是 V/U 交错（每 2×2 像素共享 1 对，所以按"色度像素"算 w/2 × h/2）。
     * 旋转时对 Y 逐像素搬位置，对色度按"一对两字节"为单位搬位置。
     * 返回 (新数组, 新宽, 新高)——90/270 度时宽高互换。
     */
    private fun rotateNv21(src: ByteArray, w: Int, h: Int, deg: Int): Triple<ByteArray, Int, Int> {
        if (deg == 0) return Triple(src, w, h)
        val ySize = w * h
        val out = ByteArray(src.size)
        if (deg == 180) {
            // 宽高不变：Y 平面中心对称翻转
            for (y in 0 until h) for (x in 0 until w)
                out[(h - 1 - y) * w + (w - 1 - x)] = src[y * w + x]
            // 色度同理（网格 w/2 × h/2，每格 2 字节）
            val hw = w / 2
            for (y in 0 until h / 2) for (x in 0 until hw) {
                val si = ySize + y * w + x * 2
                val di = ySize + (h / 2 - 1 - y) * w + (hw - 1 - x) * 2
                out[di] = src[si]; out[di + 1] = src[si + 1]
            }
            return Triple(out, w, h)
        }
        // 90 / 270：宽高互换。新图 nw=xh、nh=w
        val nw = h; val nh = w
        for (y in 0 until h) for (x in 0 until w) {
            // deg=90(顺时针): 新坐标 (nx,ny) = (h-1-y, x)；deg=270: (y, w-1-x)
            val nx = if (deg == 90) h - 1 - y else y
            val ny = if (deg == 90) x else w - 1 - x
            out[ny * nw + nx] = src[y * w + x]
        }
        val hw = w / 2; val hh = h / 2; val nnw = nw  // 色度行跨距 = 新宽
        for (y in 0 until hh) for (x in 0 until hw) {
            val nx = if (deg == 90) hh - 1 - y else y
            val ny = if (deg == 90) x else hw - 1 - x
            val si = ySize + y * w + x * 2
            val di = ySize + ny * nnw + nx * 2
            out[di] = src[si]; out[di + 1] = src[si + 1]
        }
        return Triple(out, nw, nh)
    }

    /**
     * NV21 水平镜像（左右翻转）。前置镜头专用：
     * 自拍时大家已经习惯"镜子里的自己"，PC 上保持一致才不别扭。
     * Y 每行倒着抄；色度每行按"两字节一对"倒着抄。
     */
    private fun mirrorNv21(src: ByteArray, w: Int, h: Int): ByteArray {
        val ySize = w * h
        val out = ByteArray(src.size)
        for (y in 0 until h) for (x in 0 until w)
            out[y * w + (w - 1 - x)] = src[y * w + x]
        for (y in 0 until h / 2) for (x in 0 until w / 2) {
            val si = ySize + y * w + x * 2
            val di = ySize + y * w + (w / 2 - 1 - x) * 2
            out[di] = src[si]; out[di + 1] = src[si + 1]
        }
        return out
    }

    /**
     * 把任意 w×h 的 NV21 等比缩放、居中"装裱"进 cw×ch 的横向画布（四周填黑）。
     *
     * 为什么装裱而不是直接发竖屏尺寸？
     *   电脑端虚拟摄像头对上层应用承诺了固定分辨率，帧尺寸中途变化
     *   会让部分应用（尤其 OBS 通道）黑屏。统一成横向画布最稳。
     *
     * 缩放用"最近邻"：目标像素直接按比例回采源像素，
     * 代码简单、CPU 便宜，画质对 30fps 网络流完全够用。
     */
    private fun fitNv21Into(src: ByteArray, w: Int, h: Int, cw: Int, ch: Int): ByteArray {
        val out = ByteArray(cw * ch * 3 / 2)
        // 画布先涂"视频黑"：Y=16、色度=128（YUV 有限量程下的纯黑，不是 0/0）
        Arrays.fill(out, 0, cw * ch, 16.toByte())
        Arrays.fill(out, cw * ch, out.size, 128.toByte())

        // 等比缩放：长边贴画布，宽高都取偶数（色度 2×2 对齐要求）
        val scale = minOf(cw.toFloat() / w, ch.toFloat() / h)
        val dw = (w * scale).toInt() / 2 * 2
        val dh = (h * scale).toInt() / 2 * 2
        if (dw <= 0 || dh <= 0) return out
        val ox = (cw - dw) / 2 / 2 * 2
        val oy = (ch - dh) / 2 / 2 * 2

        // Y 平面：逐目标行、逐目标列最近邻回采
        for (y in 0 until dh) {
            val sy = y * h / dh
            val sRow = sy * w
            val dRow = (oy + y) * cw + ox
            for (x in 0 until dw) out[dRow + x] = src[sRow + x * w / dw]
        }
        // 色度平面：网格是 (w/2 × h/2)，每格 2 字节一起搬
        val hw = w / 2; val hh = h / 2
        val hdw = dw / 2; val hdh = dh / 2
        val ySize = w * h
        for (y in 0 until hdh) {
            val sy = y * hh / hdh
            val sRow = ySize + sy * hw * 2
            val dRow = cw * ch + (oy / 2 + y) * cw + ox
            for (x in 0 until hdw) {
                val sx = x * hw / hdw
                out[dRow + x * 2] = src[sRow + sx * 2]
                out[dRow + x * 2 + 1] = src[sRow + sx * 2 + 1]
            }
        }
        return out
    }

    /**
     * NV21 → JPEG 字节数组。
     * YuvImage 是 Android 自带的编码器（系统层用 libjpeg-turbo），
     * quality 60：网络传输场景的甜点值 —— 肉眼够用、体积小。
     */
    private fun nv21ToJpeg(nv21: ByteArray, w: Int, h: Int, quality: Int): ByteArray {
        val yuv = YuvImage(nv21, ImageFormat.NV21, w, h, null)
        val baos = ByteArrayOutputStream(w * h / 4) // 预分配 1/4 面积，减少扩容
        yuv.compressToJpeg(Rect(0, 0, w, h), quality, baos)
        return baos.toByteArray()
    }

    /** App 退出时调用：关掉压缩线程池 */
    fun dispose() {
        stop()
        compressExecutor.shutdownNow()
    }
}
