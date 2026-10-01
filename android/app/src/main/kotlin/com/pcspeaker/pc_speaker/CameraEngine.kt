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
import android.util.Range
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
class CameraEngine(private val context: Context) {

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
         * 帧内（方向补偿）再切几段并行。
         * 只在核富余时才叠加 —— 否则"帧间并行 × 帧内并行"会过度订阅：
         * 8 核机上 4 帧 × 4 段 = 16 个线程抢 8 个核，反而比不并行更慢。
         * 判据是"帧间用掉之后还剩至少 2 个核"才允许帧内开 2 段。
         */
        private val ROTATE_SLICES =
            if (CPU_COUNT >= PIPELINE_WORKERS * 2 + 2) 2 else 1

        /**
         * JPEG 质量。60 是"网络流"的通用甜点值：肉眼够用、体积适中，
         * 且与机器性能无关（编码耗时主要跟分辨率正相关，跟质量弱相关）。
         */
        private const val JPEG_QUALITY = 60

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

    // 【v3.8.2】帧处理线程池：压缩不在采集线程上做，避免拖慢取帧。
    // 原来是「单线程 + jpegBusy 互斥门」——不管这台机有多少核，一次只跑 1 帧，
    // 一帧 82ms 期间其余核全在睡觉，实测吞吐只有 6fps。
    // 现在改成 PIPELINE_WORKERS 路并行（核数的一半，见 companion）：
    // 单帧耗时不变但吞吐 ×N（帧与帧之间没有数据依赖，天然可并行）。
    private val compressExecutor: ExecutorService =
        Executors.newFixedThreadPool(PIPELINE_WORKERS)

    // 帧内（方向补偿）分段并行用的池，线程数 = ROTATE_SLICES（1 或 2）。
    // 只在核富余时才真的提交任务（见 orientInto），否则这个池是空的、不占资源。
    private val rotatePool: ExecutorService =
        Executors.newFixedThreadPool(ROTATE_SLICES.coerceAtLeast(1))

    // ── 性能统计（v3.8.1 建立 / v3.8.2 扩展）：每 2 秒打一行 CamPerf ──
    // v3.8.2 起改为多帧并行，这些计数器会被多个线程同时累加 → 用 Atomic 或
    // 在打印时加锁。这里统一用 LongAdder（高并发累加比 AtomicLong 更快）。
    private val perfFrames = LongAdder()        // 窗口内完成压缩的帧数
    private val perfRotateNs = LongAdder()      // 方向补偿累计耗时
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

    // ── 采样表缓存（v3.8.2）────────────────────────────────────────
    // orientInto 每帧都要用"目标像素 → 源像素"的映射表。只要
    // (旋转角, 是否镜像, 源尺寸, 画布尺寸) 不变，这张表就是同一张 —— 缓存起来，
    // 避免每帧重算（也不必每帧分配 4 个 IntArray）。
    private var mapKey: String? = null
    private var cachedMaps: Maps? = null
    private val mapLock = Any()

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

    // ── 画布缓冲复用池（v3.8.2）────────────────────────────────────
    // 30fps 时每帧要 new 一个 ~1MB 的 ByteArray，一秒 30MB 垃圾 → GC 抖动。
    // 画布只在原生内部用（编码完就没用了），用完归还复用。
    private val canvasPool = ArrayDeque<ByteArray>()
    private val canvasLock = Any()

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
                val deviceMaxFps = if (aeHi > 0) aeHi else 30

                // 取设备给的尺寸清单。正常情况下 YUV_420_888 一定有；
                // 万一某台机器报空，退到"预览尺寸表"（SurfaceTexture）——
                // 那同样是设备自己声明的，不是我们编的。
                var yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888)
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
                    // ── 方向补偿流水线（每帧在压缩线程做，不碰采集线程）──
                    // 1) 按"传感器安装角 + 手机持握角"把 NV21 转正（竖着拿 → 竖屏正像）
                    // 2) 前置镜头再水平镜像（自拍视角，和手机屏幕预览一致）
                    // 3) 统一装进"横向画布"（PC 会话尺寸，随设备协商出来的档位而变）：
                    //    竖屏内容居中、左右加黑边 —— 电脑端虚拟摄像头格式恒定，
                    //    任何应用打开都不会因分辨率变化而黑屏
                    // ── v3.8.2：方向补偿【一步到位】──────────────────────
                    // 原来是三步串行，每步都 new 一个 ~1MB 数组并遍历整帧：
                    //   rotateNv21(69 万次) → mirrorNv21 → fitNv21Into(39 万次)
                    // 现在合成一次"目标驱动"的采样：直接把源像素旋转+缩放+居中
                    // 写进画布，遍历量从 ~108 万次降到 ~39 万次，还省两次内存分配。
                    val deg = rotationNeededDegrees()
                    val mirror = (currentFacing == "front")
                    // 画布 = 会话协商的横向尺寸（宽≥高）
                    val cw = maxOf(currentWidth, currentHeight)
                    val ch = minOf(currentWidth, currentHeight)

                    val canvas = borrowCanvas(cw * ch * 3 / 2)
                    val afterOrientNs: Long
                    val jpeg: ByteArray
                    try {
                        orientInto(nv21, currentWidth, currentHeight, deg, mirror, cw, ch, canvas)
                        afterOrientNs = System.nanoTime()
                        jpeg = nv21ToJpeg(canvas, cw, ch, JPEG_QUALITY)
                    } finally {
                        returnCanvas(canvas) // 画布用完归还，下帧复用
                    }
                    val frameEndNs = System.nanoTime()
                    // 按序号排队输出（并行后完成顺序会乱，这里排回原序）
                    emitOrdered(seq, jpeg)

                    // ── 性能统计（v3.8.2）：每 2 秒打一行 ──
                    // out = 真正发出去的帧率；cam = 相机送来的帧率。
                    // 两者对比就能一眼看出瓶颈在哪：
                    //   · cam≈30 而 out 低  → 我们处理慢（看 rotate/jpeg）
                    //   · cam 本身就只有 7 → 弱光曝光拉长了，改代码没用
                    perfFrames.increment()
                    perfRotateNs.add(afterOrientNs - frameStartNs)
                    perfJpegNs.add(frameEndNs - afterOrientNs)
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
                    if (winNs > 0L) {
                        val f = perfFrames.sumThenReset().coerceAtLeast(1)
                        val winMs = winNs / 1_000_000.0
                        val cam = perfCamArrived.sumThenReset()
                        val drop = perfDropped.sumThenReset()
                        val cb = perfCbInvoked.sumThenReset()
                        Log.i(
                            "CamPerf",
                            "out=" + (f * 1000.0 / winMs).format1() + "fps" +
                                    " cam=" + (cam * 1000.0 / winMs).format1() + "fps" +
                                    " cb=" + (cb * 1000.0 / winMs).format1() + "fps" +
                                    " drop=" + drop +
                                    " conv=" + (perfConvNs.sumThenReset() / f / 1_000_000.0)
                                .format1() + "ms" +
                                    " rotate=" + (perfRotateNs.sumThenReset() / f / 1_000_000.0)
                                .format1() + "ms" +
                                    " jpeg=" + (perfJpegNs.sumThenReset() / f / 1_000_000.0)
                                .format1() + "ms" +
                                    " total=" + (perfTotalNs.sumThenReset() / f / 1_000_000.0)
                                .format1() + "ms" +
                                    " size=" + cw + "x" + ch
                        )
                    }
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

    // （v3.8.2）旋转/镜像/装裱三个旧函数已被下面的 orientInto() 取代并删除：
    // 它们每帧各做一次全帧遍历、各分配 ~1MB —— 是 6fps 的主因之一。
    // 需要回看实现的话 git 历史里有。
    // ==========================================================================
    // 【v3.8.2】方向补偿：旋转 + 镜像 + 装裱 合并成"一次采样"
    // --------------------------------------------------------------------------
    // 旧做法是三步串行，每步都 new 一个 ~1MB 数组并完整遍历一帧：
    //     rotateNv21(69 万次) → mirrorNv21 → fitNv21Into(39 万次)
    // 新做法：以"目标内容像素"为驱动，直接算出它该采源图的哪个像素，
    // 旋转/镜像/缩放/居中一次算完。遍历量 ~108 万次 → ~39 万次，还省两次分配。
    // ==========================================================================

    /**
     * "目标内容像素 → 源像素"的映射表。
     *
     * 为什么能拆成两张一维表：NV21 旋转 0/90/180/270 后，源坐标 (sx,sy) 对目标
     * (dx,dy) 的依赖总是【可分离】的 —— 一个只跟 dx 有关、另一个只跟 dy 有关
     * （推导见 buildInner/buildOuter）。于是内层循环退化成纯查表，
     * 没有乘除、没有分支，这是本次提速的主要来源。
     *
     * @param inner      按 dx 索引的表（长度 dw）
     * @param outer      按 dy 索引的表（长度 dh）
     * @param innerIsRow true = inner 给的是源"行" sy；false = 给的是源"列" sx
     */
    private data class Maps(
        val innerY: IntArray,
        val outerY: IntArray,
        val innerC: IntArray,
        val outerC: IntArray,
        val innerIsRow: Boolean,
        val dw: Int, val dh: Int,  // 内容区尺寸（已取偶数，满足色度 2×2 对齐）
        val ox: Int, val oy: Int,  // 内容区左上角在画布中的偏移（已取偶数）
    )

    /** 取（或构建）映射表：参数不变时直接复用缓存，避免每帧重算与重新分配。 */
    private fun getMaps(deg: Int, mirror: Boolean, w: Int, h: Int, cw: Int, ch: Int): Maps {
        val key = "$deg|$mirror|$w|$h|$cw|$ch"
        synchronized(mapLock) {
            val c = cachedMaps
            if (key == mapKey && c != null) return c
            val m = buildMaps(deg, mirror, w, h, cw, ch)
            mapKey = key
            cachedMaps = m
            return m
        }
    }

    private fun buildMaps(deg: Int, mirror: Boolean, w: Int, h: Int, cw: Int, ch: Int): Maps {
        val swap = (deg == 90 || deg == 270)
        val rw = if (swap) h else w   // 旋转后的宽
        val rh = if (swap) w else h   // 旋转后的高
        // 等比缩放：长边贴画布，宽高取偶数（色度 2×2 对齐要求）
        val scale = minOf(cw.toFloat() / rw, ch.toFloat() / rh)
        val dw = (rw * scale).toInt() / 2 * 2
        val dh = (rh * scale).toInt() / 2 * 2
        val ox = (cw - dw) / 2 / 2 * 2
        val oy = (ch - dh) / 2 / 2 * 2

        // Y 平面：源 w×h，旋转后 rw×rh，内容 dw×dh
        val innerY = buildInner(deg, mirror, w, h, rw, dw)
        val outerY = buildOuter(deg, w, h, rh, dh)
        // 色度平面：网格整体减半（行字节跨距仍等于 w）
        val innerC = buildInner(deg, mirror, w / 2, h / 2, rw / 2, dw / 2)
        val outerC = buildOuter(deg, w / 2, h / 2, rh / 2, dh / 2)
        // 90/270 时 inner 是"源行"；0/180 时 inner 是"源列"
        return Maps(innerY, outerY, innerC, outerC, swap, dw, dh, ox, oy)
    }

    /** 依赖 dx 的那个源坐标。n=旋转后该轴尺寸, dn=内容区该轴尺寸。 */
    private fun buildInner(deg: Int, mirror: Boolean, w: Int, h: Int, rn: Int, dn: Int): IntArray {
        val out = IntArray(dn)
        for (d in 0 until dn) {
            // 镜像作用在【旋转后的图】上，即 r → rn-1-r（先缩放再翻转）。
            // 注意不能写成"先翻转目标列再缩放"：那样在缩放比例不是 1:1 时
            // 会因整数截断引入最多 1 像素的整体偏移（画面轻微偏一边）。
            val r0 = d * rn / dn
            val r = if (mirror) rn - 1 - r0 else r0
            out[d] = when (deg) {
                0 -> r           // sx = rx
                90 -> h - 1 - r  // sy = h-1-rx
                180 -> w - 1 - r // sx = w-1-rx
                else -> r        // 270: sy = rx
            }
        }
        return out
    }

    /** 依赖 dy 的那个源坐标。 */
    private fun buildOuter(deg: Int, w: Int, h: Int, rn: Int, dn: Int): IntArray {
        val out = IntArray(dn)
        for (d in 0 until dn) {
            val r = d * rn / dn
            out[d] = when (deg) {
                0 -> r           // sy = ry
                90 -> r          // sx = ry
                180 -> h - 1 - r // sy = h-1-ry
                else -> w - 1 - r// 270: sx = w-1-ry
            }
        }
        return out
    }

    /**
     * 把 src(w×h) 旋转 →（前置时）镜像 → 等比居中装裱，结果写进 cw×ch 的画布。
     * 画布由 borrowCanvas() 提供并复用，本函数只负责填内容。
     */
    private fun orientInto(
        src: ByteArray, w: Int, h: Int, deg: Int, mirror: Boolean,
        cw: Int, ch: Int, out: ByteArray
    ) {
        // 画布先涂"视频黑"：Y=16、色度=128（YUV 有限量程下的纯黑，不是 0/0）
        Arrays.fill(out, 0, cw * ch, 16.toByte())
        Arrays.fill(out, cw * ch, out.size, 128.toByte())

        val m = getMaps(deg, mirror, w, h, cw, ch)
        if (m.dw <= 0 || m.dh <= 0) return

        // ── Y 平面：按目标行分段填充（各段写入行互不相交 → 零锁零竞争）──
        fun fillRows(y0: Int, y1: Int) {
            if (m.innerIsRow) {
                // inner = 源行 sy；outer = 源列 sx
                for (dy in y0 until y1) {
                    val sx = m.outerY[dy]
                    var dp = (m.oy + dy) * cw + m.ox
                    val inn = m.innerY
                    for (dx in 0 until m.dw) out[dp++] = src[inn[dx] * w + sx]
                }
            } else {
                for (dy in y0 until y1) {
                    val sRow = m.outerY[dy] * w
                    var dp = (m.oy + dy) * cw + m.ox
                    val inn = m.innerY
                    for (dx in 0 until m.dw) out[dp++] = src[sRow + inn[dx]]
                }
            }
        }

        if (ROTATE_SLICES <= 1) {
            // 核不富余（中低端机常见）：直接在本线程做完。
            // 这时再切段只会增加线程调度和 latch 同步的开销，得不偿失。
            fillRows(0, m.dh)
        } else {
            val chunk = (m.dh + ROTATE_SLICES - 1) / ROTATE_SLICES
            val latch = CountDownLatch(ROTATE_SLICES)
            for (t in 0 until ROTATE_SLICES) {
                val y0 = t * chunk
                val y1 = minOf(m.dh, y0 + chunk)
                if (y0 >= y1) { latch.countDown(); continue } // dh 很小时多出空段
                rotatePool.execute {
                    try {
                        fillRows(y0, y1)
                    } finally {
                        latch.countDown()
                    }
                }
            }
            latch.await()
        }

        // ── 色度平面：数据量只有 Y 的 1/4，并行调度不划算，单线程 ──
        val ySize = w * h
        val cdw = m.dw / 2
        val cdh = m.dh / 2
        if (m.innerIsRow) {
            for (dy in 0 until cdh) {
                val sxc = m.outerC[dy] * 2 // 色度列 → 字节偏移
                var dp = cw * ch + (m.oy / 2 + dy) * cw + m.ox
                val inn = m.innerC
                for (dx in 0 until cdw) {
                    val sRow = ySize + inn[dx] * w
                    out[dp++] = src[sRow + sxc]
                    out[dp++] = src[sRow + sxc + 1]
                }
            }
        } else {
            for (dy in 0 until cdh) {
                val sRow = ySize + m.outerC[dy] * w
                var dp = cw * ch + (m.oy / 2 + dy) * cw + m.ox
                val inn = m.innerC
                for (dx in 0 until cdw) {
                    val si = sRow + inn[dx] * 2
                    out[dp++] = src[si]
                    out[dp++] = src[si + 1]
                }
            }
        }
    }

    /** 取一块可复用的画布缓冲；池里没有合适尺寸就新分配一块。 */
    private fun borrowCanvas(size: Int): ByteArray {
        synchronized(canvasLock) {
            while (canvasPool.isNotEmpty()) {
                val b = canvasPool.removeLast()
                if (b.size == size) return b
            }
        }
        return ByteArray(size)
    }

    /** 归还画布缓冲（30fps 下每帧省掉 ~1MB 的分配，避免 GC 抖动）。 */
    private fun returnCanvas(b: ByteArray) {
        synchronized(canvasLock) {
            // 大分辨率画布少留几块：4K 一块就是 12MB，留 6 块 = 72MB 太浪费
            val cap = if (b.size > 8_000_000) 2 else PIPELINE_WORKERS + 2
            if (canvasPool.size < cap) canvasPool.addLast(b)
        }
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
     * YuvImage 是 Android 自带的编码器（系统层用 libjpeg-turbo）。
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
        rotatePool.shutdownNow() // v3.8.1：旋转并行池一并关掉
    }

    /** 性能日志用：保留 1 位小数（Double 扩展函数，只在本文件可见） */
    private fun Double.format1(): String = String.format("%.1f", this)
}
