// ============================================================================
// mic_service.dart —— 麦克风采集服务层（v3 新增）
// ----------------------------------------------------------------------------
// 职责：调用 Android 原生 AudioRecord 采集手机话筒声音，
//       把 PCM 字节块"原样"转发出去（通过 onData 回调），
//       同时算出每块的响度（通过 onLevel 回调）给界面画电平条。
//
//   手机话筒 --原生AudioRecord--> EventChannel(字节流) --> MicService
//                                                        ├─ onData  → 上行发送
//                                                        └─ onLevel → 界面电平
//
// 与 AudioService（播放）的分工：
//   AudioService 管"耳朵听"（PC → 手机扬声器），
//   MicService    管"嘴巴说"（手机话筒 → PC 虚拟麦克风），
//   两者互不干扰，所以可以全双工同时进行。
//
// 平台通道复习（新手关键）：
//   MethodChannel —— "打电话问一句答一句"：startMic / stopMic / 权限请求
//   EventChannel  —— "装一根水管持续放水"：麦克风 PCM 帧从水管里不断流出
//
// ── 补充说明书（给初学者；以下全是注释，不含代码改动）─────────────────────
//
// 【谁调用我】只有一个：lib/providers/mic_provider.dart
//   · 构造函数里给我挂两个回调：onData（把 PCM 塞进 WebSocket）、
//     onLevel（把响度喂给电平条）—— 见该文件"接线 1/2"。
//   · ensurePermission()/hasPermission() 用于静默检查与弹窗申请。
//   · start(sampleRate:…, channels:1) / stop() 由它的 _openMic/_closeMic 调用，
//     触发时机是服务器推来的 mic_state{active:true/false}（"电脑真在用才开硬件"）。
//   · startStandbyService()/stopStandbyService() 由 enterStandby()/stop() 调用。
//   · 界面（lib/screens/mic_screen.dart）不直接碰我，只读 MicProvider 的状态。
//
// 【我调用谁】Android 原生层 MainActivity.kt：
//   通道名 "com.pcspeaker/audio"（同文件 146 行的 CHANNEL）负责方法调用，
//   "startMic/stopMic/checkMicPermission/requestMicPermission/startMicStandby/
//    stopMicStandby" 这些字符串必须和原生 when(call.method) 的分支一字不差；
//   水管 "com.pcspeaker/mic_data"（同文件 152 行 MIC_DATA_CHANNEL）负责原生→Dart 推数据。
//
// 【数据流方向】上行：手机话筒 → 原生 AudioRecord → EventChannel → 我 →
//   MicProvider → NetworkService.send() → WebSocket → PC 的虚拟麦克风(CABLE Input)。
//   下行播放是另一条独立通路（lib/services/audio_service.dart），两边互不干扰。
//
// 【一秒钟多少字节】同样是 采样率 × 声道数 × 每样本字节数（16bit=2 字节）：
//   48000 × 1 × 2 = 96000 字节/秒（单声道上行）
//   若改 44100：44100 × 1 × 2 = 88200 字节/秒（MicProvider 的采样率档位之一，
//   服务器会重采样回 48k，参见 lib/providers/mic_provider.dart 的 sampleRateChoices）。
//   原生每包的大小 = AudioRecord.getMinBufferSize(...) × 2，在 48k 单声道下
//   约 10~20ms 音频，也就是每秒约 50~100 包、每包约 1~2KB。
//   想换算某一块的时长：秒 = data.length ÷ (采样率 × 声道 × 2)。
//
// 【为什么上行不压缩】PCM 直通延迟最低（几十毫秒级），压缩成 Opus 要额外 CPU
//   和编解码延迟；代价是带宽（96kbps 级别）。麦克风是"对讲"性质，优先保延迟。
//
// 【上行帧的完整布局】麦克风 PCM 块【没有任何包头】，一个 WebSocket 二进制
//   消息就是一块原始 PCM —— 分帧靠 WebSocket 协议自己的消息边界（帧头里有
//   长度字段与 FIN 标志，接收库保证"一次回调 = 一条完整消息"），
//   所以两端都不需要自己数长度、拼半包。
//   服务器怎么区分这是麦克风还是摄像头？靠摄像头帧额外加的 4 字节魔术头
//   [0x03,'C','A','M']，见 lib/providers/camera_provider.dart 的 _frameMagic
//   （注意：那个常量在 provider 里，不在本文件也不在 network_service.dart）。
//   原始 PCM 恰好以这四个字节开头的概率约 2^-32，可以忽略。
//
// 【控制消息（JSON 文本帧）在谁手里发】不在本文件 —— 是 MicProvider 用
//   NetworkService.send(jsonEncode({'type':'mic_start' ... })) 发的，
//   回执 mic_ack / 指令 mic_state 由 network_service.dart 解析后走流出来。
//   本层只管硬件采集，完全不知道网络的存在，这是分层的核心。
//
// 【新手建议阅读顺序】start() → 那个 listen 回调 → _rms() → stop()。
//   权限那两个方法可以最后看。概念生词表：Future/async/await、
//   MethodChannel、invokeMethod 的泛型与 ?? 兜底、EventChannel、
//   Stream/StreamSubscription、Uint8List/ByteData/Endian —— 都在下面逐条注了。
// ============================================================================

// dart:async：StreamSubscription 等流类型（EventChannel 的订阅句柄就是它）。
//   不 import 这一行，下面 `StreamSubscription? _dataSub;` 就找不到类型。
import 'dart:async';
import 'dart:math' as math; // 只用它的 sqrt 开平方算 RMS
// as math：给库起别名，之后写 math.sqrt(...)，避免把 sqrt 这种
// 常见名字直接倒进本文件命名空间（也叫"命名空间污染"）。
// Uint8List：原始字节数组（一块 PCM 数据就是一个 Uint8List）。
import 'dart:typed_data';

// package:flutter/services.dart：MethodChannel + EventChannel + ByteData/Endian。
// 备注（不改代码）：flutter_lints 的 unnecessary_import 规则若在这里报
//   dart:typed_data 多余（因为部分类型由 flutter 的库转导出），删掉那行即可，
//   本任务只加注释、不动任何 import。
import 'package:flutter/services.dart';

/// 麦克风采集服务
class MicService {
  /// 方法通道：复用播放那一条（原生 MainActivity 里同一个 CHANNEL）
  // 名字必须与原生侧完全一致（MainActivity.kt:146 的 CHANNEL 常量）。
  // 一条通道可以承载任意多个方法名，麦克风、播放、摄像头、goHome 全挤在
  // "com.pcspeaker/audio" 上，原生用 when(call.method) 分流；
  // 好处是两端只对齐一个字符串，坏处是所有方法共用一个 handler（读代码时
  // 别被绕晕：本文件的 startMic 和 audio_service 的 setup 是同一条通道的不同分支）。
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  /// 事件通道：原生采集线程持续推来的 PCM 字节块
  // EventChannel 与 MethodChannel 的区别（新手必分清）：
  //   MethodChannel：一问一答，Dart 主动、原生回一个值，适合"命令/查询"。
  //   EventChannel ：单向数据流，方向只能是【原生 → Dart】，持续不断，
  //                   适合"传感器、音频帧"这类推流；反方向发东西仍得用 MethodChannel。
  // 原生侧在 MainActivity.kt:409 用 EventChannel(MIC_DATA_CHANNEL).setStreamHandler
  //   装好水管，采集线程里 micEventSink?.success(字节) 就是"放一滴水"；
  //   Dart 这边 receiveBroadcastStream().listen(...) 就是接水。
  // 名字 'com.pcspeaker/mic_data' 同样要和原生 152 行的常量一字不差。
  static const EventChannel _dataChannel = EventChannel('com.pcspeaker/mic_data');

  // StreamSubscription = "订阅凭证"。listen() 会返回它，
  // 只有留着凭证才能在不用时 cancel()；不留 = 回调永远挂着 = 内存泄漏，
  // 严重时对象销毁后回调还在跑而崩溃（这是 Flutter 新手第二大坑，第一大是忘判空）。
  // 类型写成 StreamSubscription 而不是 StreamSubscription<Uint8List>：
  // 因为 receiveBroadcastStream() 给的是 Stream<dynamic>（dynamic = 编译期不校验类型）。
  StreamSubscription? _dataSub; // 水管订阅句柄（不取消会泄漏）

  /// 是否正在采集
  // isRunning 没加下划线 = 公开字段，别的类也能读（start() 内部用它做幂等判断）。
  bool isRunning = false;

  /// 每来一块 PCM 字节就回调一次 —— MicProvider 在这里把数据发往 PC
  // 类型是"函数类型"：void Function(Uint8List bytes)?
  //   读法：一个【可选的】(结尾有 ?) 函数，参数是 Uint8List，返回 void。
  // 为什么用回调而不是让服务自己 import NetworkService：
  //   谁消费数据不由采集层决定（关注点分离），MicProvider 想发网络、想统计、
  //   想丢弃都在它自己那边做；本层因此可以完全不知道网络的存在，也便于单测。
  void Function(Uint8List bytes)? onData;

  /// 每块数据算好的响度（0.0 ~ 1.0）—— MicProvider 在这里刷电平条
  void Function(double level)? onLevel;

  /// 静默查询录音权限（不弹系统窗）。自动待命流程用：
  /// 没权限就跳过登记，避免连接瞬间弹窗打扰。
  // Android 6 起，RECORD_AUDIO / CAMERA 这类"危险权限"必须运行时申请，
  // 只在 AndroidManifest.xml 里声明是不够的（那是"我有资格申请"的声明）。
  // 原生分支：checkMicPermission → result.success(hasMicPermission())。
  Future<bool> hasPermission() async {
    // invokeMethod<bool>：尖括号里的泛型参数是"我预期原生回的是 bool"，
    //   Dart 据此把返回值当 bool 给你用（实际转换失败会在 await 时抛异常）。
    // 返回类型是可空 bool（bool?），因为原生完全可以回一个 null，
    //   所以必须用 ?? 兜底：?? 左边是 null 时取右边的值（这里当"没权限"处理）。
    //   这套 ?/??/! 的判断就是 Dart 空安全的核心：编译器逼你先把 null 处理干净。
    final granted =
        await _channel.invokeMethod<bool>('checkMicPermission') ?? false;
    return granted;
  }

  /// 确保拿到录音权限。
  /// 返回 true = 已授权；false = 用户拒绝（或系统弹窗点了"不允许"）。
  Future<bool> ensurePermission() async {
    // invokeMethod<bool> 的泛型参数：告诉 Dart "原生会回一个 bool"，
    // 返回值是可空 bool（?），用 ?? false 兜底（万一原生返回 null）
    final granted =
        await _channel.invokeMethod<bool>('checkMicPermission') ?? false;
    if (granted) return true; // 已有权限，直接过，不打扰用户

    // 没有权限 → 请求原生弹系统授权窗（用户看到"允许录音吗？"）
    // 这里有个异步往返的特殊点：原生那边不是当场就有答案，它要等用户点、
    // 答案在 onRequestPermissionsResult 里才回来（原生先把 result 存进
    // pendingPermResult，见 MainActivity.kt 的 requestMicPermission 分支）。
    // 因为这段往返耗时不确定，Dart 侧的 await 会一直挂着 —— 这正是
    // "调用原生必须 await"的典型例子：不 await 就只能拿到没兑现的 Future。
    final result =
        await _channel.invokeMethod<bool>('requestMicPermission') ?? false;
    return result;
  }

  /// 开始采集。
  /// 返回 null = 成功；返回错误码字符串 = 失败（调用方翻译成中文提示）。
  // 新手注意这个"反直觉"的约定：String? 的 null 在这里代表【好消息】（没错误），
  // 非空才是错误码。上层 MicProvider 拿到错误码后走 _reportNativeError()
  // 换成文案键，最终由界面翻译（见 lib/providers/mic_provider.dart）。
  // 另一种常见写法是抛异常或用 Result 类型；本项目选择"返回错误码"，
  // 因为原生侧 startMic 本来就是 Kotlin 返回 String?，一条通道对齐到底。
  Future<String?> start({int sampleRate = 48000, int channels = 1}) async {
    // 有默认值的命名参数：调用方可以 start() 全默认，也可以
    // start(sampleRate: 44100)；MicProvider 实际传的是 sampleRate: 用户所选, channels: 1。
    // 48000 = 与 PC 声卡混音率一致（服务器零重采样直通）；
    // channels = 1（单声道）：对讲/会议场景够用，还能把上行字节数砍一半
    //（96000 而不是 192000 字节/秒）。
    if (isRunning) return null; // 幂等：已在跑就不重复启动

    // 第一步：权限（Android 6.0+ 必须运行时申请，写死在 Manifest 不够）
    if (!await ensurePermission()) return 'PERMISSION_DENIED';

    // 第二步：让原生打开 AudioRecord 并开始采集线程
    // 原生 startMic 约定：成功 success(null)，失败 success("错误码")
    // 原生会返回这几个错误码（MainActivity.kt:516 起的 startMic）：
    //   PERMISSION_DENIED = 权限没拿到
    //   BAD_BUFFER        = getMinBufferSize 返回 ≤0，说明这套采样率/声道组合
    //                       设备不支持（这就是为什么 44100/48000 单声道最保险）
    //   INIT_FAILED       = AudioRecord 建起来了但 state 不是 INITIALIZED，
    //                       多数是话筒被别的 App 独占
    // 参数 Map 的 key 也要和原生 call.argument<Int>("sampleRate") 对齐。
    final error = await _channel.invokeMethod<String>('startMic', {
      'sampleRate': sampleRate,
      'channels': channels,
    });
    if (error != null) return error;

    // 第三步：订阅 PCM 水管。receiveBroadcastStream() 是
    // EventChannel 的标准读法，返回 Stream<dynamic>，
    // 原生推的是 ByteArray → 到这里就是 Uint8List。
    // 补充：原生推数据必须在主线程（MainActivity 里 runOnUiThread { sink.success(...) }），
    // 否则 Flutter 报 "EventSink calls must be made on the platform thread"。
    // listen(回调) 就是"接水"：每来一滴（一块字节）执行一次回调，
    // 它是非阻塞的 —— 注册完立刻返回，回调在未来某个时刻被事件循环调用。
    isRunning = true;
    _dataSub = _dataChannel.receiveBroadcastStream().listen((event) {
      // is! 是"类型判断取反"：event 是 dynamic，只有确认是 Uint8List 才敢往下传
      //（不是就 return 丢掉这一条，防御性写法）。
      if (event is! Uint8List) return;
      onData?.call(event); // 原样转发给上层（MicProvider 发 WebSocket）
      // onData 是可空的（可能没人挂回调），?.call(...) 的意思是"不为 null 才调用"，
      // 少了这个 ?. 在没人赋值时会抛空指针异常。
      onLevel?.call(_rms(event)); // 顺手算个响度给界面
    });
    return null;
  }

  /// 停止采集并释放原生资源
  Future<void> stop() async {
    if (!isRunning) return;
    // 先改标志再干活：避免"停的过程中又有人调 stop"。
    isRunning = false;
    await _dataSub?.cancel(); // 先关水管（listen 了必须 cancel）
    // cancel() 之后原生那侧的 onListen 配对变成 onCancel（MainActivity 把
    // micEventSink 置 null），采集线程即便还在跑也推不进水了 ——
    // 顺序别反过来：先停原生再 cancel 会有一小段"没人接水"的推流浪费。
    _dataSub = null;
    await _channel.invokeMethod('stopMic'); // 再让原生停线程、release
    // 原生 stopMic 里 micRunning=false 并 join(500)（最多等 0.5 秒收尾）。
  }

  /// 计算一块 PCM s16le 数据的 RMS 响度（均方根），归一化 0.0 ~ 1.0。
  ///
  /// 通俗解释：把每个采样值平方 → 求平均 → 开平方，
  /// 得到"平均能量"，比取最大值更稳定，适合画电平条。
  // RMS = Root Mean Square（均方根）。为什么先平方：声音采样正负对称，
  // 直接求平均永远是 0 左右；平方后全是正数，代表能量，再开方把量级拉回来。
  // 这块数据本身是"PCM 16 位小端"：每 2 个字节合成一个有符号整数（一个采样点）。
  double _rms(Uint8List data) {
    // 不足一个采样点（连 2 字节都凑不齐）就没意义，直接当 0
    if (data.length < 2) return 0;
    // asByteData()：把字节数组"换个视角"看成 16 位采样序列
    // ByteData 是"按类型读写字节"的视图：它可以把相邻两字节读成 int16/int32/float…
    // 视图是【零拷贝】的：不复制字节，只是换种解释方式看同一块内存。
    final bd = ByteData.sublistView(data);
    double sum = 0;
    final count = data.length ~/ 2; // ~/ 是整数除法：字节数 ÷2 = 采样数
    for (var i = 0; i < count; i++) {
      // 小端序（Little-Endian）= 低位字节排在前面。
      // 例：字节 [0x34, 0x12] 按小端读是 0x1234 = 4660；按大端读就成了 0x3412。
      // s16le 的 le 就是 little-endian，所以这里必须传 Endian.little，
      // 传错会读到完全无关的巨大数值，电平条会一路顶满。
      // getInt16 返回 -32768 ~ 32767，正是 16 位有符号整数的范围。
      final s = bd.getInt16(i * 2, Endian.little); // 小端序读 16 位采样
      sum += s * s;
    }
    // 32768 = i16 的最大幅度，除完结果落在 0~1
    // （为什么除以 32768 而不是 32767：满幅负值是 -32768，除它以 1.0 封顶更准）。
    // 顺带估算：48k 单声道 20ms 的一块 = 960 个采样，这个循环跑 960 次，
    // 每秒约 50~100 块 → 每秒不到 10 万次迭代，对手机来说完全不是负担。
    return math.sqrt(sum / count) / 32768.0;
  }

  // ── v3.1：麦克风守护前台服务 ────────────────────────────────
  // 作用：连上电脑后挂一条常驻通知，让系统不要杀进程 ——
  // 息屏状态下 PC 的唤醒指令（mic_state）才能随时送达。
  // 注意这个服务本身不开麦克风，省电靠的就是"只在需要时开采集"。
  //
  // 新手补充：Android 对后台 App 很凶（内存紧张时会直接杀进程），
  // "前台服务（Foreground Service）"是官方给的合法保活通道，代价是必须在
  // 通知栏挂一条用户能看到的常驻通知。Android 12+ 还要 POST_NOTIFICATIONS
  // 通知权限，被拒时原生启动服务会抛异常 —— 所以下面要 try/catch。
  // 原生对应 MicForegroundService（MainActivity.kt 的 startMicStandby 分支）。

  /// 启动守护服务（连接成功、待命登记前调用）
  Future<void> startStandbyService() async {
    try {
      await _channel.invokeMethod('startMicStandby');
    } catch (_) {
      // 服务启动失败（如通知权限被拒）不致命：手机亮屏时功能照常，
      // 只是息屏待机不可靠，不做错误弹窗打扰
      // 这类"降级不报错"的取舍是有意的：把通知权限缺失变成用户可感知的
      // 阻塞提示，体验反而差。若将来要提示，应该往 MicProvider 记一个文案键。
    }
  }

  /// 停止守护服务（手动关闭麦克风、断开连接时调用）
  // 记得配套调用：起守护的地方多（MicProvider.enterStandby、stop、dispose、
  // 断线清理），所以内部一律用 try/catch 兜住，重复调用无害。
  Future<void> stopStandbyService() async {
    try {
      await _channel.invokeMethod('stopMicStandby');
    } catch (_) {}
  }

  /// 释放（App 退出时调用；stop 内部已处理未启动的情况）
  // 这是"资源销毁"链条的末端：MicProvider.dispose() 里调它。
  // 顺序：先停采集（关水管 + stopMic）→ 再撤守护通知。
  // 反过来做会让通知还在挂着、麦克风已被释放，状态看起来"还在守护"其实啥都没干。
  Future<void> dispose() async {
    await stop();
    await stopStandbyService();
  }
}
