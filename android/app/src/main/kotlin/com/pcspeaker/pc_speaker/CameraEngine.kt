package com.pcspeaker.pc_speaker

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Log
import com.pcspeaker.pc_speaker.camera.Camera1Controller
import com.pcspeaker.pc_speaker.camera.Camera2Controller
import com.pcspeaker.pc_speaker.camera.CameraCapabilities
import com.pcspeaker.pc_speaker.camera.CameraOrientation
import com.pcspeaker.pc_speaker.camera.CameraState
import com.pcspeaker.pc_speaker.camera.FramePipeline
import com.pcspeaker.pc_speaker.camera.PreviewTexture
import com.pcspeaker.pc_speaker.camera.VideoCodec
import com.pcspeaker.pc_speaker.camera.VideoCodecCaps
import io.flutter.view.TextureRegistry

/**
 * CameraEngine —— 摄像头的对外门面（Flutter 层只跟它打交道）
 * ----------------------------------------------------------------------------
 * 它自己【不含任何采集细节】，只做三件事：
 *   1. 记住"这次会话要什么"（CameraState）、把帧往哪发（FramePipeline）；
 *   2. 按设备情况选一条采集路径（Camera1 直连 HAL1 / Camera2），起、停、切镜头；
 *   3. 回答 Flutter 的提问：能力清单、预览纹理、当前朝向、手动旋转。
 *
 * 采集细节各自在 camera/ 包下：
 *   CameraCapabilities  问设备"你能跑什么画质"
 *   Camera1Controller   HAL1 直连路径（LEGACY 设备）
 *   Camera2Controller   Camera2 路径
 *   FramePipeline       编码线程池 + 保序输出 + 性能统计
 *   FrameStats          每 2 秒一行 CamPerf 的仪表盘
 *   PreviewTexture      手机端预览用的 GPU 纹理
 *   CameraOrientation   "这一帧该怎么摆正"（只算标记，不做像素旋转）
 *   YuvConverter        像素格式转换 + JPEG 编码
 *   CameraConfig        全局参数（并行度、画质等）
 *
 * 【v3.15】这个文件原来 1600 行，采集、编码、方向、统计、纹理全挤在一起，
 * 改一处要在几百行里找上下文。现在拆成上面这些各司其职的小类，
 * 每个类都能单独读懂，互相之间只通过几个明确的接口打交道。
 */
class CameraEngine(
    private val context: Context,
    textureRegistry: TextureRegistry? = null
) {

    private val cameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    // ── 这一会话的共享零件 ────────────────────────────────────────
    private val state = CameraState()
    private val orientation = CameraOrientation(context, state)
    private val preview = PreviewTexture(textureRegistry)
    private val pipeline = FramePipeline(orientation)
    private val caps = CameraCapabilities(context, cameraManager)

    private val cam1 = Camera1Controller(state, pipeline, preview)
    private val cam2 = Camera2Controller(cameraManager, state, pipeline, preview)

    /** 帧的出口。切镜头时要先记住它，stop→start 之后接着用 */
    private var frameConsumer: ((ByteArray) -> Unit)? = null

    /**
     * Flutter 指定的编码方式。null = 【自动】——按硬件能力选清晰度最高的那种。
     * 界面下拉框里选了具体值就记在这里；下次开相机沿用。
     */
    private var requestedCodec: VideoCodec? = null

    val isRunning: Boolean get() = state.running

    /** 当前镜头朝向："back" 或 "front"（Flutter 层据此显示切换按钮文案） */
    fun facing(): String = state.facing

    // ══════════════════════════════════════════════════════════════
    // 能力探测：告诉 PC "这台手机最高能开什么画质"
    // ══════════════════════════════════════════════════════════════
    /** 详见 CameraCapabilities.probe()：返回 [{facing, sizes:[{width,height,maxFps}]}] */
    fun getCapabilities(): List<Map<String, Any>> = caps.probe()

    // ══════════════════════════════════════════════════════════════
    // 打开相机开始采集
    // ══════════════════════════════════════════════════════════════
    //
    // 返回 null = 成功；返回错误码字符串 = 失败（约定与麦克风 startMic 一致，
    // Flutter 层把错误码翻译成中文提示）。
    fun start(
        facing: String,
        width: Int,
        height: Int,
        fps: Int,
        onFrame: (ByteArray) -> Unit
    ): String? {
        if (state.running) return null // 幂等：已在采集直接算成功

        // 【v3.8.3】尺寸必须【由上层从设备能力清单里挑出来】再传进来。
        // 收到 0 或负数说明上层没探到档位就调了开相机 —— 这属于流程错误，
        // 直接报 BAD_SIZE 让它显形，绝不用任何写死的尺寸硬开。
        if (width <= 0 || height <= 0 || fps <= 0) return "BAD_SIZE"

        frameConsumer = onFrame
        pipeline.consumer = onFrame
        pipeline.enabled = true

        state.facing = facing
        state.width = width
        state.height = height
        // v3.8：帧率不再硬性封顶 30fps —— 设备能力探测报多少 fps，这里就用多少，
        // 由 Dart 侧传下来的 maxFps 驱动（"换个手机就自动跟着变"）。
        // 这里只做数值合法性收边（1~240），不再替设备做主。
        state.fps = fps.coerceIn(1, 240)

        // 【v3.16】选编码方式：没手动指定就按硬件能力挑清晰度最高的那个
        //（available() 已按 H.265 > H.264 > JPEG 排好序）。
        // 拿不到硬件编码器时 useCodec 自己会退回 JPEG 并给出原因，
        // 这里只把结果打进日志 —— 编码方式失败【绝不】连累开相机。
        val picked = requestedCodec
            ?: VideoCodecCaps.available(width, height, state.fps).first()
        val codecErr = pipeline.useCodec(picked, width, height, state.fps)
        Log.i(
            "CamPerf",
            "编码方式 请求=" + (requestedCodec?.name ?: "自动") +
                    " 选中=" + pipeline.codec.name +
                    if (codecErr == null) "" else " 降级原因=$codecErr"
        )

        // 第一步：按朝向找到相机 id（"0" 通常是后置，"1" 前置，但不保证，
        // 正确做法是遍历 characteristics 比对 LENS_FACING）
        val camId = caps.findCameraId(facing) ?: return "NO_CAMERA"

        // 查一下这个镜头的安装角度（查不到按 90 保守处理，绝大多数手机如此）
        state.sensorOrientation = try {
            cameraManager.getCameraCharacteristics(camId)
                .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        } catch (_: Exception) {
            90
        }

        // 【v3.9】先问设备：这颗头的 Camera2 是真 HAL 还是兼容层？
        // LEGACY = framework 用 LegacyCameraDevice 模拟出来的 Camera2
        //（本机 HAL 是 v1，实测 Camera module HAL API version: 0x100）。
        // 那种情况下走 Camera1 直连 HAL 才拿得到正常帧率，见 Camera1Controller。
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
                    " " + width + "x" + height + "@" + state.fps
        )
        if (legacy) {
            // 兜底：Camera1 万一在这台机上起不来（罕见 HAL 怪癖），
            // 绝不让用户"摄像头彻底打不开" —— 退回原来那条能用的 Camera2 路。
            val err1 = cam1.start(camId)
            if (err1 == null) return null
            Log.w("CamPerf", "Camera1 启动失败($err1)，回退 Camera2 兼容层")
        }
        return cam2.start(camId)
    }

    /**
     * 切换前/后置镜头：停掉当前 → 用同样的分辨率/帧率打开另一个。
     * 返回切换后的 facing（"back"/"front"），Flutter 据此更新按钮文案。
     */
    fun switchLens(): String {
        if (!state.running) return state.facing
        val target = if (state.facing == "back") "front" else "back"
        // 没有另一个镜头就别切
        if (caps.findCameraId(target) == null) return state.facing
        val cb = frameConsumer ?: return state.facing
        val w = state.width
        val h = state.height
        val f = state.fps
        stop()
        start(target, w, h, f, cb) // 失败也返回目标朝向？不：以实际为准
        return state.facing
    }

    // ══════════════════════════════════════════════════════════════
    // 编码方式（v3.16）
    // ══════════════════════════════════════════════════════════════

    /**
     * 这台机在给定画质下【可用】的编码方式，按清晰度从高到低排好。
     * 界面下拉框直接用这个列表（JPEG 永远在最后一位，是软件兜底）。
     */
    fun availableCodecs(width: Int, height: Int, fps: Int): List<String> =
        VideoCodecCaps.available(width, height, fps).map { it.name }

    /** 当前实际在用的编码方式名（"JPEG" / "H264" / "H265"） */
    fun currentCodec(): String = pipeline.codec.name

    /**
     * 指定编码方式。传 null = 回到自动（按硬件能力选最高的）。
     * 返回 null = 成功；非空 = 失败原因（比如设备不支持，链路会自动留在 JPEG）。
     *
     * 正在采集时切换也是允许的：编码器会重建，中间一两帧可能为空（发空帧占位），
     * 不会中断采集。
     */
    fun selectCodec(name: String?): String? {
        requestedCodec = if (name == null) null
        else VideoCodec.entries.firstOrNull { it.name == name } ?: return "未知编码方式"
        if (!state.running) return null // 没在采集：记下来，start 时生效

        val target = requestedCodec
            ?: VideoCodecCaps.available(state.width, state.height, state.fps).first()
        return pipeline.useCodec(target, state.width, state.height, state.fps)
    }

    /** 停止采集并释放所有相机资源（幂等：没开就直接返回） */
    fun stop() {
        if (!state.running && !cam2.isActive() && !cam1.isActive()) {
            pipeline.consumer = null
            frameConsumer = null
            return
        }
        state.running = false
        // 先关掉出口：还在流水线里跑的帧不再往外发（否则会"停了还在出画面"）
        pipeline.enabled = false
        cam2.stop()
        cam1.stop() // 【v3.9】Camera1 路径也要关（没开过是空操作）
        // 硬件编码器也要一起停：它是按当前分辨率/帧率建的，留着没意义，
        // 而且占着 SoC 的编码资源。下次 start 会按新的画质重建。
        pipeline.releaseEncoder()
        pipeline.consumer = null
        frameConsumer = null
    }

    /**
     * v3.4.1：手动再顺时针转 90°（0→90→180→270→0 循环）。
     * 只改一个数字，下一帧压缩时自动套用 —— 实时生效、不重启相机。
     * 返回设置后的新角度，Flutter 按钮文案用它。
     */
    fun rotateManual(): Int {
        state.manualRotation = (state.manualRotation + 90) % 360
        return state.manualRotation
    }

    /** 读当前手动偏移角（Flutter 查询/恢复按钮文案用） */
    fun manualRotationDegrees(): Int = state.manualRotation

    /**
     * 【v3.11】预览纹理的"使用说明书"：id + 摆正方式 + 实际像素尺寸。
     * 一次把三样一起给 Dart，省三次跨语言调用，也保证三个值同源
     * （都是相机这一刻的状态，不会因为分多次调用而读到中间态）。
     *
     *   id     —— Texture(textureId:) 用
     *   orient —— 与上行 JPEG 的方向标记【同一套编码】（见 CameraOrientation）：
     *             bit0~1 顺时针转几个 90°，bit2 是否水平镜像。
     *             纹理里是传感器原始朝向，摆正交给 Dart 的 RotatedBox/Transform，
     *             在 GPU 合成阶段完成，与 PC 端 orient 的逻辑一致。
     *   w/h    —— 【HAL 回读之后的实际尺寸】：个别机器会把请求尺寸悄悄改成
     *             最近的一档，用它算宽高比才不会被拉伸。
     *
     * 返回 null = 没有纹理通道（Dart 侧退回 JPEG 解码预览）。
     */
    fun previewTextureInfo(): Map<String, Any>? {
        val id = preview.id() ?: return null
        return mapOf(
            "id" to id,
            "orient" to orientation.orientFlags(),
            "width" to state.width,
            "height" to state.height,
        )
    }

    /** App 退出时调用：关掉采集与压缩线程池 */
    fun dispose() {
        stop()
        pipeline.shutdown()
    }
}
