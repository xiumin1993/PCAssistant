// ============================================================================
// AppDelegate.swift —— iOS 原生层总入口（对应 Android 的 MainActivity.kt）
// ----------------------------------------------------------------------------
// 这个文件把手机变成电脑麦克风 + 电脑摄像头的全部 iOS 原生实现写在一起：
//
//   ┌─ 下行播放：电脑声音 --WebSocket--> Dart --"write"--> AVAudioEngine --> 扬声器
//   ├─ 上行麦克风：话筒 --AVAudioEngine(inputNode)--> PCM s16le --> EventChannel --> Dart --> 电脑
//   └─ 上行摄像头：相机 --AVCaptureSession--> BGRA帧 --> 旋转/镜像/装裱 --> JPEG --> EventChannel --> Dart --> 电脑
//
// 三条"水管"的名字和 Android 完全一致（Dart 层代码一字不用改）：
//   MethodChannel  "com.pcspeaker/audio"   —— 一问一答（开/关/权限/能力探测）
//   EventChannel   "com.pcspeaker/mic_data" —— 原生持续推 PCM 字节块
//   EventChannel   "com.pcspeaker/cam_data" —— 原生持续推 JPEG 帧
//
// Android → iOS 概念对照（新手必读）：
//   AudioTrack        → AVAudioEngine + playerNode（扬声器放音）
//   AudioRecord       → AVAudioEngine + inputNode.installTap（话筒采音）
//   VOICE_COMMUNICATION 音源(自带回声消除 AEC+降噪)
//                     → AVAudioSession.Mode.voiceChat（系统语音链路，同样带 AEC）
//   Camera2 + YuvImage→ AVCaptureSession + CIImage + ImageIO(JPEG)
//   前台服务(常驻通知保活) → UIBackgroundModes=audio（系统级后台音频权限）
//   EventChannel 推送 → FlutterEventSink（必须在主线程调用，与 Android 同规则）
//
// iOS 做不到 / 有意简化的点（都在对应方法处有详细注释）：
//   1. startMicStandby / stopMicStandby / startCamStandby：Android 的前台服务
//      在 iOS 没有对应物 → 实现为"空操作返回成功"；后台保活靠 Info.plist 里的
//      UIBackgroundModes=audio + .playAndRecord 音频会话。
//   2. 相机不能后台采集（iOS 系统硬限制）：App 退到后台画面会停，回前台后
//      本实现会自动重启采集会话补救。
//   3. goHome（按 Home 键回桌面）：iOS 没有这种 API，返回 notImplemented，
//      Dart 侧 audio_service.goHome() 已有 try/catch 静默兜底（已核对）。
//
// 基线 iOS 15；iOS 17 新增的权限 API（AVAudioApplication 系列）用
// if #available(iOS 17.0, *) 保护，老系统走 AVAudioSession 传统 API。
// ============================================================================

import Flutter
import UIKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import CoreMedia

// ── 通道名常量：必须与 Dart/Android 端逐字一致 ────────────────────────────
private let kAudioChannel    = "com.pcspeaker/audio"      // 方法通道（一问一答）
private let kMicDataChannel  = "com.pcspeaker/mic_data"   // 麦克风采样水管（原生→Dart）
private let kCamDataChannel  = "com.pcspeaker/cam_data"   // 摄像头 JPEG 水管（原生→Dart）

// 小工具：把整数夹到 [lo, hi] 区间（等价 Kotlin 的 coerceIn）
private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    return max(lo, min(v, hi))
}

// ============================================================================
// 第一部分：下行播放（电脑 → 手机扬声器）
// ----------------------------------------------------------------------------
// 对应 Android MainActivity 的 setupAudio/writeAudio/stopAudio/releaseAudio。
// 数据格式：Dart 每次 "write" 推来一段 PCM —— 16bit 小端整数、按声道交错排列
// （s16le interleaved），采样率/声道数由 "setup" 决定（默认 48000Hz/2 声道）。
// iOS 的 AVAudioEngine 不认 int16，只认 float32，所以核心工作就是
// 把每个 int16 除以 32768.0 变成 [-1, 1] 的 float32 再喂给播放器。
// （iPhone 的 CPU 是小端序，和 PCM 字节序一致，可直接按 Int16 数组解读）
// ============================================================================
final class DownlinkPlayer {
    private var engine: AVAudioEngine?          // 音频引擎（相当于一条声音流水线）
    private var player: AVAudioPlayerNode?      // 播放节点（相当于 Android 的 AudioTrack）
    private var format: AVAudioFormat?          // 当前 PCM 参数（采样率/声道数）
    private var started = false                 // engine 是否已经跑起来

    // "背压"计数器：已经排进播放队列、还没播完的帧数。
    // Android 用阻塞式 write 天然限速；iOS 的 scheduleBuffer 是"扔进去就不管"，
    // 队列会无限堆积 → 延迟越来越大。所以我们自己封顶：队列里超过 0.5 秒
    // 音频就把新数据丢掉（实时场景宁可丢也不堆延迟）。
    private let pendingLock = NSLock()
    private var pendingFrames = 0
    private var maxPendingFrames = 24_000       // setup 时改成 sampleRate/2

    /// "setup"：按 Dart 给的 sampleRate/channels 重建播放管线。
    /// （与 Android 一致：先释放旧的再建新的；建完不自动开播，等 "start"）
    func setup(sampleRate: Int, channels: Int) {
        release() // 对应 Android setupAudio 里开头的 releaseAudio()

        // Float32、交错式、指定采样率/声道数 —— playerNode 能直接吃这个格式，
        // 采样率和硬件不一致时引擎内部的混音器会自动重采样，不用我们操心。
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(sampleRate),
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true) else { return }

        let eng = AVAudioEngine()
        let p = eng.playerNode // playerNode 是引擎自带的"播放器"节点
        // playerNode → 混音器（用我们的 float32 格式）→ 输出（用硬件原生格式）。
        eng.connect(p, to: eng.mainMixerNode, format: fmt)
        eng.connect(eng.mainMixerNode, to: eng.outputNode,
                    format: eng.outputNode.inputFormat(forBus: 0))
        eng.prepare() // 预热：真正 start 更快、更少爆音

        engine = eng
        player = p
        format = fmt
        maxPendingFrames = max(sampleRate / 2, 1024) // 队列上限 ≈0.5 秒
    }

    /// "start"：开播 / 从暂停中恢复（对应 audioTrack.play()）
    func start() {
        guard let eng = engine, let p = player else { return }
        if !eng.isRunning {
            do { try eng.start() } catch { return } // 起不来就放弃这次
        }
        p.play()
        started = true
    }

    /// "pause"：暂停但保留已排队的音频（对应 audioTrack.pause()）
    func pause() {
        player?.pause()
    }

    /// "stop"：立即停并清空播放队列（对应 audioTrack.stop()）
    func stop() {
        player?.stop() // stop 会丢弃所有已 schedule 未播的 buffer
        pendingLock.lock(); pendingFrames = 0; pendingLock.unlock()
        started = false
    }

    /// "release"：彻底拆掉管线释放资源（对应 audioTrack.release()）
    func release() {
        player?.stop()
        if let eng = engine, eng.isRunning { eng.stop() }
        engine = nil
        player = nil
        format = nil
        started = false
        pendingLock.lock(); pendingFrames = 0; pendingLock.unlock()
    }

    /// "write"：收到一块 PCM s16le 字节 → 转 float32 → 排进播放队列。
    /// 语义对齐 Android：管线还没建好/没开播时静默丢弃（不报错）。
    func write(_ data: Data) {
        guard started, let eng = engine, eng.isRunning,
              let p = player, let fmt = format, fmt.channelCount > 0
        else { return }

        // 帧数 = 字节数 ÷ (每样本2字节 × 声道数)
        let bytesPerFrame = 2 * Int(fmt.channelCount)
        let frames = data.count / bytesPerFrame
        guard frames > 0 else { return }

        // 背压保护：队列已经堆了超过 0.5 秒 → 这块直接丢，保实时
        pendingLock.lock()
        if pendingFrames > maxPendingFrames {
            pendingLock.unlock()
            return
        }
        pendingFrames += frames
        pendingLock.unlock()

        // 建一个 float32 输出缓冲（交错式：所有声道一个样本接一个排着放）
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let chan = buf.floatChannelData?[0] else {
            pendingLock.lock(); pendingFrames -= frames; pendingLock.unlock()
            return
        }
        buf.frameLength = AVAudioFrameCount(frames)

        // 核心转换：int16 ∈ [-32768, 32767] → float32 ∈ [-1, 1)
        // Data 底层就是小端 int16 数组（iOS/ARM 均为小端，直接绑指针零拷贝读）
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            let total = frames * Int(fmt.channelCount)
            for i in 0..<total {
                chan[i] = Float(src[i]) / 32768.0
            }
        }

        // 排队播放；播完后 completionHandler 被回调 → 计数减回去。
        // completionHandler 在音频内部线程回调，所以用锁保护计数。
        p.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            guard let self = self else { return }
            self.pendingLock.lock()
            self.pendingFrames -= frames
            if self.pendingFrames < 0 { self.pendingFrames = 0 }
            self.pendingLock.unlock()
        }
    }
}

// ============================================================================
// 第二部分：上行麦克风（手机话筒 → 电脑虚拟麦克风）
// ----------------------------------------------------------------------------
// 对应 Android 的 startMic/stopMic（AudioRecord + 采集线程）。
// iOS 做法：AVAudioEngine 的 inputNode 上"装一个水龙头"(installTap)，
// 系统每攒够一小段 PCM 就在音频线程回调我们 → 转成 int16 小端 →
// 通过 EventChannel 推给 Dart。
//
// 采样率/声道：麦克风链路里"重采样交给你"（对应 Android 的 startMic 参数，
// 目前 Dart 固定传 48000/1）。inputNode 的原生格式一般是 48kHz float32，
// 若与目标格式一致就直接逐样本转 int16（零开销）；不一致才请
// AVAudioConverter 帮忙重采样/并声道 —— 它能把 float32 直接转成 int16。
//
// 回声消除（啸叫抑制）：Android 用 VOICE_COMMUNICATION 音源 + AEC/NS 效果器；
// iOS 的等价物是把 AVAudioSession.mode 设成 .voiceChat —— 系统会自动走
// "语音处理链路"（回声消除+降噪），并且会参考同一音频会话里扬声器的声音
// （我们的下行播放也是 playAndRecord 同一会话，所以全双工不啸叫）。
// 结论：用 .voiceChat 模式即等价实现，不去调用更易踩坑的
// AVAudioEngine.setVoiceProcessingEnabled（iOS17 起在 AVAudioApplication
// 层也有开关，但都非"平凡可用"，选型决策详见 AppDelegate.configureAudioSession 注释）。
// ============================================================================
final class MicUplink {
    private let engine = AVAudioEngine()        // 麦克风专用引擎（与播放引擎分开，互不打扰）
    private var targetFormat: AVAudioFormat?    // Dart 要求的目标 PCM 格式（int16/交错）
    private var inputFormat: AVAudioFormat?     // inputNode 的原生格式（float32）
    private var converter: AVAudioConverter?    // 仅在两种格式不同才用到
    private var running = false                 // 对应 Android 的 micRunning (AtomicBoolean)
    private let runLock = NSLock()              // 保护 running（采集线程与主线程共享）

    /// 每采到一块 PCM(s16le) 就回调；AppDelegate 里接到 mic_data 水管上。
    /// ⚠️ 回调发生在系统音频线程，推给 Flutter 前必须自己切回主线程。
    var onPcm: ((Data) -> Void)?

    /// 采集状态查询（startMic 的幂等判断用）
    var isRunning: Bool {
        runLock.lock(); defer { runLock.unlock() }
        return running
    }

    /// 对应 Android startMic(sampleRate, channels)：
    /// 返回 nil = 成功；返回字符串 = 错误码（Dart 会翻译成中文提示）。
    /// 错误码与 Android 对齐：PERMISSION_DENIED / INIT_FAILED / BAD_BUFFER
    func start(sampleRate: Int, channels: Int) -> String? {
        if isRunning { return nil }              // 幂等：已在采集直接算成功
        if !Self.micAuthorized() { return "PERMISSION_DENIED" }

        let inputNode = engine.inputNode
        let inFmt = inputNode.outputFormat(forBus: 0)
        // 采样率为 0 = 设备不可用（没权限被拒/被别的 App 独占）→ 初始化失败
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { return "INIT_FAILED" }

        // 目标格式：16bit 小端整数、交错。常见非法组合(如 0 声道)会构造失败
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true) else { return "BAD_BUFFER" }

        targetFormat = outFmt
        inputFormat = inFmt
        // 只有格式不同（采样率或声道数）才建重采样器；相同就直转，省 CPU。
        if inFmt.sampleRate != outFmt.sampleRate
            || inFmt.channelCount != outFmt.channelCount {
            converter = AVAudioConverter(inputFormat: inFmt, outputFormat: outFmt)
            converter?.sampleRateConverterQuality = .medium // 语音场景中等质量足够
        } else {
            converter = nil
        }

        // bufferSize 1024 帧 ≈ 48kHz 下 21ms 一包，和 Android 的 10~20ms 节奏一致
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.handleTap(buf)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return "INIT_FAILED" // 常见原因：麦克风被其他 App 占用
        }
        runLock.lock(); running = true; runLock.unlock()
        return nil
    }

    /// 对应 Android stopMic：关水龙头、停引擎（硬件释放 = 录影绿点熄灭）
    func stop() {
        runLock.lock()
        if !running { runLock.unlock(); return } // 幂等
        running = false
        runLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    // 音频线程回调：把一坨 float32 变成 int16 小端字节，推给 Dart
    private func handleTap(_ inBuf: AVAudioPCMBuffer) {
        runLock.lock()
        let alive = running
        runLock.unlock()
        guard alive, let outFmt = targetFormat else { return }
        guard let onPcm = onPcm else { return } // Dart 还没订阅水管 → 丢帧（同 Android）

        if let conv = converter, let inFmt = inputFormat {
            // ── 需要重采样/声道转换的路径：AVAudioConverter ──
            let ratio = outFmt.sampleRate / max(inFmt.sampleRate, 1.0)
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var fed = false       // 本次输入的 buffer 只许"喂"一次，防止死循环
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, inStatus in
                if fed {
                    inStatus.pointee = .noDataNow // 没更多输入了，结束本次转换
                    return nil
                }
                fed = true
                inStatus.pointee = .haveInput
                return inBuf
            }
            if status == .error { return }        // 单块失败不致命，丢块继续
            emitInt16(out, format: outFmt, sink: onPcm)
        } else {
            // ── 快速路径：采样率/声道完全一致，float32 → int16 逐样本直乘 ──
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt,
                                             frameCapacity: inBuf.frameLength),
                  let src = inBuf.floatChannelData?[0],
                  let dst = out.int16ChannelData?[0] else { return }
            let total = Int(inBuf.frameLength) * Int(outFmt.channelCount)
            for i in 0..<total {
                // [-1,1] 浮点 × 32768 → 夹进 int16 范围（防过载削顶爆音）
                let v = src[i] * 32768.0
                dst[i] = Int16(max(-32768.0, min(32767.0, v.rounded())))
            }
            out.frameLength = inBuf.frameLength
            emitInt16(out, format: outFmt, sink: onPcm)
        }
    }

    // 交错 int16 缓冲 → Data（字节数 = 帧数 × 2字节 × 声道数）→ 回调出去
    private func emitInt16(_ buf: AVAudioPCMBuffer, format: AVAudioFormat,
                           sink: (Data) -> Void) {
        guard buf.frameLength > 0, let p = buf.int16ChannelData?[0] else { return }
        let count = Int(buf.frameLength) * 2 * Int(format.channelCount)
        sink(Data(bytes: p, count: count))
    }

    // ── 麦克风权限（iOS17 前后两套 API，语义一致）─────────────────
    /// 静默查询（checkMicPermission 用）：true=已授权
    static func micAuthorized() -> Bool {
        if #available(iOS 17.0, *) {
            // iOS17：AVAudioApplication 是新的全局音频/权限入口
            return AVAudioApplication.isMicrophoneAuthorized()
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// 弹窗请求（requestMicPermission 用）。completion 保证在主线程回调一次。
    /// 注意：iOS 只在"第一次"询问时弹系统窗；用户以前拒绝过就只能返回 false
    /// （引导用户去 设置-隐私 里手动打开），这点行为与 Android 拒绝后一致。
    static func requestMicPermission(completion: @escaping (Bool) -> Void) {
        if micAuthorized() { completion(true); return }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }
}

// ============================================================================
// 第三部分：上行摄像头（手机镜头 → 电脑虚拟摄像头）
// ----------------------------------------------------------------------------
// 对应 Android 的 CameraEngine.kt（Camera2 + YUV + YuvImage 压 JPEG）。
// iOS 用 AVFoundation 三件套：
//   AVCaptureDevice      一颗镜头（选格式 ≈ Camera2 的 StreamConfigurationMap）
//   AVCaptureSession     采集会话（开/关硬件）
//   AVCaptureVideoDataOutput  逐帧回调（≈ ImageReader）
//
// 帧处理流水（与 Android 逐条对齐）：
//   BGRA 原始帧(横向, 如 1280×720)
//     → 按"传感器安装角 ± 持握角 + 手动偏移"旋转到"正的"画面（顺时针度数）
//     → 前置镜头水平镜像（自拍视角，和 Android mirrorNv21 一致）
//     → 等比缩放居中装进"横向画布" max(w,h)×min(w,h)，四周填黑
//       （目的同 Android：PC 虚拟摄像头分辨率恒定，中途变尺寸会黑屏）
//     → JPEG 压缩质量 0.6（≈ Android quality 60）
//     → EventChannel cam_data 推给 Dart
// 保实时策略（同 Android jpegBusy）：上一帧还在压，这一帧直接丢，绝不排队。
//
// 方向角公式（与 CameraEngine.rotationNeededDegrees 完全同源）：
//   后置：(sensorOrientation - displayRotation + 360) % 360   顺时针
//   前置：(sensorOrientation + displayRotation) % 360         顺时针 + 镜像
//   iOS 拿不到逐机的 SENSOR_ORIENTATION，但内置广角镜头的安装角是硬件标准：
//   后置恒 90°、前置恒 270°（与 Android 主流机型一致），故写死常量并注明。
//   displayRotation(0/90/180/270) 来自 UIDevice.orientation，映射关系：
//     竖屏→0、向左横躺(设备左边朝下)→90、倒竖→180、向右横躺→270。
// ============================================================================
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // ── 当前工作状态（对应 CameraEngine.kt 的 @Volatile 字段）──
    private var running = false
    private var currentFacing = "back"      // "back" / "front"
    private var currentWidth = 640
    private var currentHeight = 480
    private var currentFps = 30
    private var sensorOrientation = 90      // 当前镜头安装角（back=90 / front=270）

    /// 手动旋转偏移（0/90/180/270 顺时针）。
    /// 语义照抄 Android：不随 stop() 清零 —— 用户设定一次，
    /// 断线重连/切镜头都继续生效；相机没开也能改，开相机后自动套用。
    private(set) var manualRotation = 0

    /// 设备持握角（0/90/180/270 顺时针），由 AppDelegate 在主线程
    /// 监听 UIDevice.orientationDidChangeNotification 后写进来。
    /// 压缩线程每帧读一次：Int 读写在本工程场景无撕裂风险，为保简单不加锁。
    var displayRotationDegrees = 0

    /// 每压好一帧 JPEG 回调（≈ Android 的 onFrame）。在压缩线程触发，
    /// 由上层（AppDelegate）负责切回主线程推 EventChannel。
    var onFrame: ((Data) -> Void)?

    // ── AVFoundation 对象（start 创建 / stop 释放）──
    private let sessionQueue = DispatchQueue(label: "pcspeaker.cam.session") // 会话操作队列
    private let compressQueue = DispatchQueue(label: "pcspeaker.cam.jpeg")   // JPEG 压缩线程（≈ compressExecutor）
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let ciContext = CIContext()     // CoreGraphics→JPEG 的渲染上下文（创建很贵，全程复用一个）

    // 上一帧还在压缩 → 新帧直接丢（≈ jpegBusy，保实时）
    private let busyLock = NSLock()
    private var jpegBusy = false

    // MARK: 能力探测（getCameraCaps）
    // 返回结构和 Android getCapabilities 逐字段一致：
    //   [{facing:"back"|"front", sizes:[{width:Int,height:Int,maxFps:Int}]}]
    // 过滤/排序规则也照抄：面积 ≤ 1280×720、按面积从大到小、最多报 8 档。
    // （iOS 无外接 UVC 摄像头支持，所以永远只有 back/front，不会有 external）
    func getCapabilities() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (facingName, position) in [("back", AVCaptureDevice.Position.back),
                                       ("front", AVCaptureDevice.Position.front)] {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], // 广角主摄 = Android 的 YUV 输出档
                mediaType: .video, position: position)
            guard let device = discovery.devices.first else { continue }

            // 同一个尺寸可能被多档帧率范围重复列出 → 去重，帧率取各档最大值
            var bySize: [String: (w: Int, h: Int, fps: Int)] = [:]
            for fmt in device.formats {
                let dims = CMFormatDescriptionGetDimensions(fmt.formatDescription)
                let w = Int(dims.width)
                let h = Int(dims.height)
                if w <= 0 || h <= 0 { continue }
                // 网络传输 720p 封顶（同 Android：更大分辨率带宽/压缩都扛不住）
                if Int64(w) * Int64(h) > 1280 * 720 { continue }
                let maxRangeFps = fmt.videoSupportedFrameRateRanges
                    .map { Int($0.maxFrameRate) }.max() ?? 30
                let maxFps = clampInt(maxRangeFps <= 0 ? 30 : maxRangeFps, 1, 60)
                let key = "\(w)x\(h)"
                if let old = bySize[key] {
                    bySize[key] = (w, h, max(old.fps, maxFps))
                } else {
                    bySize[key] = (w, h, maxFps)
                }
            }
            let sizes = bySize.values
                .sorted { $0.w * $0.h > $1.w * $1.h }   // 面积从大到小
                .prefix(8)                               // 最多 8 档，防 JSON 过大
                .map { ["width": $0.w, "height": $0.h, "maxFps": $0.fps] as [String: Any] }
            if !sizes.isEmpty {
                result.append(["facing": facingName, "sizes": sizes])
            }
        }
        return result
    }

    // MARK: 开始采集（startCamera）
    // 约定同 Android：成功回调 nil，失败回调错误码字符串。
    // ⚠️ 全程在 sessionQueue 异步执行，绝不卡主线程（Android 端用 3 秒门闩
    // 阻塞的是它自己的调用线程，这里我们做得更好：纯异步 + completion）。
    func start(facing: String, width: Int, height: Int, fps: Int,
               completion: @escaping (String?) -> Void) {
        sessionQueue.async {
            if self.running { completion(nil); return } // 幂等：已在采集算成功

            // 先把"当前状态"记下来 —— 照抄 Android：currentFacing 在尝试打开
            // 之前就赋值，switchLens 失败时也返回目标朝向（保持两端行为一致）
            self.currentFacing = facing
            self.currentWidth = width
            self.currentHeight = height
            self.currentFps = clampInt(fps, 1, 30)      // 网络场景 30fps 封顶（同 Android）

            // 权限兜底（正常流程 Dart 已 ensurePermission）
            if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                completion("PERMISSION_DENIED"); return
            }

            // 第一步：按朝向找镜头（≈ findCameraId）
            let position: AVCaptureDevice.Position = (facing == "front") ? .front : .back
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
            guard let device = discovery.devices.first else {
                completion("NO_CAMERA"); return
            }
            self.sensorOrientation = (position == .front) ? 270 : 90 // 安装角常量（见文件头说明）

            // 第二步：选"最接近请求分辨率"的输出格式（≈ StreamConfigurationMap）
            // 优先精确匹配 width×height；没有就取面积最接近的一档。
            let wantedArea = width * height
            var chosen: AVCaptureDevice.Format?
            var chosenRange: AVFrameRateRange?
            for fmt in device.formats {
                let dims = CMFormatDescriptionGetDimensions(fmt.formatDescription)
                let area = Int(dims.width) * Int(dims.height)
                if area <= 0 { continue }
                let ranges = fmt.videoSupportedFrameRateRanges
                let bestRange = ranges.first { $0.maxFrameRate >= Double(self.currentFps) }
                    ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
                let score: Int
                if Int(dims.width) == width && Int(dims.height) == height {
                    score = 0                            // 精确命中，最优
                } else {
                    score = abs(area - wantedArea) + 1   // 差越大越靠后
                }
                if let cur = chosen {
                    let curDims = CMFormatDescriptionGetDimensions(cur.formatDescription)
                    let curArea = Int(curDims.width) * Int(curDims.height)
                    let curScore = (curArea == wantedArea) ? 0 : abs(curArea - wantedArea) + 1
                    if score < curScore { chosen = fmt; chosenRange = bestRange }
                } else {
                    chosen = fmt; chosenRange = bestRange
                }
            }
            guard let pickFormat = chosen else { completion("SESSION_FAILED"); return }

            do {
                let newSession = AVCaptureSession()
                // 关键：不让相机自动改写我们的音频会话！
                // AVCaptureSession 默认会自动把 AVAudioSession 切成录音模式，
                // 会打断"下行播放 + 语音回声消除"的音频配置 → 必须关掉自管。
                newSession.automaticallyConfiguresApplicationAudioSession = false

                // 配置格式 + 锁帧率（≈ TEMPLATE_PREVIEW + AE_TARGET_FPS_RANGE）
                // 锁帧率的意义：让相机严格按目标 fps 出帧，不随环境亮度自动降帧。
                // 版本说明：iOS 17 起 activeVideoMin/MaxFrameDuration 被
                // activeFrameRateRange 取代，但"废弃标记"≠"删除"——旧属性在
                // iOS 17/18 上照样编译（仅警告）、照样生效，且一套写法覆盖
                // iOS15~18 全部版本，故有意只用旧 API，避免新老分叉。
                _ = try? device.lockForConfiguration()
                device.activeFormat = pickFormat
                let wantFps = Float64(self.currentFps)
                let actualMax = chosenRange?.maxFrameRate ?? 30
                let targetFps = max(1.0, min(wantFps, actualMax))
                let t = CMTime(value: 1, timescale: CMTimeScale(targetFps.rounded()))
                device.activeVideoMinFrameDuration = t
                device.activeVideoMaxFrameDuration = t
                device.unlockFromConfiguration()

                // 输入：这台镜头
                let input = try AVCaptureDeviceInput(device: device)
                guard newSession.canAddInput(input) else {
                    completion("SESSION_FAILED"); return
                }
                newSession.addInput(input)

                // 输出：逐帧 BGRA（≈ ImageReader，但 iOS 直接给 RGB 域，
                // 省掉 Android 的 YUV→NV21 转换；JPEG 编码交给 ImageIO）
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        NSNumber(value: kCVPixelFormatType_32BGRA)
                ]
                // 只保最新帧：上一帧还在压就丢新帧（≈ acquireLatestImage + jpegBusy）
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.sessionQueue)
                guard newSession.canAddOutput(output) else {
                    completion("SESSION_FAILED"); return
                }
                newSession.addOutput(output)

                // 启动会话，等"真的跑起来"通知（3 秒超时 ≈ OPEN_TIMEOUT）
                newSession.startRunning()
                let sem = DispatchSemaphore(value: 0)
                let token = NotificationCenter.default.addObserver(
                    forName: .AVCaptureSessionDidStartRunning,
                    object: newSession, queue: nil) { _ in sem.signal() }
                let ok = sem.wait(timeout: .now() + 3.0) == .success
                NotificationCenter.default.removeObserver(token)
                if !ok {
                    newSession.stopRunning()
                    completion("OPEN_TIMEOUT"); return
                }

                self.session = newSession
                self.videoOutput = output
                self.running = true
                completion(nil)
            } catch {
                completion("SESSION_FAILED") // ≈ Android 的 OPEN_ERROR/SESSION_FAILED
            }
        }
    }

    // MARK: 停止采集（stopCamera / stopCamStandby 内部也用）
    // 幂等：没开就直接返回。注意：不清零 manualRotation（同 Android）。
    func stop() {
        sessionQueue.async {
            if !self.running && self.session == nil { return }
            self.running = false
            self.session?.stopRunning()
            if let out = self.videoOutput {
                self.session?.removeOutput(out)
            }
            if let s = self.session {
                for i in s.inputs { s.removeInput(i) }
                for o in s.outputs { s.removeOutput(o) }
            }
            self.session = nil
            self.videoOutput = nil
        }
    }

    // MARK: 前后置切换（switchCamera）—— 逻辑照抄 CameraEngine.switchLens
    /// 返回切换后的 facing；没有另一个镜头/没在跑 → 返回当前 facing（不改状态）。
    func switchLens() -> String {
        // 判断"有没有另一个镜头"不需要开硬件，可以同步查
        if !running { return currentFacing }
        let target = (currentFacing == "back") ? "front" : "back"
        let pos: AVCaptureDevice.Position = (target == "front") ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: pos)
        if discovery.devices.isEmpty { return currentFacing }
        // 异步 stop→start（沿用当前分辨率/帧率/onFrame），返回值按 Android 语义
        // 直接给目标朝向（start 会先把 currentFacing 置为 target）
        let w = currentWidth, h = currentHeight, f = currentFps
        stop()
        start(facing: target, width: w, height: h, fps: f) { _ in }
        return target
    }

    // MARK: 手动旋转（rotateCamera）—— 照抄 CameraEngine.rotateManual
    /// 点一次 +90°（0→90→180→270→0 循环），下一帧立即生效、不重启相机；
    /// 返回新角度（Dart invokeMethod<int> 期望 Int）。
    func rotateManual() -> Int {
        manualRotation = (manualRotation + 90) % 360
        return manualRotation
    }

    // ── 帧方向计算（≈ CameraEngine.rotationNeededDegrees）──
    private func rotationNeededDegrees() -> Int {
        let dev = ((displayRotationDegrees % 360) + 360) % 360
        let auto: Int
        if currentFacing == "front" {
            auto = (sensorOrientation + dev) % 360          // 前置公式
        } else {
            auto = (sensorOrientation - dev + 360) % 360    // 后置公式
        }
        return (auto + manualRotation) % 360                // 再叠加手动偏移
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate —— 每帧到达
    // 运行在 sessionQueue。这里只做"占坑 + 搬像素缓冲"，重活扔给 compressQueue，
    // 保证采集线程永不阻塞（同 Android：ImageReader 线程只做 yuvToNv21）。
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let onFrame = onFrame else { return }

        busyLock.lock()
        if jpegBusy { busyLock.unlock(); return } // 上一帧还在压 → 丢掉这帧（保实时）
        jpegBusy = true
        busyLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            busyLock.lock(); jpegBusy = false; busyLock.unlock()
            return
        }
        // CVPixelBuffer 只在本回调内有效 → 想带出去必须 retain/release（手动计数）
        CVPixelBufferRetain(pixelBuffer)
        let w = currentWidth, h = currentHeight
        let mirror = (currentFacing == "front")
        let deg = rotationNeededDegrees()

        compressQueue.async { [weak self] in
            guard let self = self else {
                CVPixelBufferRelease(pixelBuffer); return
            }
            defer {
                CVPixelBufferRelease(pixelBuffer)
                self.busyLock.lock(); self.jpegBusy = false; self.busyLock.unlock()
            }
            if let jpeg = self.makeJpeg(pixelBuffer, mirror: mirror, cw: w, ch: h, deg: deg) {
                if self.running { onFrame(jpeg) }
            }
        }
    }

    // MARK: 单帧加工：旋转 → 镜像 → 装裱 → JPEG（≈ rotateNv21+mirrorNv21+fitNv21Into+nv21ToJpeg）
    // 全部用 CIImage 仿射变换完成：
    //   * CIImage 坐标系是"左下原点、y 向上"；CGAffineTransform 正角 = 逆时针。
    //     所以要"顺时针转 deg"就用 rotationAngle = -deg（这是最容易搞反的一步）。
    //   * 围绕画面中心变换：先平移中心到原点 → 做变换 → 平移回去。
    private func makeJpeg(_ pb: CVPixelBuffer, mirror: Bool,
                          cw: Int, ch: Int, deg: Int) -> Data? {
        var img = CIImage(cvPixelBuffer: pb) // 原始横向帧，如 1280×720

        // ① 顺时针旋转 deg 度（90/270 时宽高自动互换 → 竖屏正像）
        if deg != 0 {
            let c = CGPoint(x: img.extent.midX, y: img.extent.midY)
            img = img
                .transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y))
                .transformed(by: CGAffineTransform(rotationAngle: -CGFloat(deg) * .pi / 180.0))
                .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
        }

        // ② 前置镜头水平镜像（自拍 = 镜子里的自己，同 Android）
        if mirror {
            let mx = img.extent.midX
            img = img
                .transformed(by: CGAffineTransform(translationX: -mx, y: 0))
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: mx, y: 0))
        }

        // ③ 等比缩放 + 居中"装裱"进横向画布 cw×ch（四周填黑，分辨率恒定）
        let fw = img.extent.width, fh = img.extent.height
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(cw), height: CGFloat(ch))
        guard fw > 0, fh > 0 else { return nil }
        let scale = min(canvas.width / fw, canvas.height / fh)
        if scale != 0 {
            let cx = img.extent.midX, cy = img.extent.midY
            img = img
                .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                // 缩放后平移到画布正中央
                .transformed(by: CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
        }

        // 纯黑底 + 画面叠加（Android 用 YUV 黑 Y=16，这里 RGB 全黑，观感一致）
        let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .clampedToExtent()
            .cropped(to: canvas)
        let composed = img.composited(over: bg)

        guard let cg = ciContext.createCGImage(composed, from: canvas) else { return nil }

        // ④ JPEG 编码，质量 0.6 ≈ Android compressToJpeg(quality:60)
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.6]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }
}

// ============================================================================
// EventChannel 的"水龙头开关"：Dart 订阅/取消订阅时收/放 sink。
// （结构照抄 MainActivity.kt 里的匿名 StreamHandler：onListen 存、onCancel 清空）
// ============================================================================
final class DataStreamHandler: NSObject, FlutterStreamHandler {
    var sink: FlutterEventSink? // 原生 → Dart 的出水口（nil = Dart 没在听）
    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

// ============================================================================
// AppDelegate：通道的"总机"。所有 MethodChannel 分支与 Android 一一对应。
// ============================================================================
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    // ── 三条水管 + 三个原生引擎（与 Android MainActivity 的字段一一对照）──
    private var methodChannel: FlutterMethodChannel?
    private var micEventChannel: FlutterEventChannel?  // ⚠️ 通道对象必须被持有，
    private var camEventChannel: FlutterEventChannel?  //   否则会被 ARC 回收、水管断流
    private let micStream = DataStreamHandler()   // ≈ micEventSink
    private let camStream = DataStreamHandler()   // ≈ camEventSink
    private let player = DownlinkPlayer()         // ≈ audioTrack (AudioTrack)
    private let mic = MicUplink()                 // ≈ audioRecord (AudioRecord)
    private let camEngine = CameraEngine()        // ≈ camEngine (CameraEngine.kt)
    // 注意：camEngine 只创建一次、全程复用 —— manualRotation 因此跨
    // stop/start/切镜头/断线重连都不会丢（同 Android camEngine 懒加载单例）。

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 打开"设备方向"事件源：不 beginGenerating 就收不到方向变化通知。
        // （对应 Android 里 CameraEngine 每帧现查 WindowManager.defaultDisplay.rotation）
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onOrientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        onOrientationChanged() // 启动时先采一次当前方向

        // 相机被系统抢占/恢复（电话进来、切后台再切回来）的看护：
        // iOS 不允许后台采集相机（系统硬限制）—— 回前台时若 PC 还在看
        // （Dart 状态仍是 live、会再收帧）但会话已被停掉，这里自动重启补救，
        // 让画面在用户回到前台的下一秒恢复。
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAppActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        // 插件注册不放这里：本工程用"隐式引擎"模板，统一在下面的
        // didInitializeImplicitFlutterEngine 里完成（见该方法注释）。
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── 新版 Flutter 模板（隐式引擎）：通道注册的唯一正确时机 ──
    // 老项目里这段写在 configureFlutterEngine；本工程用 FlutterImplicitEngineDelegate，
    // 从 engineBridge 拿 pluginRegistry 注册插件、拿 applicationRegistrar.messenger()
    // 建我们自己的三条通道（这是当前模板官方给出的取 messenger 方式）。
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let messenger = engineBridge.applicationRegistrar.messenger()

        // ── 方法通道：逐方法镜像 Android MainActivity 的 when(call.method) ──
        methodChannel = FlutterMethodChannel(name: kAudioChannel, binaryMessenger: messenger)
        methodChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result)
        }

        // ── EventChannel：mic_data / cam_data（与 Android 完全同构）──
        // 注意把通道对象存进属性：通道对象若被 ARC 释放，Dart 那边水管就断了。
        micEventChannel = FlutterEventChannel(name: kMicDataChannel, binaryMessenger: messenger)
        micEventChannel?.setStreamHandler(micStream)
        camEventChannel = FlutterEventChannel(name: kCamDataChannel, binaryMessenger: messenger)
        camEventChannel?.setStreamHandler(camStream)

        // 原生采到的数据 → 主线程 → EventChannel 推给 Dart。
        // （Android: runOnUiThread { micEventSink?.success(...) } —— 同一规则：
        //   FlutterEventSink 必须在平台线程调用，音频/压缩线程都不能直接推。）
        mic.onPcm = { [weak self] data in
            DispatchQueue.main.async { self?.micStream.sink?(FlutterStandardTypedData(bytes: data)) }
        }
        camEngine.onFrame = { [weak self] data in
            DispatchQueue.main.async { self?.camStream.sink?(FlutterStandardTypedData(bytes: data)) }
        }
    }

    // MARK: 方向通知 → 换算成"设备持握角"（0/90/180/270 顺时针）
    @objc private func onOrientationChanged() {
        // UIDevice 与 Android Surface.rotation 的对应：
        //   向左横躺(设备左边朝下)= ROTATION_90 → 90
        //   向右横躺(设备右边朝下)= ROTATION_270 → 270
        // 注意命名陷阱：UIDevice 的 Left/Right 是"哪条边朝下"，
        // 而 Android 的是"显示内容相对自然方向转了多少"。两者取反着来，
        // 下表已与后置镜头"横屏不额外旋转(0°)"的实测惯例对齐；
        // 若真机横屏方向差 180°，用户点一下旋转按钮即可验证并反馈。
        var deg = 0
        switch UIDevice.current.orientation {
        case .portrait:            deg = 0     // 竖屏
        case .portraitUpsideDown:  deg = 180   // 倒竖
        case .landscapeLeft:       deg = 90    // 设备向左横躺
        case .landscapeRight:      deg = 270   // 设备向右横躺
        default: return            // faceUp/faceDown/unknown：保持上一次的值
        }
        camEngine.displayRotationDegrees = deg
    }

    // MARK: 回到前台 → 相机采集会话若已被系统停掉则自动重启（见上注释）
    @objc private func onAppActive() {
        // 走公开方法重启当前配置（幂等；失败就等 PC 下一次 cam_state 唤醒）
        camEngine.resumeIfNeeded()
    }

    // MARK: 音频会话策略（全 App 共用一条 AVAudioSession）
    // * 类别 .playAndRecord：同时开扬声器放音 + 麦克风采音的前提（全双工地基）。
    // * .defaultToSpeaker：不加的话 playAndRecord 默认把下行声音路由到"听筒"
    //   （贴耳朵那种小声音），我们要的是外放（≈ Android STREAM_MUSIC）。
    // * mode：麦克风采集中 = .voiceChat（系统回声消除+降噪链路，
    //   ≈ Android VOICE_COMMUNICATION + AEC/NS 效果器）；纯播放 = .default
    //   （音乐模式，不走语音处理链，音质更好）。
    // * iOS17 的 AVAudioApplication 没有"直接开 AEC"的开关，voiceProcessing
    //   属于 AVAudioEngine 层 API（setVoiceProcessingEnabled），与 .voiceChat
    //   功能重叠且兼容性差 → 有意不调用，注释说明选型（任务要求记录决策）。
    private func configureAudioSession(micActive: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord,
                              mode: micActive ? .voiceChat : .default,
                              options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch {
            // 会话设置失败不致命：沿用现状继续
        }
    }

    // MARK: MethodChannel 总调度 —— 逐分支对照 MainActivity.configureFlutterEngine
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        // Dart 传参是个 Map；统一取出（invokeMethod 不传参时 arguments 为 nil）
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        // ── 播放（PC → 手机扬声器）──────────────────────────────
        case "setup":
            // 参数：sampleRate(默认48000)、channels(默认2) —— 与 Android ?: 默认值一致
            let sr = (args["sampleRate"] as? NSNumber)?.intValue ?? 48000
            let ch = (args["channels"] as? NSNumber)?.intValue ?? 2
            configureAudioSession(micActive: mic.isRunning)
            player.setup(sampleRate: sr, channels: ch)
            result(true)

        case "write":
            // data：PCM s16le 字节块。Dart 的 Uint8List 到 iOS 是
            // FlutterStandardTypedData（.data 属性即字节）；也兼容直接给 Data。
            var data: Data?
            if let typed = args["data"] as? FlutterStandardTypedData {
                data = typed.data
            } else if let d = args["data"] as? Data {
                data = d
            }
            if let data = data {
                player.write(data)
                result(true)
            } else {
                // 错误码/文案照抄 Android：INVALID_DATA
                result(FlutterError(code: "INVALID_DATA",
                                    message: "No data provided", details: nil))
            }

        case "start":
            player.start()
            result(true)

        case "pause":
            player.pause()
            result(true)

        case "stop":
            player.stop()
            result(true)

        case "release":
            player.release()
            // 麦克风也关了 → 音频会话切回普通播放模式（不 deactivate，
            // 保持会话活着以免打断后台 WebSocket 音频保活）
            configureAudioSession(micActive: false)
            result(true)

        // ── 麦克风（手机话筒 → PC 虚拟麦克风）────────────────────
        case "checkMicPermission":
            // 静默查询，不弹窗（语义/返回值类型同 Android：Bool）
            result(MicUplink.micAuthorized())

        case "requestMicPermission":
            // 已授权直接 true；否则弹系统窗，用户答复后异步 result（同 Android）
            MicUplink.requestMicPermission { granted in
                result(granted) // requestRecordPermission 已保证主线程回调
            }

        case "startMic":
            let sr = (args["sampleRate"] as? NSNumber)?.intValue ?? 48000
            let ch = (args["channels"] as? NSNumber)?.intValue ?? 1
            // 先配好音频会话（开麦 = 进入 voiceChat 回声消除链路）
            configureAudioSession(micActive: true)
            let err = mic.start(sampleRate: sr, channels: ch)
            result(err) // 约定：nil=成功；字符串=错误码（PERMISSION_DENIED/INIT_FAILED/BAD_BUFFER）

        case "stopMic":
            mic.stop()
            configureAudioSession(micActive: false) // 回到普通播放模式
            result(true)

        case "startMicStandby":
            // Android：挂"前台守护通知"保活进程。iOS 无前台服务概念 →
            // 空操作返回成功；后台保活由 Info.plist 的 UIBackgroundModes=audio
            // + 激活中的 playAndRecord 会话承担（Dart 侧本就 try/catch 容错）。
            result(true)

        case "stopMicStandby":
            result(true) // 同上：iOS 侧本来没有服务可停，空操作

        // ── 摄像头（手机镜头 → PC 虚拟摄像头）────────────────────
        case "checkCamPermission":
            result(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)

        case "requestCamPermission":
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                result(true)
            } else {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    // 系统回调线程不定 → 切回主线程再回 Flutter
                    DispatchQueue.main.async { result(granted) }
                }
            }

        case "getCameraCaps":
            // 返回 [[facing:String, sizes:[{width,height,maxFps}]]]，
            // 结构与过滤/排序规则逐条复刻 Android（见 CameraEngine.getCapabilities）
            result(camEngine.getCapabilities())

        case "startCamera":
            let facing = (args["facing"] as? String) ?? "back"
            let w = (args["width"] as? NSNumber)?.intValue ?? 640
            let h = (args["height"] as? NSNumber)?.intValue ?? 480
            let fps = (args["fps"] as? NSNumber)?.intValue ?? 30
            // 异步打开（不卡主线程），完成回主线程 result
            camEngine.start(facing: facing, width: w, height: h, fps: fps) { err in
                DispatchQueue.main.async { result(err) } // nil=成功；字符串=错误码
            }

        case "stopCamera":
            camEngine.stop()
            result(true)

        case "switchCamera":
            result(camEngine.switchLens()) // 返回切换后的 facing："back"/"front"

        case "rotateCamera":
            // 手动 +90° 循环；返回新角度 Int（Dart invokeMethod<int> 已核对）
            result(camEngine.rotateManual())

        case "startCamStandby":
            // Android：挂相机守护通知。iOS 空操作（理由同 startMicStandby）
            result(true)

        case "stopCamStandby":
            // 照抄 Android：这个分支除了撤服务，还真的会 engine().stop()
            // —— 注销相机守护时必须关硬件（隐私承诺的支点），保留该语义。
            camEngine.stop()
            result(true)

        case "goHome":
            // Android 专属能力（发 Home Intent 回桌面）。iOS 沙箱没有等价 API，
            // 且 Dart 的 AudioService.goHome() 用 try/catch 静默兜底（已核对源码）
            // → 返回 notImplemented 让 Dart 走静默失败分支即可。
            result(FlutterMethodNotImplemented)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// ── CameraEngine 的小扩展：回前台自动续拍（职责归位，代码放一起好读）──
extension CameraEngine {
    /// 场景：PC 正在看（running=true）、但相机被系统"打断"过
    /// （切后台、被电话/其他 App 抢占相机等）。AVFoundation 的打断结束
    /// 通知（AVCaptureSessionWasInterrupted / InterruptionEnded）系统
    /// 通常会自行恢复会话，但"App 退后台"这种不算打断 —— 会话直接停摆，
    /// 且 iOS 明确禁止后台采集相机。所以这里做最保守的补救：
    /// 回前台时若发现"我们以为在跑、但会话实际已停" → 重新 startRunning。
    /// ⚠️ 已知限制（用户实测重点）：手机在后台期间画面传输一定是中断的，
    ///    这是 iOS 平台硬限制，无法绕过（Android 靠前台服务能做到息屏推流）。
    func resumeIfNeeded() {
        sessionQueue.async {
            // 只有"逻辑在跑 + 有会话 + 物理会话已停"三者同时成立才补救
            guard self.running, let s = self.session, !s.isRunning else { return }
            s.startRunning()
        }
    }
}
