package com.pcspeaker.pc_speaker

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
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
import android.util.Log
import io.flutter.view.TextureRegistry
import android.util.Range
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.util.Arrays
import java.util.TreeMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.LongAdder

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
 *   宁可"跳帧"也不能让画面堆积延迟 —— 流水线车道占满时新帧直接丢弃，
 *   摄像头永远只送"最新画面"，绝不排队。
 *
 * 【v3.8.2 性能改造】改造前实测只有 6fps，两处硬伤：
 *   1) 一次只允许 1 帧在流水线里（单线程 + jpegBusy 互斥门）→ 不管几核只用 1 核；
 *   2) 方向补偿走了三步全帧遍历（旋转→镜像→装裱），每步还各分配 ~1MB。
 * 现在：① 多帧并行（并行度按本机核数推导，不写死）+ 保序输出；
 *       ② 旋转/镜像/装裱合并成一次查表采样。
 *
 * 【通用性约定】本文件不针对任何具体机型写死参数：核数、并行度、旋转分段数
 * 一律由 Runtime.availableProcessors() 运行时推导；分辨率/帧率上限取自设备
 * 自己上报的 Camera2 能力清单。要加限制只能加"技术安全阀"（如单边 ≤1080），
 * 不能加"某台机器实测出来"的经验值。
 * 瓶颈定位看 logcat 的 CamPerf 行（每 2 秒一条，含 cam 出帧率与 drop 丢帧数）。
 * ============================================================================
 */
/**
 * @param textureRegistry Flutter 的纹理注册表（来自 FlutterEngine.renderer）。
 *   传进来之后，相机的预览画面会【直接】送到一块 GPU 纹理上，Flutter 用
 *   Texture(textureId) 显示 —— 画面不经过 CPU 解码（详见 previewEntry 注释）。
 *   传 null 也可以：那会退回"离屏空纹理"，预览只能走老的 JPEG 解码路径。
 */
class CameraEngine(
    private val context: Context,
    private val textureRegistry: TextureRegistry? = null
) {

    companion object {
        // ======================================================================
        // 【v3.8.2】并行度按"这台机器实际有多少核"运行时推导，不写死任何数字。
        // 本项目要跑在各种手机上：4 核的低端机、8 核主流机、16 核旗舰机都有。
        // 写死 4 或 8 都会在别的机器上出问题（低端机 UI 卡死 / 旗舰机吃不满）。
        // ======================================================================

        /** 可用核数。夹在 1..16：防止设备报错返回 0 或虚高值。 */
        private val CPU_COUNT =
            Runtime.getRuntime().availableProcessors().coerceIn(1, 16)

        /**
         * 帧间并行度：同时最多几帧在"方向补偿 + JPEG 编码"流水线里跑。
         * 取"核数的一半"——另一半留给 UI 线程、Dart 线程、相机采集线程和系统，
         * 否则画面是流畅了但界面会卡、取帧也会被拖慢。
         * 夹在 1..4：上限 4 是因为相机出帧本身就 ≤30fps，4 路已经足够吃满，
         * 再多只会拉长单帧延迟（延迟 = 首帧处理时间，与吞吐无关）。
         */
        private val PIPELINE_WORKERS = (CPU_COUNT / 2).coerceIn(1, 4)

        /**
         * JPEG 质量。
         *
         * 上行链路是【有损】的：每帧画面都要压成 JPEG 才发出去。
         * 为什么不发原始数据：1280x720 的 NV21 一帧就是 1.38 MB，
         * 24 fps 下 33 MB/s —— 手机端编码、WiFi、PC 端解码三边都吃不消；
         * 压成 JPEG 后一帧约 100~180 KB，只有 2.4~4.3 MB/s。
         * 代价就是清晰度：这是实时流绕不开的取舍。
         *
         * 质量值怎么定的：
         * 【v3.12】60 → 75：60 在 720p 上块效应明显（文字、网格、树叶处最扎眼）。
         * 【v3.13】75 → 90：换成 libjpeg-turbo 之后编码从 51ms 降到 24ms，
         *   而一帧的预算是 41ms（1/24 秒）—— 余量是实打实空出来的，
         *   没有理由不把它花在画质上。90 大约涨到 28ms，仍在预算内；
         *   体积 100KB → 约 180KB（4.3MB/s），局域网毫无压力。
         *   再往上（95+）收益已经很难看出来，体积却还在一路涨，停在这里。
         *
         * 带宽真吃紧时的正确做法是调低【画质档位】（界面下拉框），
         * 而不是让每一档都糊 —— 档位仍只取设备上报的最高档，代码不替设备降档。
         */
        private const val JPEG_QUALITY = 90

        /** 占位用的空帧：某帧处理失败时用它顶上，防止保序队列卡死 */
        private val EMPTY_JPEG = ByteArray(0)
    }

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

    // ══════════════════════════════════════════════════════════
    // 【v3.9】Camera1 快速路径（只给 HAL1 / LEGACY 设备用）
    // ------------------------------------------------------------------
    // 为什么要有第二条路：实测这台机 `dumpsys media.camera` 打印
    //   Camera module HAL API version: 0x100   ← HAL 是 v1，不是 v3
    // 也就是说 Camera2 在这台机上【没有真正的 HAL 支撑】，全靠 framework 的
    // legacy 兼容层（LegacyCameraDevice）把 Camera1 的预览帧转换出来：
    //   · 它要用一条 GL 线程做缓冲转换（实测 CameraDeviceGLT 单独吃了 0.97 核）；
    //   · CONTROL_AE_TARGET_FPS_RANGE 这类控制它基本不认 —— 我们下发了 (30,30)，
    //     相机照样只给 10fps，且不随环境亮度变化、不随我们处理速度变化。
    //
    // 换成 Camera1 直连 HAL1 之后：
    //   · setPreviewFpsRange(30000,30000) 是 HAL1 自己的原生参数，认；
    //   · 回调直接给 NV21 —— 连我们自己的 yuvToNv21 都省了（conv 9ms → 0）；
    //   · 没有 GL 转换线程那一个核的开销。
    //
    // ⚠ 分辨率/帧率档位【完全不变】，仍然由 Dart 从设备能力清单挑出来传进来，
    //   只是不再绕兼容层 —— 这不是"降档"，是"换一条不打折的路"。
    // ══════════════════════════════════════════════════════════
    @Suppress("DEPRECATION")
    private var cam1: android.hardware.Camera? = null
    private var cam1Thread: HandlerThread? = null
    private var cam1Handler: Handler? = null
    // 离屏"预览承载"。Camera1 不挂一个承载就不出帧，而我们不需要真的显示。
    // ⚠ 必须用一个字段【持有引用】：SurfaceTexture 靠 finalize 释放显存，
    // 只 new 出来不存的话随时可能被 GC 回收 → 相机拿到一个已释放的纹理，
    // 表现是"预览跑一会儿就报错/黑屏"，而且很难复现。
    //
    // 【v3.11】拿到 Flutter 纹理注册表后，这个"承载"不再是丢弃画面的黑洞，
    // 而是一块 Flutter 能直接采样的 GPU 纹理（见 previewEntry）。只有注册表
    // 不可用时才退回纯离屏的 SurfaceTexture（那时预览走老 JPEG 解码路径）。
    private var cam1DummySurface: SurfaceTexture? = null

    // ══════════════════════════════════════════════════════════
    // 【v3.11】预览走 GPU 纹理：彻底干掉"每帧解码一张 JPEG"
    // ------------------------------------------------------------------
    // 改之前预览的链路是这样的（每帧都要全走一遍）：
    //   HAL 出 NV21 → CPU 压 JPEG(51ms) → 传到 Dart → 【Dart 解码成
    //   960×720 的 RGBA 位图（约 2.7MB）】→ 再缩放 → 上传纹理 → 下一帧丢弃。
    // 每秒 24 次 × 2.7MB 位图分配，A53 上光解码就吃掉一个核，还带 GC 抖动 ——
    // 这就是"预览看着卡"的根源（采集那边的帧率数字反而是正常的）。
    //
    // 改之后：HAL → GPU 纹理 → Flutter 光栅化。相机本来就要往某个 Surface 送
    // 预览帧（Camera1 不挂承载根本不出帧），我们只是把那个"丢弃画面的黑洞"
    // 换成 Flutter 注册的纹理 —— 【硬件多做的事为零】，省掉的是整套
    //   JPEG 编码 → 跨线程传输 → Dart 解码 → 位图分配 → GC
    // 预览帧率从此不再受 JPEG 编码(51ms/帧)拖累，也不再跟采集抢 CPU。
    //
    // 方向不在这里处理：纹理里是传感器原始朝向，摆正交给 Dart 的
    // RotatedBox/Transform（GPU 合成，免费），与 PC 端 orient 标记同源。
    // ══════════════════════════════════════════════════════════
    private var previewEntry: TextureRegistry.SurfaceTextureEntry? = null

    /**
     * 当前预览纹理的 id，交给 Dart 的 Texture(textureId:) 显示。
     * 返回 null = 这台机没走纹理通道，Dart 侧要退回 JPEG 解码的老预览。
     */
    fun previewTextureId(): Long? = previewEntry?.id()

    /**
     * 【v3.11】预览纹理的"使用说明书"：id + 摆正方式 + 实际像素尺寸。
     * 一次把三样一起给 Dart，省三次跨语言调用，也保证三个值同源
     * （都是相机这一刻的状态，不会因为分多次调用而读到中间态）。
     *
     *   id     —— Texture(textureId:) 用
     *   orient —— 与上行 JPEG 的方向标记【同一套编码】（见 orientFlags）：
     *             bit0~1 顺时针转几个 90°，bit2 是否水平镜像。
     *             纹理里是传感器原始朝向，摆正交给 Dart 的 RotatedBox/Transform，
     *             在 GPU 合成阶段完成，与 PC 端 orient 的逻辑一致。
     *   w/h    —— 【HAL 回读之后的实际尺寸】：个别机器会把请求尺寸悄悄改成
     *             最近的一档，用它算宽高比才不会被拉伸。
     *
     * 返回 null = 没有纹理通道。
     */
    fun previewTextureInfo(): Map<String, Any>? {
        val entry = previewEntry ?: return null
        return mapOf(
            "id" to entry.id(),
            "orient" to orientFlags(),
            "width" to currentWidth,
            "height" to currentHeight,
        )
    }
    /** 回调缓冲数量：够 PIPELINE_WORKERS 帧同时在飞 + 相机自己手里再拿几张 */
    private val cam1BufferCount = PIPELINE_WORKERS + 3

    // 【v3.8.2】帧处理线程池：压缩不在采集线程上做，避免拖慢取帧。
    // 原来是「单线程 + jpegBusy 互斥门」——不管这台机有多少核，一次只跑 1 帧，
    // 一帧 82ms 期间其余核全在睡觉，实测吞吐只有 6fps。
    // 现在改成 PIPELINE_WORKERS 路并行（核数的一半，见 companion）：
    // 单帧耗时不变但吞吐 ×N（帧与帧之间没有数据依赖，天然可并行）。
    private val compressExecutor: ExecutorService =
        Executors.newFixedThreadPool(PIPELINE_WORKERS)

    // ── 性能统计（v3.8.1 建立 / v3.8.2 扩展）：每 2 秒打一行 CamPerf ──
    // v3.8.2 起改为多帧并行，这些计数器会被多个线程同时累加 → 用 Atomic 或
    // 在打印时加锁。这里统一用 LongAdder（高并发累加比 AtomicLong 更快）。
    private val perfFrames = LongAdder()        // 窗口内完成压缩的帧数
    private val perfJpegNs = LongAdder()        // JPEG 编码累计耗时
    private val perfTotalNs = LongAdder()       // 单帧进流水线到出 JPEG 的墙钟耗时
    // 【v3.8.5】onImageAvailable 被回调的【原始次数】（取帧之前就计数）。
    // 它和 perfCamArrived 的差值能一锤定音地区分两种完全不同的瓶颈：
    //   · cb ≈ cam ≈ 10fps → 相机 HAL 真的只出 10fps，改我们自己的代码没用，
    //     只能靠降分辨率（Dart 侧自适应降档）绕开；
    //   · cb ≈ 30fps 而 cam ≈ 10fps → 帧在到达时被 acquireLatestImage 合并掉了
    //     （回调线程来不及取），瓶颈在回调线程，是代码问题、可修。
    private val perfCbInvoked = LongAdder()
    private val perfCamArrived = LongAdder()    // 【v3.8.2】相机实际送到采集线程的帧数
    private val perfConvNs = LongAdder()        // 【v3.8.4】YUV→NV21 拷贝累计耗时
    private val perfDropped = LongAdder()       // 【v3.8.2】因流水线占满而被丢掉的帧数
    private var perfLastPrint = 0L              // 上次打印时刻（nanoTime）
    private val perfPrintLock = Any()           // 保护 perfLastPrint（多线程会同时到达）


    // 【v3.8.2】并发门：还在流水线里的帧数。原来是 boolean 互斥（一次只 1 帧），
    // 现在允许最多 PIPELINE_WORKERS 帧同时在飞 —— 满了才丢帧（保实时、不排队）。
    private val inFlight = AtomicInteger(0)

    // ── 保序输出（v3.8.2）──────────────────────────────────────────
    // 多帧并行后各帧完成时间会有先后差异，直接 onFrame 会出现"画面回跳"。
    // 做法：每帧在采集线程领一个自增序号，完成后进 pendingFrames 暂存，
    // 只按序号从小到大的顺序往外发；早到的帧等前面的补齐后再一起发出。
    private val frameSeq = AtomicLong(0)
    private var nextEmitSeq = 0L                       // 下一个该发出的序号
    private val pendingFrames = TreeMap<Long, ByteArray>() // 早到的帧（按序号有序）
    private val emitLock = Any()                       // 保护上面两个字段

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

    /** Camera1 探测结果：设备自报的预览尺寸表 + 自报的帧率上界（fps） */
    private data class Cam1Caps(val sizes: List<Size>, val maxFps: Int)

    /**
     * 【v3.12】用 Camera1 直接问设备：这颗镜头能跑哪些预览尺寸、最高多少帧。
     *
     * 只给 HAL1(LEGACY) 设备用 —— 那些机器上 Camera2 是兼容层，清单不可信
     * （本机实测：Camera2 最大只报 960×720，设备真实能力是 1280×720）。
     *
     * 返回 null 表示"问不到"（没权限 / 相机正被占用 / HAL 怪癖），
     * 调用方会回退到 Camera2 的清单 —— 探测失败不影响开相机，只是档位表
     * 可能不全，绝不会因此开不了摄像头。
     *
     * ⚠ 必须在【相机没被占用】时问：Camera1 的 open 是独占的，采集进行中
     * 再 open 会抛异常（这里 catch 住返回 null）。所以只在 App 刚连上、
     * 还没开硬件的探测阶段调用（Dart 侧 ensureCaps 只探一次，见 _capsReady）。
     */
    @Suppress("DEPRECATION")
    private fun camera1Caps(camId: String): Cam1Caps? {
        val idx = camId.toIntOrNull() ?: return null
        // 没授权就不碰硬件 —— 免得在某些 ROM 上弹异常日志甚至崩溃
        if (context.checkSelfPermission(android.Manifest.permission.CAMERA) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return null

        var cam: android.hardware.Camera? = null
        return try {
            cam = android.hardware.Camera.open(idx)
            val p = cam.parameters
            val sizes = p.supportedPreviewSizes?.map { Size(it.width, it.height) }
            // 帧率：HAL1 用"千分之一 fps"为单位的区间表，取所有区间的最大上界
            var hi = 0
            val ranges = p.supportedPreviewFpsRange
            if (ranges != null) {
                for (r in ranges) if (r.size >= 2 && r[1] > hi) hi = r[1]
            }
            if (sizes.isNullOrEmpty()) null else Cam1Caps(sizes, hi / 1000)
        } catch (e: Exception) {
            Log.i("CamPerf", "Camera1 能力探测不可用（$camId）：" + e.javaClass.simpleName)
            null
        } finally {
            try {
                cam?.release()
            } catch (_: Exception) {
            }
        }
    }

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
                // ── 这颗镜头自报的帧率上限（兜底用，仍然来自设备）──────────────
                // 下面每个尺寸都会去查 getOutputMinFrameDuration 算最高帧率，
                // 但个别 HAL 会返回 0 / 抛异常。那种情况下不能用常量 30 顶上
                // （那是代码编的），而要用设备自己声明的"我最高能跑多少"：
                // CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES 就是设备给的区间表。
                // 只有连这张表都拿不到（极老的 HAL1 设备）才退到 30 ——
                // 那已经不是"编造"，而是"设备什么都不肯说"时的最后手段。
                var aeHi = 0
                try {
                    val ranges = ch.get(
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                    )
                    if (ranges != null) {
                        for (r in ranges) if (r.upper > aeHi) aeHi = r.upper
                    }
                } catch (_: Exception) {
                    // 拿不到就保持 0，下面会退到常量
                }
                // 【v3.12】先问设备：这颗头的 Camera2 是真 HAL 还是兼容层？
                // LEGACY → 下面是 framework 模拟出来的 Camera2，尺寸表不可信，
                // 要改用 Camera1 的参数表（见 camera1Caps）。
                val level = try {
                    ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
                } catch (_: Exception) {
                    null
                }
                val legacy =
                    level == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY

                // ── 【v3.12】HAL1(LEGACY) 设备改用 Camera1 的尺寸表 ──────────
                // 实测本机：Camera2 的 YUV 清单最大只报 960×720，而设备真实的
                // `preview-size-values` 最大是 1280×720 —— 于是"自动最高档"
                // 选出来的其实是次高档，画面白白少 33% 像素（这就是"清晰度差"
                // 的根因）。原因：HAL1 设备上 Camera2 只是 framework 的兼容层，
                // 它给的 stream configuration map 并不等于硬件真正能跑的预览尺寸。
                // 我们本来就走 Camera1 采集，直接用 Camera1 的
                // supportedPreviewSizes —— 同样是【设备自己上报】的，且就是
                // 采集中真实生效的那张参数表，最准。拿不到就照旧用 Camera2 清单。
                val c1 = if (legacy) camera1Caps(id) else null
                // 帧率同理：HAL1 的 supportedPreviewFpsRange 比兼容层的
                // AE_TARGET_FPS_RANGES 更贴近实际能锁住的帧率。
                val deviceMaxFps = when {
                    c1 != null && c1.maxFps > 0 -> c1.maxFps
                    aeHi > 0 -> aeHi
                    else -> 30
                }

                // 取设备给的尺寸清单。正常情况下 YUV_420_888 一定有；
                // 万一某台机器报空，退到"预览尺寸表"（SurfaceTexture）——
                // 那同样是设备自己声明的，不是我们编的。
                var yuvSizes: Array<Size>? = null
                if (c1 != null && c1.sizes.isNotEmpty()) {
                    yuvSizes = c1.sizes.toTypedArray()
                }
                if (yuvSizes.isNullOrEmpty()) {
                    yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888)
                }
                if (yuvSizes.isNullOrEmpty()) {
                    yuvSizes = map.getOutputSizes(SurfaceTexture::class.java)
                }
                val all = yuvSizes
                    // ============================================================
                    // v3.8.2：【设备支持到多少就报多少】—— 不再有任何"替设备做主"
                    // 的画质封顶（此前误设的 1080p 上限会把能跑更高档的机器按着）。
                    // 最高档由 Dart 侧自动挑（面积最大的一档），想降档就在下拉框手选。
                    // ============================================================
                    // 只留两道【防异常】安全阀，都与机型无关：
                    //  1) 长边 ≤4096：个别 HAL 会把"静止拍照尺寸"（如 8000×6000）
                    //     混进视频流清单，那种尺寸做连续取流会直接 OOM。
                    //  2) 宽高均为偶数：NV21 色度是 2×2 采样，奇数尺寸会让色度
                    //     采样错位（画面泛绿/条纹）。正常设备都是偶数，只挡畸形值。
                    // ⚠ 必须用 maxOf/minOf 判断：少数设备按【竖屏】报尺寸（2160×3840）。
                    .filter {
                        maxOf(it.width, it.height) <= 4096 &&
                                it.width % 2 == 0 && it.height % 2 == 0
                    }
                    .sortedByDescending { it.width.toLong() * it.height }

                // ── 档位抽样：最多报 12 档，但必须【两头都有】──────────────
                // 直接 take(12) 拿到的永远是最高的 12 档，低分辨率档会被挤掉，
                // 用户在弱网 / 省电 / 嫌卡的场景下想手动降档就没得选了。
                // 所以：头 8 档（含最高档）+ 中间均匀抽 3 档 + 最低档（必留）。
                val headCount = minOf(8, all.size)
                val picked = ArrayList(all.take(headCount))
                val rest = all.drop(headCount)
                if (rest.isNotEmpty()) {
                    val mid = rest.dropLast(1) // 最低档单独处理，保证一定入选
                    val step = maxOf(1, (mid.size + 2) / 3)
                    var i = 0
                    while (i < mid.size && picked.size < 11) {
                        picked.add(mid[i])
                        i += step
                    }
                    picked.add(rest.last()) // 最低档：极端弱网/省电场景的兜底选项
                }

                val sizes = picked
                    .map {
                        val minDur = try {
                            // 该尺寸下"两帧之间最少要间隔多少纳秒" → 换算最高帧率
                            map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, it)
                        } catch (_: IllegalArgumentException) {
                            -1L // 查不到：下面改用设备自报的 deviceMaxFps
                        }
                        // 帧率只认两个来源，且优先设备按尺寸报的：
                        //   ① 该尺寸自己的 minFrameDuration（最准）
                        //   ② 设备声明的 AE 帧率区间上界（尺寸查不到时）
                        // 上限 240 只挡 HAL 报出的畸大值，下限 1 挡 0fps（传 0
                        // 会让原生不出帧）。不再有"统一按 30 封顶"这种替设备做主。
                        val maxFps = if (minDur > 0)
                            (1_000_000_000.0 / minDur).toInt().coerceIn(1, 240)
                        else deviceMaxFps.coerceIn(1, 240)
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

        // 【v3.8.3】尺寸必须【由上层从设备能力清单里挑出来】再传进来。
        // 收到 0 或负数说明上层没探到档位就调了开相机 —— 这属于流程错误，
        // 直接报 BAD_SIZE 让它显形，绝不用任何写死的尺寸硬开。
        if (width <= 0 || height <= 0 || fps <= 0) return "BAD_SIZE"

        this.onFrame = onFrame
        this.currentFacing = facing
        this.currentWidth = width
        this.currentHeight = height
        // v3.8：帧率不再硬性封顶 30fps —— 设备能力探测报多少 fps，这里就用多少，
        // 由 Dart 侧传下来的 maxFps 驱动（"换个手机就自动跟着变"）。
        // 这里只做数值合法性收边（1~240），不再替设备做主。
        this.currentFps = fps.coerceIn(1, 240)

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

        // 【v3.9】先问设备：这颗头的 Camera2 是真 HAL 还是兼容层？
        // LEGACY = framework 用 LegacyCameraDevice 模拟出来的 Camera2
        //（这台机 HAL 是 v1，实测 Camera module HAL API version: 0x100）。
        // 那种情况下走 Camera1 直连 HAL 才拿得到正常帧率，见上面字段注释。
        val level = try {
            cameraManager.getCameraCharacteristics(camId).get(
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL
            )
        } catch (_: Exception) {
            null
        }
        val legacy = level == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY
        Log.i(
            "CamPerf",
            "start facing=" + facing + " hwLevel=" + level + " legacy=" + legacy +
                    " → " + (if (legacy) "Camera1(原生HAL1)" else "Camera2") +
                    " " + width + "x" + height + "@" + currentFps
        )
        if (legacy) {
            // 兜底：Camera1 万一在这台机上起不来（罕见 HAL 怪癖），
            // 绝不让用户"摄像头彻底打不开" —— 退回原来那条能用的 Camera2 路。
            val err1 = startCamera1(camId)
            if (err1 == null) return null
            Log.w("CamPerf", "Camera1 启动失败($err1)，回退 Camera2 兼容层")
        }

        // 第二步：起一条后台消息线程。
        // Camera2 要求回调在某个 Handler 的线程上执行；放在独立线程
        // 就不阻塞界面（Flutter UI）线程。
        val thread = HandlerThread("cam-bg")
        thread.start()
        bgThread = thread
        bgHandler = Handler(thread.looper)

        // 第三步：建 ImageReader —— 相机帧的"取件柜"。
        // v3.8.2：槽位从 2 提到 PIPELINE_WORKERS+2。
        // 原来只有 2 个槽，流水线多路并行时柜子不够用 → 相机会因为"取件柜满了"
        // 反过来降速（backpressure），这也是实测只有 6fps 的一部分原因。
        // 我们每取一张都要 close() 归还，配合丢帧策略保实时。
        //
        // 槽位数按分辨率自适应（因为现在不再封顶 1080p，可能遇到 4K）：
        // 单帧 YUV 内存 = w*h*1.5 字节，4K 时一帧就 12.4MB —— 槽位开满会吃
        // 掉几十 MB 的 native 内存。所以大分辨率时少开一个槽（仍 ≥ 并行度+1，
        // 否则又会造成 backpressure）。
        val framePx = currentWidth * currentHeight
        val slots = if (framePx > 8_000_000) PIPELINE_WORKERS + 1 else PIPELINE_WORKERS + 2
        imageReader = ImageReader.newInstance(
            currentWidth, currentHeight, ImageFormat.YUV_420_888, slots
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
            // 【v3.8.5】先记"HAL 叫了我几次"，取帧成功与否都算（见字段注释）
            perfCbInvoked.increment()
            // v3.8.4：占满判断挪到【取帧之前】—— 原来先取出再判断，
            // 等于每次都白拿一张（还占着一个取件柜槽位）。
            if (inFlight.get() >= PIPELINE_WORKERS) {
                // 流水线车道都占满了 → 这一帧丢掉，绝不排队（宁可跳帧也不堆延迟）
                r.acquireLatestImage()?.close()
                perfDropped.increment()
                return@setOnImageAvailableListener
            }
            // 取最新一张，旧的直接作废（acquireLatestImage 自带丢旧帧行为）
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            // 【v3.8.2】记"相机到底送了多少帧来" —— 用来区分
            //   "相机本身就出得慢"（如弱光下自动曝光拉长）vs"我们处理慢"。
            perfCamArrived.increment()

            // 领一个序号：并行处理后完成顺序可能打乱，靠它把输出排回原序
            val seq = frameSeq.getAndIncrement()
            inFlight.incrementAndGet() // 占一条流水线车道

            compressExecutor.execute {
                try {
                    // ── 【v3.8.4】YUV→NV21 从回调线程搬进工作线程 ──────────────
                    // 原来这段在 cam-bg 回调里【串行】执行，而它对 960×720 要搬
                    // 上百万字节 —— 回调线程被占住，相机送帧就被整体拖慢。
                    // 证据：CamPerf 显示 cam≈11.7fps，但 drop=0、inFlight 从未
                    // 占满（后面 rotate/jpeg 明明有 4 条空闲车道）→ 慢的正是
                    // "取水"这一串行步骤，不是压缩。
                    // 现在只把 Image 交给工作线程，拷贝 + close 都在那边做；
                    // 取件柜有 6 个槽位，同时持有 PIPELINE_WORKERS 张是安全的。
                    val convStartNs = System.nanoTime()
                    val nv21 = yuvToNv21(image)
                    perfConvNs.add(System.nanoTime() - convStartNs)

                    val frameStartNs = System.nanoTime()
                    // 【v3.10】这里【不再】做方向补偿 —— 编码原始朝向的 NV21，
                    // 方向通过一个标记字节交给 PC 与手机预览各自处理（见 withOrientTag）。
                    val jpeg = nv21ToJpeg(nv21, currentWidth, currentHeight, JPEG_QUALITY)
                    val frameEndNs = System.nanoTime()
                    // 按序号排队输出（并行后完成顺序会乱，这里排回原序）
                    emitOrdered(seq, withOrientTag(jpeg))

                    recordFrameStats(frameStartNs, frameEndNs, currentWidth, currentHeight, "C2")
                } catch (_: Exception) {
                    // 单帧失败无所谓，丢掉继续 —— 但要占位发出去，
                    // 否则保序队列会永远等这个序号，后面所有帧都卡住。
                    emitOrdered(seq, EMPTY_JPEG)
                } finally {
                    // 相机缓冲在工作线程归还同样合法（v3.8.4：拷贝已搬到这里）
                    image.close()
                    inFlight.decrementAndGet() // 归还流水线车道
                }
            }
        }, bgHandler)

        val sessionLatch = CountDownLatch(1)
        var sessionOk = false
        val device = cameraDevice!!
        // 【v3.11】把预览纹理一并挂进会话：相机同时往"取帧柜(ImageReader)"和
        // "预览纹理"送同一批帧，后者由 GPU 直接采样 —— Dart 侧不再解码 JPEG。
        // 拿不到纹理时列表里就只有取帧柜，行为与改动前完全一致。
        val previewSt = acquirePreviewTexture(currentWidth, currentHeight)
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
            cleanup()
            return "SESSION_FAILED"
        }

        // 第六步：发出"持续出帧"请求（repeating request）。
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
            val target = currentFps
            val ranges = try {
                cameraManager.getCameraCharacteristics(camId).get(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                )
            } catch (_: Exception) {
                null
            }
            // 【v3.8.5】把这颗镜头的 Camera2 支持级别打出来。
            // LEGACY / LIMITED 的老设备（如骁龙 435 时代的机型）HAL 通常不吃
            // AE 帧率区间这套控制，帧率由老 HAL 自己定 —— 这类机器上"下发了
            // (30,30) 却只给 10fps"是常态，只能靠降分辨率绕开，别再改请求参数。
            val level = try {
                cameraManager.getCameraCharacteristics(camId).get(
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL
                )
            } catch (_: Exception) {
                null
            }
            Log.i(
                "CamPerf",
                "open facing=" + currentFacing + " hwLevel=" + when (level) {
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "LEGACY"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "LIMITED"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "FULL"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "LEVEL_3"
                    CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "EXTERNAL"
                    else -> level?.toString() ?: "?"
                } + " req=" + currentWidth + "x" + currentHeight + "@" + currentFps
            )
            var bestFit: Range<Int>? = null
            var bestFitWidth = Int.MAX_VALUE
            var fastest: Range<Int>? = null
            if (ranges != null) {
                for (r in ranges) {
                    val lo = r.lower
                    val hi = r.upper
                    if (lo <= target && target <= hi) {
                        val w = hi - lo
                        if (w < bestFitWidth) {
                            bestFitWidth = w
                            bestFit = r
                        }
                    }
                    // 用 ?. 取值再判空，避开 !! 的编译器警告
                    val prevUpper = fastest?.upper
                    if (prevUpper == null || hi > prevUpper) fastest = r
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
        if (!running && cameraDevice == null && cam1 == null) {
            onFrame = null
            return
        }
        running = false
        cleanup()
        cleanup1() // 【v3.9】Camera1 路径也要关（cam1 为空时是空操作）
        onFrame = null
    }

    /**
     * 【v3.9】性能统计与 2 秒一行 CamPerf（Camera1 / Camera2 两条路共用）。
     * 抽成方法是为了让两条采集路径打出【同一份口径】的日志，方便直接对比：
     * 换路径前后看同一行数字就知道有没有变快。
     */
    private fun recordFrameStats(
        frameStartNs: Long,
        frameEndNs: Long,
        cw: Int,
        ch: Int,
        api: String
    ) {
        // out = 真正发出去的帧率；cam = 相机送来的帧率；cb = HAL 叫我们的次数。
        //   · cam≈30 而 out 低  → 我们处理慢（看 rotate/jpeg）
        //   · cb≈30 而 cam 低   → 帧在取帧时被合并，回调线程来不及
        //   · cb≈cam≈10         → 相机真的只出 10fps
        perfFrames.increment()
        // 【v3.10】方向补偿已迁到 PC 端（见 withOrientTag），手机上不再做像素重排，
        // 所以整帧耗时就是 JPEG 编码耗时 —— rotate 这一项恒为 0，留着只为
        // 日志口径不变（看到非 0 就说明有别的开销混进来了）。
        perfJpegNs.add(frameEndNs - frameStartNs)
        perfTotalNs.add(frameEndNs - frameStartNs)

        val winNs = synchronized(perfPrintLock) {
            if (perfLastPrint == 0L) {
                perfLastPrint = frameEndNs; 0L
            } else if (frameEndNs - perfLastPrint >= 2_000_000_000L) {
                val w = frameEndNs - perfLastPrint
                perfLastPrint = frameEndNs
                w
            } else 0L
        }
        if (winNs <= 0L) return
        val f = perfFrames.sumThenReset().coerceAtLeast(1)
        val winMs = winNs / 1_000_000.0
        val cam = perfCamArrived.sumThenReset()
        val drop = perfDropped.sumThenReset()
        val cb = perfCbInvoked.sumThenReset()
        Log.i(
            "CamPerf",
            "api=" + api +
                    " out=" + (f * 1000.0 / winMs).format1() + "fps" +
                    " cam=" + (cam * 1000.0 / winMs).format1() + "fps" +
                    " cb=" + (cb * 1000.0 / winMs).format1() + "fps" +
                    " drop=" + drop +
                    " conv=" + (perfConvNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " jpeg=" + (perfJpegNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " total=" + (perfTotalNs.sumThenReset() / f / 1_000_000.0).format1() + "ms" +
                    " size=" + cw + "x" + ch
        )
    }

    /**
     * 【v3.9】Camera1 直连 HAL1 的采集路径（只给 LEGACY 设备用）。
     * 与 Camera2 路径共用同一套下游：nv21ToJpeg → withOrientTag → emitOrdered → onFrame。
     * 差别只有两处：① 回调直接给 NV21，不用再转；② 帧率用 HAL1 原生参数锁。
     */
    @Suppress("DEPRECATION")
    private fun startCamera1(camId: String): String? {
        val id = camId.toIntOrNull() ?: return "NO_CAMERA"

        // Camera1 的回调会投递到【调用 open() 的那条线程的 Looper】上，
        // 所以必须在后台线程里 open —— 否则每帧都砸在主线程上。
        val thread = HandlerThread("cam1-bg")
        thread.start()
        cam1Thread = thread
        cam1Handler = Handler(thread.looper)

        var opened: android.hardware.Camera? = null
        var openError: String? = null
        val latch = CountDownLatch(1)
        cam1Handler?.post {
            opened = try {
                android.hardware.Camera.open(id)
            } catch (e: Exception) {
                openError = "OPEN_ERROR"
                null
            }
            latch.countDown()
        }
        if (!latch.await(3, TimeUnit.SECONDS) || opened == null) {
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return openError ?: "OPEN_ERROR"
        }
        val cam = opened!!

        // ── 参数：分辨率 / 格式 / 帧率 ──────────────────────────
        // 全部来自设备支持表，尺寸由上层从能力清单挑好传进来，这里不替设备做主。
        val params = cam.parameters
        params.setPreviewSize(currentWidth, currentHeight)
        params.previewFormat = ImageFormat.NV21

        // 帧率：HAL1 的原生参数是"预览帧率区间"，单位 1/1000 fps。
        // ① 优先 (target,target) 固定区间 —— 下限=上限时相机不许自己往下滑；
        // ② 没有就挑"能容纳目标帧率"的里上界最高的；③ 再没有就挑上界最高的。
        val want = currentFps * 1000
        var chosen: IntArray? = null
        val ranges = try {
            params.supportedPreviewFpsRange
        } catch (_: Exception) {
            null
        }
        if (ranges != null && ranges.isNotEmpty()) {
            for (r in ranges) {
                if (r.size >= 2 && r[0] == want && r[1] == want) {
                    chosen = r
                    break
                }
            }
            if (chosen == null) {
                var best: IntArray? = null
                for (r in ranges) {
                    if (r.size < 2) continue
                    if (r[0] <= want && want <= r[1]) {
                        if (best == null || r[1] > best[1]) best = r
                    }
                }
                if (best == null) {
                    for (r in ranges) {
                        if (r.size < 2) continue
                        if (best == null || r[1] > best[1]) best = r
                    }
                }
                chosen = best
            }
        }
        if (chosen != null) {
            params.setPreviewFpsRange(chosen[0], chosen[1])
            Log.i(
                "CamPerf",
                "Camera1 fpsRange target=" + want + " chosen=(" +
                    chosen[0] + "," + chosen[1] + ") all=" +
                    (ranges?.joinToString(",") { "(${it[0]},${it[1]})" } ?: "?")
            )
        }
        try {
            cam.parameters = params
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return "BAD_SIZE"
        }

        // HAL 有最终解释权：个别机器会把尺寸悄悄改成它支持的最近一档。
        // 必须以【相机回读的实际尺寸】为准 —— 否则回调里 data 是 1280×720
        // 而我们按 960×720 去采样，画面会直接错位/花屏。
        try {
            val actual = cam.parameters.previewSize
            if (actual != null && (actual.width != currentWidth || actual.height != currentHeight)) {
                Log.i(
                    "CamPerf",
                    "Camera1 尺寸被 HAL 调整：" + currentWidth + "x" + currentHeight +
                            " → " + actual.width + "x" + actual.height + "（以实际为准）"
                )
                currentWidth = actual.width
                currentHeight = actual.height
            }
        } catch (_: Exception) {
            // 读不回来就按请求值走，绝大多数机器本来就一致
        }

        // Camera1 必须有个"预览承载"才能出帧。
        // 【v3.11】优先挂 Flutter 注册的纹理 —— 画面直通 GPU，预览零解码；
        // 注册表不可用时才退回离屏空纹理（那时预览走 Dart 侧 JPEG 解码）。
        try {
            val st = acquirePreviewTexture(currentWidth, currentHeight)
                ?: SurfaceTexture(0).also { cam1DummySurface = it }
            cam.setPreviewTexture(st)
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return "SESSION_FAILED"
        }

        // 预分配回调缓冲：不预分配的话 HAL 每帧 new 一个 ~1MB 数组 → GC 抖动。
        val bufSize = currentWidth * currentHeight * 3 / 2
        for (i in 0 until cam1BufferCount) cam.addCallbackBuffer(ByteArray(bufSize))

        cam.setPreviewCallbackWithBuffer { data, camera ->
            perfCbInvoked.increment()
            if (inFlight.get() >= PIPELINE_WORKERS) {
                // 流水线满了：这一帧放弃，但缓冲必须立刻还回去，
                // 否则相机手里的缓冲越来越少 → 反过来把帧率压下去（背压）。
                perfDropped.increment()
                camera.addCallbackBuffer(data)
                return@setPreviewCallbackWithBuffer
            }
            perfCamArrived.increment()
            val seq = frameSeq.getAndIncrement()
            inFlight.incrementAndGet()
            compressExecutor.execute {
                try {
                    val frameStartNs = System.nanoTime()
                    // 注意：这里直接用回调给的 NV21（data），不再经过 yuvToNv21
                    // —— Camera1 给的就是 NV21。
                    //
                    // 【v3.13】优先让原生一次产出"方向标记 + JPEG"：标记字节直接
                    // 写进缓冲区头部，省掉下面 withOrientTag 那次整帧拷贝
                    // （720p 一帧约 100 KB，24 fps 就是每秒 2.4 MB 白拷 + 一次
                    // 数组分配）。拿不到才走老的「编码 + 再套标记」两步。
                    val payload = JpegCodec.tryEncodeTagged(
                        data, currentWidth, currentHeight, JPEG_QUALITY, orientFlags()
                    ) ?: withOrientTag(
                        nv21ToJpeg(data, currentWidth, currentHeight, JPEG_QUALITY)
                    )
                    val frameEndNs = System.nanoTime()
                    emitOrdered(seq, payload)
                    recordFrameStats(frameStartNs, frameEndNs, currentWidth, currentHeight, "C1")
                } catch (_: Exception) {
                    emitOrdered(seq, EMPTY_JPEG)
                } finally {
                    // 缓冲在【处理完之后】才还 —— 还早了相机会往这块内存里写下帧，
                    // 正在读它的 JPEG 编码器就会读到半新半旧的画面。
                    camera.addCallbackBuffer(data)
                    inFlight.decrementAndGet()
                }
            }
        }

        return try {
            cam.startPreview()
            cam1 = cam
            running = true
            null
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            "SESSION_FAILED"
        }
    }

    /**
     * 【v3.11】申请一块 Flutter 预览纹理（尺寸按当前实际生效的采集尺寸）。
     * 返回 null 表示"这场没有纹理通道"，调用方应退回离屏承载。
     *
     * 尺寸要用【HAL 回读之后的实际尺寸】：个别机器会把请求的尺寸悄悄改成
     * 它支持的最近一档，纹理缓冲尺寸对不上会造成画面拉伸/裁切。
     */
    private fun acquirePreviewTexture(w: Int, h: Int): SurfaceTexture? {
        val reg = textureRegistry ?: return null
        return try {
            releasePreviewTexture()
            val entry = reg.createSurfaceTexture()
            previewEntry = entry
            val st = entry.surfaceTexture()
            // 必须显式声明缓冲尺寸：不设的话部分 HAL 会按默认的小尺寸写入，
            // Flutter 端看到的就是一张被拉伸/裁切的画面。
            st.setDefaultBufferSize(w, h)
            Log.i("CamPerf", "预览纹理就绪 id=" + entry.id() + " " + w + "x" + h)
            st
        } catch (e: Exception) {
            // 纹理拿不到不是致命错误 —— 预览退回 JPEG 解码路径，采集照常
            Log.w("CamPerf", "预览纹理创建失败，退回 JPEG 预览: " + e)
            releasePreviewTexture()
            null
        }
    }

    /** 释放预览纹理（切换镜头/停止采集时调用；entry 已被置空则为空操作） */
    private fun releasePreviewTexture() {
        try {
            previewEntry?.release()
        } catch (_: Exception) {
        }
        previewEntry = null
    }

    /** Camera1 路径的清理（与 cleanup() 互不干扰：cam1 为空时全是空操作） */
    @Suppress("DEPRECATION")
    private fun cleanup1() {
        try {
            cam1?.setPreviewCallback(null)
        } catch (_: Exception) {
        }
        try {
            cam1?.stopPreview()
        } catch (_: Exception) {
        }
        try {
            cam1?.release()
        } catch (_: Exception) {
        }
        cam1 = null
        try {
            cam1DummySurface?.release()
        } catch (_: Exception) {
        }
        cam1DummySurface = null
        releasePreviewTexture() // 【v3.11】预览纹理也要还回去
        try {
            cam1Thread?.quitSafely()
        } catch (_: Exception) {
        }
        cam1Thread = null
        cam1Handler = null
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
        releasePreviewTexture() // 【v3.11】预览纹理也要还回去
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
        } else if (yPlane.pixelStride == 1) {
            // v3.8.1：有行 padding 但像素连续 —— 逐行整块拷贝。
            // 原来这里逐字节循环（w*h ≈ 69 万次 JNI 边界读），~15ms/帧；
            // position+bulk get 把 JNI 往返从 69 万次减到 h 次，~2ms/帧。
            var dst = 0
            for (row in 0 until h) {
                yBuf.position(row * yRowStride)
                yBuf.get(out, dst, w)
                dst += w
            }
        } else {
            // 逐像素拷贝（pixelStride≠1 的罕见布局才走）
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
        // 【v3.8.4 关键优化】这里原本在双重循环里直接 vBuf[i] / uBuf[i] 取字节：
        // 960×720 一帧要取 2 × 360 × 480 ≈ 34.5 万次，而 ByteBuffer 每次索引都带
        // 边界检查（direct buffer 还要多走一次 JNI 读），CamPerf 实测 conv≈40ms
        // 几乎全花在这——它是整条流水线里最慢的一段，比 JPEG 压缩还贵。
        // 改法：先【整块 bulk get 到普通 ByteArray】（每个平面仅 1 次调用），
        // 循环体退化成两次纯内存数组寻址，没有 JNI、没有 ByteBuffer 检查。
        // 部分机型 V 平面比 U 平面短一截（奇数尺寸/驱动怪癖），所以长度和下标
        // 都夹住：越界就重复最后一个字节，绝不崩溃（行为与优化前一致）。
        val uvRows = h / 2
        val uvCols = w / 2
        // 最后一个像素的字节下标 + 1 = 这一帧真正需要的字节数
        val need = (uvRows - 1) * uvRowStride + (uvCols - 1) * uvPixelStride + 1
        val uLen = need.coerceAtMost(uBuf.remaining())
        val vLen = need.coerceAtMost(vBuf.remaining())
        val uArr = ByteArray(uLen)
        val vArr = ByteArray(vLen)
        uBuf.get(uArr, 0, uLen)
        vBuf.get(vArr, 0, vLen)
        val uMax = uLen - 1
        val vMax = vLen - 1
        for (row in 0 until uvRows) {
            val rowOff = row * uvRowStride
            for (col in 0 until uvCols) {
                val uvIndex = rowOff + col * uvPixelStride
                out[dst++] = vArr[if (uvIndex > vMax) vMax else uvIndex]
                out[dst++] = uArr[if (uvIndex > uMax) uMax else uvIndex]
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

    // ==========================================================================
    // 【v3.10】方向补偿迁出手机：只发一个标记，旋转交给 PC
    // --------------------------------------------------------------------------
    // 之前每帧在手机上做像素级重排（orientInto，实测 27~28ms/帧，比 JPEG 编码之外
    // 最贵的一段），还顺带把画面塞进"横向画布"等比缩放 —— 960×720 旋转后塞回
    // 960×720，实际内容只剩 540×720，白白丢掉约 44% 的像素。
    //
    // 现在手机只编码原始朝向的 JPEG，并在帧头带 1 字节标记；旋转与镜像由
    // ① PC 端（解码成 RGBA 后做，PC 算力富余，成本可忽略）
    // ② 手机自己的预览（Flutter 用 RotatedBox/Transform 走 GPU，同样免费）
    // 各自完成。手机上省掉的 28ms/帧 全部还给 CPU、发热与续航。
    // ==========================================================================

    /**
     * 生成 1 字节方向标记：
     *   bit0~1 = 需要【顺时针】转几个 90°（0~3）
     *   bit2   = 1 表示还要水平镜像（前置镜头自拍视角）
     */
    fun orientFlags(): Int {
        val q = rotationNeededDegrees() / 90
        return (q and 0x3) or (if (currentFacing == "front") 0x4 else 0)
    }

    /**
     * 在 JPEG 前面拼 1 字节方向标记，得到"上行帧载荷"。
     * 布局：[flags][JPEG...] —— Dart 侧在它前面再加 4 字节 CAM 魔术头；
     * 手机预览用 `sublistView(bytes, 1)` 零拷贝地跳过这一字节。
     */
    private fun withOrientTag(jpeg: ByteArray): ByteArray {
        // 标记在【编码之后】才取：旋转角会随手机持握方向变，取晚了会滞后一帧。
        val out = ByteArray(jpeg.size + 1)
        out[0] = orientFlags().toByte()
        System.arraycopy(jpeg, 0, out, 1, jpeg.size)
        return out
    }
    /**
     * 按序号把帧排回原序再发出去。
     * 多帧并行后完成顺序会乱，直接发会出现"画面回跳"；这里让早到的帧
     * 等前面的补齐后一起按顺序发出。
     */
    private fun emitOrdered(seq: Long, jpeg: ByteArray) {
        val toSend = ArrayList<ByteArray>(2)
        synchronized(emitLock) {
            pendingFrames[seq] = jpeg
            while (true) {
                val b = pendingFrames.remove(nextEmitSeq) ?: break
                if (b.isNotEmpty()) toSend.add(b) // 空帧=该帧处理失败，跳过不卡队
                nextEmitSeq++
            }
            // 兜底：万一某帧永久丢失（线程被强杀等），队列会越堆越长 → 强制前进
            if (pendingFrames.size > 12) {
                pendingFrames.clear()
                nextEmitSeq = seq + 1
            }
        }
        if (running) for (b in toSend) onFrame?.invoke(b)
    }

    /**
     * NV21 → JPEG 字节数组。
     *
     * 【v3.13】优先走原生 libjpeg-turbo（NEON 加速，见 JpegCodec 的说明）。
     * 它比下面这条 YuvImage 路径快 3~6 倍 —— 这一步原本是整条采集链路里
     * 最贵的一环（720p 上 50~90 ms/帧），也是帧率上不去的直接原因。
     *
     * 原生拿不到结果（so 缺失 / 自检不过 / 尺寸奇数 / 编码报错）时
     * 一律退回 YuvImage：慢一点，但绝不会因为引了原生库就出不了画面。
     */
    private fun nv21ToJpeg(nv21: ByteArray, w: Int, h: Int, quality: Int): ByteArray {
        JpegCodec.tryEncode(nv21, w, h, quality)?.let { return it }

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

    /** 性能日志用：保留 1 位小数（Double 扩展函数，只在本文件可见） */
    private fun Double.format1(): String = String.format("%.1f", this)
}
