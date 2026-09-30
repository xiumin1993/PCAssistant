// ============================================================================
// network_service.dart —— 网络服务层（WebSocket 客户端）
// ----------------------------------------------------------------------------
// 本文件是"手机 ↔ 电脑"通信的核心。手机作为 WebSocket 客户端，
// 连接电脑端运行的服务器（Rust AudioServer），接收服务器推过来的音频字节流。
//
// 什么是 WebSocket？
//   普通 HTTP 是"一问一答"：客户端请求一次，服务器回答一次就结束。
//   WebSocket 是"打电话"：连接建立后双向通道一直开着，
//   服务器可以随时把音频数据推送过来 —— 这正是实时音频流需要的模式。
//
// 什么是 Stream（流）？（Flutter/Dart 最重要的概念之一）
//   Stream 是一个"随时间陆续产出数据的管道"。
//   类比：水龙头。你不接水时它待命；拧开（listen 订阅）后水（数据）
//   持续流出来；关水（close）就结束。
//   本服务对外提供 3 条流：连接状态流、音频数据流、错误流。
//   上层（ConnectionProvider）订阅它们，就能"被动地"知道发生了什么，
//   而不需要轮询查询。
//
// 设计原则：这一层只管"网络收发"，不碰界面、不含业务逻辑，
// 收到的音频数据原样丢进流里，谁需要谁订阅。这叫"关注点分离"。
//
// ── 补充说明书（给初学者；以下全是注释，不含代码改动）─────────────────────
//
// 【谁调用我】
//   lib/providers/connection_provider.dart —— 唯一调 connect()/disconnect() 的人
//     （首页大按钮 toggleConnection），并订阅 connectionStatusStream /
//     audioDataStream / audioConfigStream / errorStream 四条流（它的"监听 1~4"）。
//   lib/providers/mic_provider.dart —— 订阅 micAckStream/micStateStream，
//     用 send() 发 JSON 控制消息（mic_start / mic_mute / mic_stop）和 PCM 二进制块。
//   lib/providers/camera_provider.dart —— 订阅 camAckStream/camStateStream/
//     camRequestStream/camForceStopStream，用 send() 发 cam_capabilities /
//     cam_start / cam_stop 和"4 字节魔术头 + JPEG"。
//   lib/main.dart —— Provider<NetworkService> 建全局唯一实例，App 退出时 dispose()。
//
// 【我调用谁】第三方包 web_socket_channel（pubspec.yaml 里 ^3.0.1）→
//   它内部用 dart:io 的 WebSocket/Socket → TCP。本文件不碰任何 MethodChannel，
//   和原生层无关（原生那边只处理音频/相机硬件）。
//
// 【地址里的魔数】
//   · 端口 8080：PC 上 Rust AudioServer 的默认监听端口（首页 USB 输入框
//     默认值也写死 8080，见 connection_provider.dart 的 _usbPortController）。
//     改了要两端同时改，否则连不上（表现是 SocketException: Connection refused）。
//   · 路径 /ws/audio：服务器路由约定，连错路径会得到 HTTP 404 式失败。
//   · ws:// 是 WebSocket 的明文协议；wss:// 才是加密版（本项目在局域网内跑，
//     用 ws:// 就够，也不需要 443/证书）。
//   · USB 模式连 127.0.0.1：靠 `adb reverse tcp:8080 tcp:8080` 把手机的 8080
//     镜像到电脑的 8080，所以这里的"本机地址"其实是电脑（原理注释在
//     connection_provider.dart 里，别搞混 adb forward 的方向）。
//
// 【一帧的完整布局 —— 下行（PC → 手机）】
//   WebSocket 自己已经把消息分好帧（文本帧 / 二进制帧，有 FIN+opcode+长度字段），
//   所以本文件【不需要】"前 N 字节是长度"的自定义头 —— 一次 message 回调
//   拿到的 data 就是一条完整消息。Rust 侧按同样规则切：一条 WS message 一件事。
//     文本帧（UTF-8 JSON）：{"type":"audio_config","sample_rate":48000,
//       "channels":2,"format":"pcm_s16le"} 之类，控制消息全在这一类；
//     二进制帧：纯 PCM，s16le（16bit 有符号小端），按 audio_config 的
//       采样率×声道数×2 字节/秒 排布，例如 48000×2×2=192000 字节/秒。
//
// 【一帧的完整布局 —— 上行（手机 → PC）】
//   麦克风：二进制消息 = 原始 PCM 块，【没有任何包头】（48000×1×2=96000 字节/秒）。
//   摄像头：二进制消息 = 4 字节魔术头 + JPEG 本体：
//       字节 0     0x03          分隔哨兵（控制字符，音频里极少出现）
//       字节 1~3   0x43 0x41 0x4D  ASCII 'C' 'A' 'M'
//       字节 4~    FF D8 ... FF D9  一张完整 JPEG
//     这个头由 lib/providers/camera_provider.dart 的 _frameMagic 拼接
//     （注意：常量在 provider 里，不在本文件），Rust 侧靠它把画面帧和
//     麦克风 PCM 分流 —— 两者共用同一条 WebSocket 的二进制通道。
//   控制消息：JSON 文本帧，type 取值 mic_start / mic_mute / mic_stop /
//     cam_capabilities / cam_start / cam_stop（发送点都在两个 provider 里）。
//
// 【超时与重连（新手最常被问到，本文件目前都没做）】
//   · 连接超时：现在只 await _channel!.ready，成败取决于操作系统的 TCP 超时
//     （"连不上"可能要等十几秒到几十秒才报错）。想加的话有两种写法：
//       A. await _channel!.ready.timeout(const Duration(seconds: 5));
//          Future 自带 timeout()，超时抛 TimeoutException，被下面 catch 接住；
//       B. 用 Completer + Timer：Completer 是"我自己手动兑现的 Future"——
//          new Completer<void>() → Timer(5s){ if(!c.isCompleted) c.completeError(...) }
//          → 连接成功时 c.complete() → await c.future。
//          为什么要有 Completer：有些"完成时机"只有你自己知道（原生回调、
//          多个事件里挑第一个），无法由语言自动生成 Future，就自己造一个凭据。
//     （本仓库目前没有使用 Completer，也没有 connectTimeout 字段，故只作说明；
//       要加请由作者动手，我只写注释。）
//   · 自动重连与退避（backoff）：断线后 App 现在交给用户重点"连接"
//     （onDone 只把状态广播成 disconnected；MicProvider/CameraProvider 各自
//      清理状态，摄像头会记住 _guardWanted 意图，等用户重连后自动恢复登记）。
//     若要自己做重连，标准做法是"指数退避"：第 1 次等 1s、第 2 次 2s、4s、8s…
//     封顶 30s 并加随机抖动。为什么退避：网络刚断时立刻死循环重连，
//     既打爆服务器又白耗电，退避让重试频率随失败次数下降。
//
// 【新手建议阅读顺序】connect()（含里面那个 listen 回调）→ send() →
//   disconnect() → dispose()；流相关的 getter 当"词典"查就行。
// ============================================================================

// dart:async：Dart 官方库，提供 Stream、StreamController、
// StreamSubscription 等异步/流处理能力（不用 pub get，内置）
import 'dart:async';
// 补充：Stream（陆续产出数据的管道）、StreamController（生产端）、
// StreamSubscription（订阅凭证，listen 回来的一定要 cancel）是本章三件套。
// 另一个常见成员 Future/Completer 也在这个库里（Future 由 dart:core 自动可见）。

// dart:convert：提供 jsonDecode，用于解析服务器发来的 JSON 配置头。
// 服务器连接后会先发一条文本消息告知音频格式（采样率、声道数等），
// 后续才是二进制音频数据。需要 JSON 解析器来提取这些配置信息。
import 'dart:convert';
// jsonDecode(String) 返回 dynamic —— 编译器不知道它是 Map 还是 List，
// 所以下面取值前一律先判 `json is Map`，这叫"运行时类型检查"。
// 同一个库还提供 jsonEncode（两个 provider 用它拼控制消息）。

// dart:typed_data：提供 Uint8List —— "无符号 8 位整型数组"，
// 即原始字节数组。音频、图片等二进制数据在网络上传输就是这种格式。
import 'dart:typed_data';
// 与 ByteData 的关系（新手常混）：Uint8List 是"一字节一格"的裸数组；
// ByteData 是同一块内存的"按类型读写"视图（可 getInt16/getFloat32）。
// PCM 字节在这里始终以 Uint8List 形态流动，交给 AudioService 前不做解析 ——
// 解析（把字节当 16 位采样）发生在两处：mic_service._rms 和原生 AudioTrack。

// web_socket_channel：Dart 社区最常用的 WebSocket 库。
// 相比 dart 内置的 WebSocket，它返回的是标准 Stream，
// 与整个异步生态衔接更好。
import 'package:web_socket_channel/web_socket_channel.dart';
// 版本 ^3.0.1（见 pubspec.yaml）：3.x 才有的 `channel.ready` 这个 Future，
// 本文件靠它来"等握手真的完成"。升级到 2.x 以前的写法要改成监听 stream。

/// 连接状态枚举。
///
/// enum（枚举）：把一个东西"只能是的那几种情况"列成清单。
/// 连接生命周期只有 4 个合法状态，用枚举可以避免
/// 出现 "conneted"（拼写错误）之类的字符串比较事故，
/// 而且 switch 枚举时编译器会检查你是否处理了所有情况。
// 再补三点新手要知道的用法：
//   · ConnectionStatus.connected 这种"类型.成员"是取枚举值的唯一写法；
//   · ConnectionStatus.values 是全部值的列表，配合 .index / .name 可以做
//     持久化与恢复（lib/providers/connection_provider.dart 就用 m.name 存字符串）；
//   · 枚举值本身是编译期单例，用 == 比较完全安全（不需要 compareTo）。
enum ConnectionStatus {
  disconnected, // 未连接（初始状态 / 连接已关闭）
  connecting,   // 正在连接中（等待服务器响应）
  connected,    // 已连接（通道打开，可以收数据）
  error,        // 出错（连接失败或被中断）
}

/// 一条网络错误事件（v3.7 国际化引入）。
///
/// 为什么不用 String：以前这里流的是"连接失败: xxx"这种拼好的中文句子，
/// 界面直接显示 —— 一旦要支持多语言，网络层就必须知道当前语言，
/// 分层就烂了。现在网络层只上报【事实】：
///   kind   —— 哪一类错误（发起连接就失败 / 连上之后通道出错），界面据此选文案键
///   detail —— 原始异常文字（英文、带 errno，排查用，不参与翻译）
/// 界面拿到 kind+detail 才翻成人话。
// 这种"只有两个 final 字段 + const 构造"的类叫值对象/DTO：
// 不可变（final）、可以编译期创建（const）、在流里传递不用担心被人改。
// const NetErrorEvent(...) 构造里没有 this.xxx 的赋值语句，
// 因为位置参数 `this.kind, this.detail` 已经自动完成赋值。
class NetErrorEvent {
  final NetErrorKind kind;
  final String detail;

  const NetErrorEvent(this.kind, this.detail);
}

/// 错误类别。用 enum 而不是字符串，理由同 ConnectionStatus。
enum NetErrorKind {
  connectFailed, // 连不上（地址错、服务器没开、超时、拒绝连接）
  streamError, // 连上之后通道出错/中断
}

/// 音频配置信息（服务器连接后发送的 JSON 头部解析结果）。
///
/// 服务器在发送音频数据之前，会先发一条 JSON 文本消息，
/// 告知音频格式参数（采样率、声道数等）。本端必须据此配置播放器，
/// 否则播放速度/音调会异常。
///
/// class 关键字：定义一个"数据类"，把相关的几个字段打包在一起。
/// final 字段：创建后不可修改（不可变对象），线程安全，适合在流中传递。
// 三个参数怎么决定"一秒多少字节"（新手要记住的算式）：
//   字节/秒 = 采样率(Hz) × 声道数 × 每样本字节数
//   本项目的 pcm_s16le 每样本固定 2 字节（16 bit）：
//     48000 × 2 × 2 = 192000 字节/秒（PC → 手机扬声器）
//     48000 × 1 × 2 =  96000 字节/秒（手机麦克风 → PC，单声道）
//   采样率错 → 音调/时长变（播成"花栗鼠"或"慢牛"）；
//   声道数错 → 左右声道错位、声音发飘；
//   位深/格式错（比如把 s32 当 s16 读）→ 一片刺耳噪声。
class AudioConfig {
  final int sampleRate;   // 采样率（Hz），如 48000
  final int channels;     // 声道数，如 2（立体声）
  final String format;    // 编码格式，如 "pcm_s16le"（16 位有符号，小端序）

  /// 构造函数：创建时必须提供这三个值。
  /// required 关键字：命名参数必传，漏写编译器直接报错。
  const AudioConfig({
    required this.sampleRate,
    required this.channels,
    required this.format,
  });
}

/// 网络服务 - 管理 WebSocket 连接
///
/// 生命周期：随 App 启动创建（见 main.dart），全 App 单例共用，
/// App 退出时调用 dispose() 释放。
// "单例"在这里不是自己写的 getInstance()，而是靠 provider 库保证：
// main.dart 里 Provider<NetworkService>(create: ...) 只 create 一次，
// 所有 context.read<NetworkService>() 拿到的都是同一个对象 ——
// 所以这三个 Provider（connection/mic/camera）才能共享一条连接。
class NetworkService {
  /// 当前的 WebSocket 通道。声明为可空（WebSocketChannel?）
  /// 因为"未连接时它不存在"。这是 Dart 的空安全机制：
  /// 类型带 ? 表示可以是 null，编译器强制你在使用前判空，
  /// 从源头避免"空指针崩溃"。
  // 配套的两个语法糖（本文件都在用）：
  //   x!.member  非空断言："我保证这里不是 null"，猜错就运行时报错；
  //   x?.member  条件访问："是 null 就整句返回 null"，不崩。
  WebSocketChannel? _channel;

  /// 对 _channel.stream 的订阅句柄。
  /// 必须保存它，因为断开连接时要调用 cancel() 取消订阅，
  /// 否则回调会持续触发、造成内存泄漏。
  // 记住这条铁律：listen() 返回的 StreamSubscription 是"欠下的债"，
  // 必须在生命周期结束时 cancel()，否则回调会摸到已经销毁的对象。
  StreamSubscription? _subscription;

  // --------------------------------------------------------------------------
  // 三条对外的"数据管道"
  // --------------------------------------------------------------------------
  // （实际不止三条，下面一共 10 条，分类看就清楚：
  //   状态类 1 条、下行数据 2 条（音频字节 + 音频配置）、错误 1 条、
  //   麦克风 2 条（回执 + 开关）、摄像头 4 条（回执/开关/请求/强制关）。）
  // StreamController（流控制器）是流的"生产者端"：
  //   - controller.add(数据)  = 往管道里放水（发出事件）
  //   - controller.stream     = 管道的"出水口"，外部只能通过它订阅，
  //                             不能直接往管道里塞东西（保护内部状态）。
  //
  // .broadcast 修饰很重要：
  //   普通流（单订阅流）只允许一个人 listen；
  //   广播流允许多个订阅者同时收到相同的数据，
  //   类似"电台广播"。本项目虽然目前只有 ConnectionProvider 一个订阅者，
  //   但广播流更安全，将来加页面监听也不用改这里。
  // 再补三个新手会撞上的点：
  //   1) 广播流是"直播"不是"录像"：add 的时候没人订阅，这个事件就永远丢了。
  //      所以界面后打开时，要靠 getter（如 status / isConnected）读"当前快照"，
  //      或者由 Provider 自己缓存最后一值（本项目 Provider 就是这么做的）。
  //   2) 默认是 async 调度：add() 不会当场执行回调，而是在下一个事件循环 tick
  //      才派发（避免回调里同步改状态引起重入）。StreamController(sync: true)
  //      才是立即派发，本项目没用 sync。
  //   3) controller.close() 之后不能 add，订阅者收到"流结束"事件；
  //      本文件只在 dispose() 里关管道（App 退出），运行期一直开着。
  final _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast(); // 状态变化广播
  final _audioDataController = StreamController<Uint8List>.broadcast(); // 音频字节广播
  final _audioConfigController = StreamController<AudioConfig>.broadcast(); // 音频配置广播
  final _errorController =
      StreamController<NetErrorEvent>.broadcast(); // 错误事件广播（v3.7 起带类型）
  // v3：服务器对 mic_start 的回执（"mic_ack"）广播。
  // MicProvider 订阅它，收到才把界面切成"上行中"。
  // 类型是 String（就把回执名字原样丢出来当"有事发生"的信号）；
  // 订阅方其实只关心"来了一条"，值本身不重要（见 mic_provider 的 (_) {} 写法）。
  final _micAckController = StreamController<String>.broadcast();

  // v3.1：PC 端发来的"麦克风被占用中"开关指令广播（true = 有应用在录 CABLE Output）。
  // 手机连上电脑后默认只是"待命"（不开录音，省电），
  // 收到 true 才开始真正采集 —— 这就是"像真麦克风一样自动待命"的实现。
  final _micStateController = StreamController<bool>.broadcast();

  // ── v3.4 摄像头指令管道 ─────────────────────────────────────
  // cam_ack      服务器对 cam_start 登记的回执（可附带 active 字段）
  final _camAckController = StreamController<String>.broadcast();
  // cam_state    PC 是否有应用正在观看虚拟摄像头（true → 手机该开相机）
  final _camStateController = StreamController<bool>.broadcast();
  // cam_request  PC 端 GUI 点了"请求手机开启摄像头" → 手机弹确认
  // StreamController<void>：这条流"只有事件、没有载荷"，
  // 所以下面用 add(null) 表示"发生了这件事"，订阅者的回调参数类型是 void（拿不到也用不上）。
  // 为什么要发明这种"空类型流"：指令本身不带信息（信息在 JSON 里已被判过类型），
  // 只需要通知"来了一条 cam_request"。用 bool 反而让人猜 true/false 是什么意思。
  final _camRequestController = StreamController<void>.broadcast();
  // cam_stop(forced)  PC 端"强制关闭"隐私开关 → 手机立即注销摄像头会话
  final _camForceStopController = StreamController<void>.broadcast();

  // 内部维护的"当前状态"变量，带 _ 前缀表示私有（类外不可见）。
  // Dart 没有 public/private 关键字，用下划线前缀约定私有成员。
  // 这个字段是"快照"，让界面不订阅流也能问一句"现在连着吗"（见下面 isConnected）。
  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// 连接状态流（只读出口）。
  /// 外部拿到的是 Stream（只能订阅），拿不到 Controller（不能伪造状态），
  /// 这是封装的标准做法：内部可写，外部只读。
  // 语法拆开看：`Stream<ConnectionStatus> get connectionStatusStream => 表达式;`
  //   get 表示"这是一个只读属性"，调用方写 network.connectionStatusStream（没有括号）。
  //   箭头 => 后面跟的是"值"，等价于 { return ...; }。
  //   三行同类的 getter（下面一直到 camForceStopStream）都只是"把私有 Controller 的
  //   出水口递出去"，本类内部一律用 _xxxController.add(...) 生产事件。
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  /// 音频数据流：服务器推来的每一块音频字节都会从这里流出
  // 消费者：lib/providers/connection_provider.dart 的"监听 2"，
  // 它把这块字节交给 AudioService.receiveAudioData() → 原生 AudioTrack → 扬声器。
  // 本文件对 PCM 内容零解析，纯粹"原样搬运"。
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  /// 音频配置流：服务器连接后发送的 JSON 配置头解析结果从这里流出。
  /// ConnectionProvider 订阅它，收到后调 AudioService.updateConfig() 同步配置。
  Stream<AudioConfig> get audioConfigStream => _audioConfigController.stream;

  /// 错误信息流：发生错误时，一条 NetErrorEvent 从这里流出。
  ///
  /// v3.7 国际化：这里【不再】拼中文句子（以前是 '连接失败: $e'）。
  /// 因为网络层不知道界面当前是什么语言，也不该知道 ——
  /// 它只负责把"哪一类错误 + 原始异常文字"如实报上去，
  /// 由 Provider 存成错误码，最后由界面用 AppLocalizations 翻成人话。
  Stream<NetErrorEvent> get errorStream => _errorController.stream;

  /// v3：mic_ack 回执流（服务器确认已开启手机麦克风上行）
  Stream<String> get micAckStream => _micAckController.stream;

  /// v3.1：mic_state 指令流（true = PC 应用正在用麦克风 → 手机该上行；false → 回待命）
  Stream<bool> get micStateStream => _micStateController.stream;

  /// v3.4：cam_ack 回执流（服务器确认摄像头会话已登记）
  Stream<String> get camAckStream => _camAckController.stream;

  /// v3.4：cam_state 指令流（true = PC 应用正在观看 → 手机开相机；false = 回待命）
  Stream<bool> get camStateStream => _camStateController.stream;

  /// v3.4：cam_request 指令流（PC GUI 请求手机开启摄像头，手机需用户确认）
  Stream<void> get camRequestStream => _camRequestController.stream;

  /// v3.4：cam_stop(forced) 指令流（PC GUI 强制关闭 → 手机立即注销会话）
  Stream<void> get camForceStopStream => _camForceStopController.stream;

  /// 当前连接状态（快照式读取，不走流）
  // 和流的区别：流告诉你"什么时候发生了变化"，快照告诉你"现在是什么"。
  // 界面 initState 里建好之后才订阅，会错过之前的广播，所以要用快照兜底。
  ConnectionStatus get status => _status;

  /// 便捷判断：是否处于"已连接"状态
  // == 比较枚举值：枚举实例是编译期单例，直接用 == 就行（不需要 compareTo/equals）。
  bool get isConnected => _status == ConnectionStatus.connected;

  /// 连接到服务器。
  ///
  /// 返回类型 `Future<void>`：
  ///   Future = "未来会完成的一件事"，是 Dart 异步编程的基石。
  ///   HTTP 连接不是瞬间完成的，函数先返回一个 Future 凭证，
  ///   调用方用 await 等待它真正完成。
  ///   async 关键字允许在函数体内使用 await。
  // 再展开一点（初学必修）：
  //   · Dart 跑在单线程事件循环上：同一时刻只有一段 Dart 代码在执行。
  //     await 不是"睡着"，而是"我先返回，好了再叫我"—— 期间界面照常动画、
  //     别的回调照常跑，这就是为什么不 await 卡不住 UI 而忙等会卡死。
  //   · 只有 async 标记的函数里才能写 await；调用它的函数如果也想等结果，
  //     它自己也得是 async（异步函数会像涟漪一样往上传染）。
  //   · 返回 Future<void> 表示"有结束时刻但没有返回值"。
  //   · 调用方可以 await connect(addr)（connection_provider 就是 await 的），
  //     也可以不 await（fire-and-forget），后者要自己保证错误有地方接住
  //     —— 本方法内部已经 try/catch 全兜住了，所以不 await 也安全。
  ///
  /// @param serverAddress 用户输入的地址，如 "192.168.1.100:8080"
  Future<void> connect(String serverAddress) async {
    // 防重复点击：已经在连接中就忽略本次调用
    // 注意只挡了 connecting，没挡"已经 connected"：连着的时候再点连接，
    // 由上层 ConnectionProvider.toggleConnection 先 disconnect 再 connect
    // （见 lib/providers/connection_provider.dart 分支 A/B）。
    // 若哪天有别的入口绕过它直接调 connect，_channel 会被新对象覆盖，
    // 旧通道和旧订阅就成了泄漏点（这里只是提示，不改代码）。
    if (_status == ConnectionStatus.connecting) return;

    // 进入"连接中"状态并广播，界面会据此显示转圈动画
    _updateStatus(ConnectionStatus.connecting);

    try {
      // 【构建 WebSocket URL】
      // 用户可能输入两种格式：
      //   完整形式 "ws://192.168.1.100:8080/ws/audio" —— 原样使用
      //   简短形式 "192.168.1.100:8080"              —— 自动补全协议和路径
      // ws:// 是 WebSocket 的协议前缀（类比 http://），
      // /ws/audio 是与服务器约定的音频流接口路径。
      // 三元表达式：条件 ? A : B —— 条件成立取 A，否则取 B
      // startsWith 是 String 的普通方法（区分大小写，'WS://' 不会被认出来）。
      final url = serverAddress.startsWith('ws://')
          ? serverAddress
          : 'ws://$serverAddress/ws/audio'; // $变量名 是字符串插值

      // 【发起连接】
      // WebSocketChannel.connect 只是"开始拨号"，返回通道对象，
      // 此时连接未必已建立。Uri.parse 把字符串解析成标准的 URL 对象。
      // Uri.parse 会顺手做校验：地址里有非法字符（空格、中文）时它自己抛异常，
      // 会被下面的 catch 接住 —— 这就是"用户乱填地址也只会显示错误而不是崩溃"。
      _channel = WebSocketChannel.connect(Uri.parse(url));

      // 【等待连接真正建立】
      // .ready 是一个 Future：TCP 握手 + WebSocket 升级完成时它才结束。
      // await 在这里暂停函数、等结果，失败会抛异常被下面的 catch 接住。
      // 没有这一句的话，"服务器没开机"这种错误会被延迟、难以捕获。
      // 补充 WebSocket 握手机制：它先发一个普通 HTTP 请求，带
      //   Upgrade: websocket / Connection: Upgrade / Sec-WebSocket-Key 三个头，
      //   服务器同意就回 101 Switching Protocols，之后这条 TCP 连接改走 WS 帧格式。
      //   所以"连不上"可能是：IP 不通（路由/防火墙）、端口没人监听（refused）、
      //   路径不对（服务器回 404 而不是 101）—— 三种错在 ready 上都抛异常。
      // ⚠ 本文件没有设置任何超时（库本身也没有 connectTimeout 参数）。
      //   操作系统级 TCP 超时通常要十几秒以上，"服务器没开机"时用户会看到
      //   长时间转圈。想改善就写：await _channel!.ready.timeout(Duration(seconds: 5))
      //   或用 Completer + Timer 自己造超时（概念见文件头"超时与重连"一节）。
      //   本任务只加注释，具体改法由作者决定。
      await _channel!.ready; // ! 表示"我确认这里不为 null"

      _updateStatus(ConnectionStatus.connected);

      // 【订阅通道数据流 —— 开始"收货"】
      // listen(回调, onError:, onDone:) 三个参数对应流的三种"结束或来料"事件：
      //   onData    ：每来一条 WS 消息调用一次（本方法的核心工作都在这里）
      //   onError   ：通道本身出错（对端异常断开、协议错误等）
      //   onDone    ：连接正常关闭（自己 close 或对端 close 都会走到）
      // 顺带一提另一种写法：await for (final data in _channel!.stream) { ... }
      //   等价于 listen，但会把所在函数一直"占住"直到流关闭，还要自己处理
      //   退出循环的时机；本项目统一用 listen（本文件没有 await for）。
      _subscription = _channel!.stream.listen(
        (data) {
          // data 的类型是 dynamic：WS 文本帧给 String，二进制帧给 List<int>/Uint8List，
          // 所以必须先 is 判类型再处理，绝不能直接当字节用。
          if (data is String) {
            // 【文本帧：JSON 音频配置 / mic 回执 / mic 开关指令】
            // 本项目所有"控制类"消息都是 JSON 文本帧，一共认这几种 type：
            //   audio_config / mic_ack / mic_state / cam_ack / cam_state /
            //   cam_request / cam_stop(forced=true)
            // 认不出的 type 直接忽略（不报错）—— 这是"前向兼容"：
            // 以后服务器加新消息类型，老版本 App 只会看不懂、不会崩。
            try {
              final json = jsonDecode(data);
              // json is Map：确认解码结果是对象（服务器可能发数组或裸字符串）。
              // 用 Map 而不是 Map<String, dynamic> 是因为泛型不匹配时
              // 严格判断会把合法数据判掉（这里宽松一点更安全）。
              if (json is Map && json['type'] == 'audio_config') {
                // as int 是硬转型：服务器若把这列发成 "48000"（字符串）会直接抛异常，
                // 被下面的 catch 吞掉 → 配置丢失（表现为播放仍是 48k 默认值）。
                final config = AudioConfig(
                  sampleRate: json['sample_rate'] as int,
                  channels: json['channels'] as int,
                  // format 允许缺失（as String?）并用 pcm_s16le 兜底 —— 这是本项目
                  // 唯一的音频格式，服务器不发也按它处理；发了别的值只是记录下来，
                  // 原生侧仍按 16bit 播放（AudioService 忽略 format 字段）。
                  format: json['format'] as String? ?? 'pcm_s16le',
                );
                _audioConfigController.add(config);
              } else if (json is Map && json['type'] == 'mic_ack') {
                // v3：服务器确认收到 mic_start，手机麦克风上行已建立
                _micAckController.add('mic_ack');
                // v3.1：回执可附带 active 字段 —— 若 PC 应用已在录，
                // 立刻按"上行中"处理，不用等下一条 mic_state
                // 不加 as 而是 `final active = json['active']` 取 dynamic，
                // 再用 `if (active is bool)` 判断：字段可能压根不存在（null），
                // 这种写法比 `as bool` 安全（后者遇到 null/字符串就抛异常）。
                final active = json['active'];
                if (active is bool) _micStateController.add(active);
              } else if (json is Map && json['type'] == 'mic_state') {
                // v3.1：PC 端自动感知指令。true = 有应用打开了 CABLE Output
                //（相当于"有人按下对讲机"），手机应立即开始上行；
                // false = 应用关闭了麦克风，手机回到省电待命。
                final active = json['active'];
                if (active is bool) _micStateController.add(active);
              } else if (json is Map && json['type'] == 'cam_ack') {
                // v3.4：服务器确认摄像头会话已登记
                _camAckController.add('cam_ack');
                // 回执附带 active 字段：登记时 PC 已在观看 → 立刻按"取景中"处理
                final active = json['active'];
                if (active is bool) _camStateController.add(active);
              } else if (json is Map && json['type'] == 'cam_state') {
                // v3.4：PC 应用打开/关闭了 Unity Video Capture 虚拟摄像头。
                // true = 有人正在观看 → 手机此刻才开相机硬件；
                // false = 没人看了 → 手机立即关相机回待命（按需取景，省电+隐私）
                final active = json['active'];
                if (active is bool) _camStateController.add(active);
              } else if (json is Map && json['type'] == 'cam_request') {
                // v3.4：PC GUI 点了"请求手机开启摄像头" → 手机弹确认框
                // add(null)：void 流没有载荷，"发一条事件"本身就是全部信息。
                _camRequestController.add(null);
              } else if (json is Map &&
                  json['type'] == 'cam_stop' &&
                  json['forced'] == true) {
                // v3.4：PC GUI 的"强制关闭"隐私开关 → 手机立即注销会话
                // 只认 forced == true：普通 cam_stop（手机自己发的注销回执）
                // 不该触发这里，否则会和 provider 自己的 stop() 打架。
                _camForceStopController.add(null);
              }
            } catch (_) {
              // JSON 解析失败，忽略无效数据
              // 注意这一句 catch 的范围很大：从 jsonDecode 到每个 as 转型都在里面。
              // 好处是乱七八糟的数据打不崩 App；代价是"字段类型写错"这种真 bug
              // 会被静默吞掉（现象：配置不生效但没有任何报错）。
              // 更好的做法（留给作者决定，本任务不改）：把 as 换成宽松取值，
              // 或者 catch 到异常时通过 _errorController 报一条排查用事件。
            }
          } else if (data is Uint8List) {
            // 【二进制帧：音频 PCM 数据】
            // 到了这条分支就说明"WS 消息已完整"，PCM 字节原样转出去即可，
            // 本层绝不解析采样值（解析在 AudioService→原生 AudioTrack 那边）。
            _audioDataController.add(data);
          } else if (data is List<int>) {
            // 兜底分支：某些平台/版本的 web_socket_channel 会把二进制帧给成
            // 普通 List<int>（每个元素还是 0~255，但内存布局不是紧密的字节数组）。
            // Uint8List.fromList 会【拷贝】出一份紧凑字节数组再转发，
            // 保证下游（AudioService 走 MethodChannel、MicProvider 走 send）拿到的
            // 类型稳定；这个拷贝在每秒上百包的场景是可以接受的。
            _audioDataController.add(Uint8List.fromList(data));
          }
        },
        onError: (error) {
          // 只上报"类别 + 原始异常"，句子交给界面翻译（v3.7 国际化）
          // '$error' 是插值 + 自动 toString：把异常对象变成可读字符串。
          // 这里【没有 rethrow】：rethrow 的作用是在 catch 里"把同一个异常继续
          // 往上抛"（本文件选择自己消化：既不崩溃也不让调用方 await 出错）。
          // 副作用是错误只会以事件形式出现，日志里看不到堆栈，排错要看界面小字。
          _errorController.add(NetErrorEvent(NetErrorKind.streamError, '$error'));
          _updateStatus(ConnectionStatus.error);
        },
        onDone: () {
          // 对端关闭连接时触发（正常挥手或断网都会走到这里）
          // 这里只把状态广播成 disconnected，不做自动重连（概念见文件头"退避"一节）：
          // 麦克风/摄像头两个 Provider 收到 disconnected 会各自清理硬件会话，
          // CameraProvider 还会保留 _guardWanted 意图，等用户手动重连后自动恢复。
          _updateStatus(ConnectionStatus.disconnected);
        },
      );
    } catch (e) {
      // 兜底：地址格式错误、服务器不存在、超时、拒绝连接等
      // e 是异常对象；'$e' 转成文字塞进 detail，界面用 l10n.netFailed(detail) 填占位符。
      // try/catch/finally 三件套复习：finally 是"无论成败都执行"的收尾（本文件没用到，
      // 常见于关文件、释放计时器）；这里不需要，因为资源清理都在 disconnect/dispose 里。
      _errorController.add(NetErrorEvent(NetErrorKind.connectFailed, '$e'));
      _updateStatus(ConnectionStatus.error);
    }
  }

  /// 断开连接（用户点"断开"按钮时走到这里）
  // 调用点：本文件的 dispose()，以及 lib/providers/connection_provider.dart
  // 的 toggleConnection（"已连着再点就先断"）。
  Future<void> disconnect() async {
    // 【第一步：取消数据订阅】
    // 停止接收服务器数据。?. 是"空安全调用"：
    // _subscription 为 null（本来就没连）时跳过，不报空指针。
    // cancel() 返回 Future，这里没 await —— 取消动作本身是本地记账，
    // 不必等它，先关通道更重要。
    _subscription?.cancel();
    _subscription = null;

    // 【第二步：关闭通道】
    // sink（水槽）是往通道里"写数据/关闭"的出口端，
    // 与 stream（读数据的入口端）相对。close() 发送 WebSocket
    // 关闭帧，礼貌地挂断，并释放底层 socket 端口。
    // 术语补充：sink 是"只写"、stream 是"只读"，成对出现；
    // StreamChannel 这个抽象就是 stream + sink 的组合体。
    if (_channel != null) {
      await _channel!.sink.close();
      // 先把引用置空再结束，防止后续 send() 往已关闭的 sink 上写数据
      //（写了不会崩，但会抛 StateError 之类的异常被静默丢弃，白白费解）。
      _channel = null;
    }

    // 【第三步：广播"已断开"状态】界面据此恢复成"未连接"
    // 这一步会连锁触发：ConnectionProvider 停播放、MicProvider 关麦撤守护、
    // CameraProvider 关相机注销会话 —— 都靠这一条广播驱动（改状态请走 _updateStatus）。
    _updateStatus(ConnectionStatus.disconnected);
  }

  /// 向服务器发送数据（预留功能：如音量控制指令、握手消息等）
  ///
  /// dynamic 参数：不限类型（String / `List<int>` 都能传），
  /// WebSocket 通道自己会做编码。
  /// 实际用法（都来自 Provider 层）：
  ///   send(jsonEncode({'type':'mic_start', ...}))  → 文本帧（String）
  ///   send(pcmBytes)                                → 二进制帧（Uint8List，麦克风上行）
  ///   send(packet.toBytes())                        → 二进制帧（4 字节魔术头 + JPEG）
  /// 也就是说这个"预留功能"其实撑起了全部上行流量。
  void send(dynamic data) {
    // 双保险：通道存在 且 状态是已连接，才真正发送；
    // 否则数据会被静默丢弃（也可改成抛异常，视需求定）
    // 为什么选择静默丢弃：麦克风/摄像头是每秒几十上百包的实时流，
    // 断线瞬间抛异常会淹掉日志且没有意义（旧数据已过时，不重传）。
    // 新手注意：本方法是同步 void，没有 await —— add() 只是"把数据交给发送缓冲"，
    // 真正写进 socket 由事件循环稍后完成；TCP 会负责有序可靠到达（对比 UDP 丢包）。
    if (_channel != null && _status == ConnectionStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  /// 内部工具：统一更新状态。
  /// 把"改变量"和"发广播"绑在一起，避免将来漏掉其中一步
  /// 导致界面状态和数据不一致 —— 单一出口原则。
  // 为什么要私有（下划线开头）：外部只能走 connect/disconnect 这些"动作"，
  // 不能直接 set 状态，否则会出现"状态是 connected 但根本没有通道"的分裂局面。
  void _updateStatus(ConnectionStatus status) {
    _status = status;
    _connectionStatusController.add(status);
  }

  /// 释放资源（App 退出时由 main.dart 的 dispose 回调触发）
  ///
  /// Dart 有垃圾回收（GC），但 GC 只管内存，不管"连接、文件句柄、
  /// 流"这类外部资源 —— 必须手动关闭，否则泄漏。
  // dispose 是同步 void（provider 的 dispose 回调要求这个签名），
  // 所以里面不能 await：disconnect() 返回的 Future 没被等待（见下一行）。
  // 实际无害：App 正在退出，操作系统会回收 socket；
  // 若要严谨，可把 disconnect 的清理逻辑同步化或让 main.dart 那侧先 await
  //（本任务只标注，不改代码）。
  void dispose() {
    disconnect(); // 先断连接、取消订阅
    // 再关闭四条流管道，关闭后不可再 add，订阅者收到"结束"事件
    // （现在一共 10 条，逐条列在下面；close() 也返回 Future，同样没 await）
    _connectionStatusController.close();
    _audioDataController.close();
    _audioConfigController.close();
    _errorController.close();
    _micAckController.close();
    _micStateController.close(); // v3.1：关闭 mic_state 指令管道
    _camAckController.close(); // v3.4：关闭摄像头四条管道
    _camStateController.close();
    _camRequestController.close();
    _camForceStopController.close();
  }
}
