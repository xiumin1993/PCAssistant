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
// ============================================================================

// dart:async：Dart 官方库，提供 Stream、StreamController、
// StreamSubscription 等异步/流处理能力（不用 pub get，内置）
import 'dart:async';

// dart:convert：提供 jsonDecode，用于解析服务器发来的 JSON 配置头。
// 服务器连接后会先发一条文本消息告知音频格式（采样率、声道数等），
// 后续才是二进制音频数据。需要 JSON 解析器来提取这些配置信息。
import 'dart:convert';

// dart:typed_data：提供 Uint8List —— "无符号 8 位整型数组"，
// 即原始字节数组。音频、图片等二进制数据在网络上传输就是这种格式。
import 'dart:typed_data';

// web_socket_channel：Dart 社区最常用的 WebSocket 库。
// 相比 dart 内置的 WebSocket，它返回的是标准 Stream，
// 与整个异步生态衔接更好。
import 'package:web_socket_channel/web_socket_channel.dart';

/// 连接状态枚举。
///
/// enum（枚举）：把一个东西"只能是的那几种情况"列成清单。
/// 连接生命周期只有 4 个合法状态，用枚举可以避免
/// 出现 "conneted"（拼写错误）之类的字符串比较事故，
/// 而且 switch 枚举时编译器会检查你是否处理了所有情况。
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
class NetworkService {
  /// 当前的 WebSocket 通道。声明为可空（WebSocketChannel?）
  /// 因为"未连接时它不存在"。这是 Dart 的空安全机制：
  /// 类型带 ? 表示可以是 null，编译器强制你在使用前判空，
  /// 从源头避免"空指针崩溃"。
  WebSocketChannel? _channel;

  /// 对 _channel.stream 的订阅句柄。
  /// 必须保存它，因为断开连接时要调用 cancel() 取消订阅，
  /// 否则回调会持续触发、造成内存泄漏。
  StreamSubscription? _subscription;

  // --------------------------------------------------------------------------
  // 三条对外的"数据管道"
  // --------------------------------------------------------------------------
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
  final _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast(); // 状态变化广播
  final _audioDataController = StreamController<Uint8List>.broadcast(); // 音频字节广播
  final _audioConfigController = StreamController<AudioConfig>.broadcast(); // 音频配置广播
  final _errorController =
      StreamController<NetErrorEvent>.broadcast(); // 错误事件广播（v3.7 起带类型）
  // v3：服务器对 mic_start 的回执（"mic_ack"）广播。
  // MicProvider 订阅它，收到才把界面切成"上行中"。
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
  final _camRequestController = StreamController<void>.broadcast();
  // cam_stop(forced)  PC 端"强制关闭"隐私开关 → 手机立即注销摄像头会话
  final _camForceStopController = StreamController<void>.broadcast();

  // 内部维护的"当前状态"变量，带 _ 前缀表示私有（类外不可见）。
  // Dart 没有 public/private 关键字，用下划线前缀约定私有成员。
  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// 连接状态流（只读出口）。
  /// 外部拿到的是 Stream（只能订阅），拿不到 Controller（不能伪造状态），
  /// 这是封装的标准做法：内部可写，外部只读。
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  /// 音频数据流：服务器推来的每一块音频字节都会从这里流出
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
  ConnectionStatus get status => _status;

  /// 便捷判断：是否处于"已连接"状态
  bool get isConnected => _status == ConnectionStatus.connected;

  /// 连接到服务器。
  ///
  /// 返回类型 `Future<void>`：
  ///   Future = "未来会完成的一件事"，是 Dart 异步编程的基石。
  ///   HTTP 连接不是瞬间完成的，函数先返回一个 Future 凭证，
  ///   调用方用 await 等待它真正完成。
  ///   async 关键字允许在函数体内使用 await。
  ///
  /// @param serverAddress 用户输入的地址，如 "192.168.1.100:8080"
  Future<void> connect(String serverAddress) async {
    // 防重复点击：已经在连接中就忽略本次调用
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
      final url = serverAddress.startsWith('ws://')
          ? serverAddress
          : 'ws://$serverAddress/ws/audio'; // $变量名 是字符串插值

      // 【发起连接】
      // WebSocketChannel.connect 只是"开始拨号"，返回通道对象，
      // 此时连接未必已建立。Uri.parse 把字符串解析成标准的 URL 对象。
      _channel = WebSocketChannel.connect(Uri.parse(url));

      // 【等待连接真正建立】
      // .ready 是一个 Future：TCP 握手 + WebSocket 升级完成时它才结束。
      // await 在这里暂停函数、等结果，失败会抛异常被下面的 catch 接住。
      // 没有这一句的话，"服务器没开机"这种错误会被延迟、难以捕获。
      await _channel!.ready; // ! 表示"我确认这里不为 null"

      _updateStatus(ConnectionStatus.connected);

      // 【订阅通道数据流 —— 开始"收货"】
      _subscription = _channel!.stream.listen(
        (data) {
          if (data is String) {
            // 【文本帧：JSON 音频配置 / mic 回执 / mic 开关指令】
            try {
              final json = jsonDecode(data);
              if (json is Map && json['type'] == 'audio_config') {
                final config = AudioConfig(
                  sampleRate: json['sample_rate'] as int,
                  channels: json['channels'] as int,
                  format: json['format'] as String? ?? 'pcm_s16le',
                );
                _audioConfigController.add(config);
              } else if (json is Map && json['type'] == 'mic_ack') {
                // v3：服务器确认收到 mic_start，手机麦克风上行已建立
                _micAckController.add('mic_ack');
                // v3.1：回执可附带 active 字段 —— 若 PC 应用已在录，
                // 立刻按"上行中"处理，不用等下一条 mic_state
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
                _camRequestController.add(null);
              } else if (json is Map &&
                  json['type'] == 'cam_stop' &&
                  json['forced'] == true) {
                // v3.4：PC GUI 的"强制关闭"隐私开关 → 手机立即注销会话
                _camForceStopController.add(null);
              }
            } catch (_) {
              // JSON 解析失败，忽略无效数据
            }
          } else if (data is Uint8List) {
            // 【二进制帧：音频 PCM 数据】
            _audioDataController.add(data);
          } else if (data is List<int>) {
            _audioDataController.add(Uint8List.fromList(data));
          }
        },
        onError: (error) {
          // 只上报"类别 + 原始异常"，句子交给界面翻译（v3.7 国际化）
          _errorController.add(NetErrorEvent(NetErrorKind.streamError, '$error'));
          _updateStatus(ConnectionStatus.error);
        },
        onDone: () {
          // 对端关闭连接时触发（正常挥手或断网都会走到这里）
          _updateStatus(ConnectionStatus.disconnected);
        },
      );
    } catch (e) {
      // 兜底：地址格式错误、服务器不存在、超时、拒绝连接等
      _errorController.add(NetErrorEvent(NetErrorKind.connectFailed, '$e'));
      _updateStatus(ConnectionStatus.error);
    }
  }

  /// 断开连接（用户点"断开"按钮时走到这里）
  Future<void> disconnect() async {
    // 【第一步：取消数据订阅】
    // 停止接收服务器数据。?. 是"空安全调用"：
    // _subscription 为 null（本来就没连）时跳过，不报空指针。
    _subscription?.cancel();
    _subscription = null;

    // 【第二步：关闭通道】
    // sink（水槽）是往通道里"写数据/关闭"的出口端，
    // 与 stream（读数据的入口端）相对。close() 发送 WebSocket
    // 关闭帧，礼貌地挂断，并释放底层 socket 端口。
    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }

    // 【第三步：广播"已断开"状态】界面据此恢复成"未连接"
    _updateStatus(ConnectionStatus.disconnected);
  }

  /// 向服务器发送数据（预留功能：如音量控制指令、握手消息等）
  ///
  /// dynamic 参数：不限类型（String / `List<int>` 都能传），
  /// WebSocket 通道自己会做编码。
  void send(dynamic data) {
    // 双保险：通道存在 且 状态是已连接，才真正发送；
    // 否则数据会被静默丢弃（也可改成抛异常，视需求定）
    if (_channel != null && _status == ConnectionStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  /// 内部工具：统一更新状态。
  /// 把"改变量"和"发广播"绑在一起，避免将来漏掉其中一步
  /// 导致界面状态和数据不一致 —— 单一出口原则。
  void _updateStatus(ConnectionStatus status) {
    _status = status;
    _connectionStatusController.add(status);
  }

  /// 释放资源（App 退出时由 main.dart 的 dispose 回调触发）
  ///
  /// Dart 有垃圾回收（GC），但 GC 只管内存，不管"连接、文件句柄、
  /// 流"这类外部资源 —— 必须手动关闭，否则泄漏。
  void dispose() {
    disconnect(); // 先断连接、取消订阅
    // 再关闭四条流管道，关闭后不可再 add，订阅者收到"结束"事件
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
