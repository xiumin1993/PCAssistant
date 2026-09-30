// ============================================================================
// connection_provider.dart —— 连接状态管理器（业务逻辑中枢）
// ----------------------------------------------------------------------------
// 它在架构中处于"中间层"，把底层服务和界面粘合起来：
//
//   NetworkService / AudioService  <--->  ConnectionProvider  <--->  HomeScreen
//        （干活的服务）                 （翻译 + 调度 + 状态）       （显示）
//
// 为什么需要这一层？
//   1. 服务层只懂"字节和连接"，不懂"界面要显示什么文字、按钮能不能点"；
//   2. 界面不应该直接调网络，否则逻辑散落各处难维护；
//   3. 把"连接成功后要开始推流"这类跨服务调度集中在这里。
//
// ChangeNotifier 是什么？（Flutter 状态管理入门关键）
//   它是 provider 库的核心基类：类继承它之后，就获得了一个
//   notifyListeners() 方法 —— 调用它，所有通过 Consumer/Provider
//   订阅了这个对象的 Widget 就会自动重建刷新界面。
//   这就是"数据变了，界面自动跟着变"的实现原理。
// ============================================================================

// dart:async：StreamSubscription，用来保存对流(Stream)的订阅句柄
import 'dart:async';

// flutter/material：这里主要为了用它的 TextEditingController
// （文本输入框控制器， manages 输入框里的文字）
import 'package:flutter/material.dart';

// shared_preferences：轻量本地存储插件（第三方依赖）。
// 数据存在手机 App 私有目录里，App 关闭重启后仍在。
// 本项目用它记住"上次输入的服务器地址"，省去每次重输。
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_service.dart';   // 音频服务
import '../services/network_service.dart';  // 网络服务（含 ConnectionStatus 枚举）

// v3.7 国际化：文案表类型。
// 注意这里 import 的是【生成出来的】类，不是 .arb 文件本身；
// 依赖方向仍然是"界面把 l10n 传进来"，本文件不主动读语言、不碰 BuildContext。
import '../l10n/app_localizations.dart';

/// 连接模式：WiFi 需要完整 IP:端口，USB 只需端口（IP 固定 127.0.0.1），
/// 蓝牙目前是占位（App↔PC 只有 WebSocket/TCP 一条通路，蓝牙不做实现）。
///
/// v3.6：枚举从 2 个值变 3 个 —— 注意 Dart 对枚举的 switch 要求"穷举"，
/// 所以凡是 switch(_connectionMode) 的地方都会立刻报编译错，
/// 这是保护网（防止加了新模式却忘了配文案），不是坑。
enum ConnectionMode { wifi, usb, bluetooth }

/// 连接状态管理
class ConnectionProvider extends ChangeNotifier {
  // --------------------------------------------------------------------------
  // 依赖的服务（通过构造函数注入进来，不是自己 new 的 —— 依赖注入）
  // 都是 final：注入后终身不换。
  // --------------------------------------------------------------------------
  final NetworkService _networkService;
  final AudioService _audioService;

  // --------------------------------------------------------------------------
  // 四个订阅句柄。
  // 规则：凡是 listen() 了就必须记住，并在 dispose() 时 cancel()，
  // 否则对象销毁后回调仍被触发 → 内存泄漏 / 操作已销毁对象报错。
  // --------------------------------------------------------------------------
  StreamSubscription? _statusSubscription; // 订阅"连接状态变化"
  StreamSubscription? _audioSubscription;  // 订阅"音频字节到达"
  StreamSubscription? _configSubscription; // 订阅"音频配置到达"
  StreamSubscription? _errorSubscription;  // 订阅"错误发生"

  // --------------------------------------------------------------------------
  // 界面需要的状态（私有字段 + 下方公开 getter 只读暴露）
  // --------------------------------------------------------------------------
  String _serverAddress = ''; // 服务器地址（持久化用的原始值）

  // 连接模式：WiFi 需要填完整 IP:端口，USB 只需填端口（IP 固定 127.0.0.1）
  // v3.6：这个字段的语义 = "首页当前选中的 Tab"，切换 Tab 只代表"在看哪种模式"，
  // 不会断开、也不会发起连接（用户明确要求：简单切 Tab 不引起状态变化）。
  ConnectionMode _connectionMode = ConnectionMode.wifi;

  // ── v3.6：每个模式各自的连接状态 ──────────────────────────────────
  // 为什么不用一个 _connectionStatus 就够？
  //   因为三个 Tab 要分别上色：WiFi 连着的时候切去看 USB 页，
  //   WiFi 那个 Tab 必须仍然是绿的（它确实还连着），
  //   而 USB Tab 该显示"未连接"。一份全局状态做不到这件事。
  // Map 的 key 是枚举、value 是状态；没连过的模式压根不在表里，
  // 读的时候用 statusOf() 兜底成 disconnected。
  final Map<ConnectionMode, ConnectionStatus> _modeStatus = {};

  // 当前这条连接是"由哪个模式发起"的。
  // 状态的到达是异步的（流回调里才知道 connected/error），
  // 所以要提前记下这次连接属于哪个 Tab，回调时才知道该给谁上色。
  ConnectionMode? _connectingMode;

  // 注意：这个字段和 NetworkService 里的枚举是同一个类型（import 过来的），
  // 两个类共享一份枚举定义，保证语义一致。
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;

  // v3.7 国际化：错误不再存"拼好的中文句子"，而是存【文案键】+【原始细节】。
  //   _errorKey    —— null 表示"当前没有错误"；非空是 'errEnterPort' 这类键名
  //   _errorDetail —— 原始异常文字（英文、带 errno），只用于排查，不参与翻译
  // 为什么要这样拆：Provider 活在没有 BuildContext 的地方，拿不到当前语言；
  // 只有界面（有 context）才能问 AppLocalizations 要那一句话。
  String? _errorKey;
  String? _errorDetail;
  bool _isLoading = false; // 是否正在连接中（控制按钮转圈动画）

  /// 文本框控制器：连接"输入框"这座桥。
  /// 它持有输入框的当前文字，可以：
  ///   读 —— controller.text（拿用户输入的地址）
  ///   写 —— controller.text = 'xxx'（回填历史地址）
  /// 由 Provider 持有而不是界面持有，界面销毁重建后输入内容也不会丢。
  final TextEditingController _serverAddressController = TextEditingController();

  /// USB 模式下的端口输入控制器，默认 8080。
  final TextEditingController _usbPortController = TextEditingController(text: '8080');

  /// 构造函数。
  /// required 关键字：调用时必须传这两个参数（见 main.dart 的注入代码）。
  ///
  /// 注意冒号后的初始化列表写法：
  ///   )  : _networkService = networkService,
  ///        _audioService = audioService {
  /// 这是在进入函数体"之前"给 final 字段赋值的唯一方式
  /// （final 字段一旦进入函数体就不能再改，所以必须在这里完成赋值）。
  ConnectionProvider({
    required NetworkService networkService,
    required AudioService audioService,
  })  : _networkService = networkService,
        _audioService = audioService {
    _init();          // 异步初始化（读本地存储），不阻塞构造
    _setupListeners(); // 挂上三个流监听，这是本类的核心
  }

  /// 异步初始化：从本地存储恢复上次输入的服务器地址。
  ///
  /// SharedPreferences.getInstance() 是异步的（要读磁盘），
  /// 返回 Future，用 await 等待结果。
  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    // getString 可能返回 null（从没存过），用 ?? 提供默认值 ''
    _serverAddress = prefs.getString('server_address') ?? '';
    // 回填到输入框，用户一打开 App 就看到上次的地址
    _serverAddressController.text = _serverAddress;

    // v3.6：恢复上次选中的连接模式 Tab。
    // indexWhere 找不到会返回 -1，所以判一下再用，防止越界崩溃。
    final savedMode = prefs.getString('connection_mode');
    if (savedMode != null) {
      final i = ConnectionMode.values.indexWhere((m) => m.name == savedMode);
      if (i >= 0) _connectionMode = ConnectionMode.values[i];
    }
    // USB 端口也恢复（默认 8080）
    final savedPort = prefs.getString('usb_port');
    if (savedPort != null && savedPort.isNotEmpty) {
      _usbPortController.text = savedPort;
    }

    // 状态变了 → 通知界面刷新（虽然是刚启动，界面还没建，
    // 多调用一次也无副作用）
    notifyListeners();
  }

  /// 建立"接线"：把两个服务的输出流接到本类的处理逻辑上。
  void _setupListeners() {
    // 【监听 1：连接状态变化】
    _statusSubscription = _networkService.connectionStatusStream.listen((status) {
      _connectionStatus = status;
      _isLoading = status == ConnectionStatus.connecting;

      // v3.6：把这次状态变化"记在发起它的那个模式头上"，
      // 首页三个 Tab 的颜色就是从这里读的（statusOf）。
      final owner = _connectingMode;
      if (owner != null) {
        if (status == ConnectionStatus.connected) {
          // 同一时刻只能有一条连接：给 owner 上绿色前，
          // 先把别的模式的状态清掉，避免出现"两个 Tab 同时绿"。
          _modeStatus.removeWhere((m, _) => m != owner);
          _modeStatus[owner] = ConnectionStatus.connected;
        } else if (status == ConnectionStatus.error) {
          _modeStatus[owner] = ConnectionStatus.error;
          _connectingMode = null; // 这次尝试结束了，失败态留在 Tab 上
        } else if (status == ConnectionStatus.disconnected) {
          _modeStatus.remove(owner);
          _connectingMode = null;
        }
      }

      if (status == ConnectionStatus.connected) {
        _audioService.startStreaming();
      } else if (status == ConnectionStatus.disconnected) {
        _audioService.stopStreaming();
      }

      notifyListeners();
    });

    // 【监听 2：音频数据到达】
    _audioSubscription = _networkService.audioDataStream.listen((data) {
      // 【性能优化】移除了每包日志。音频包每秒约 100 个，
      // 即使节流也不需要在生产环境打印。
      _audioService.receiveAudioData(data);
    });

    // 【监听 3：音频配置到达】
    _configSubscription = _networkService.audioConfigStream.listen((config) {
      _audioService.updateConfig(
        sampleRate: config.sampleRate,
        channelCount: config.channels,
      );
    });

    // 【监听 4：错误发生】
    // v3.7：网络层报来的是 NetErrorEvent（类别 + 原始异常），
    // 这里只把"类别"翻译成文案键、把原始异常留作细节，
    // 界面用 errorOf(l10n) 才拿到那句人话。
    _errorSubscription = _networkService.errorStream.listen((e) {
      _errorKey = e.kind == NetErrorKind.streamError ? 'netError' : 'netFailed';
      _errorDetail = e.detail;
      notifyListeners();
    });
  }

  // --------------------------------------------------------------------------
  // Getters（只读出口）
  // --------------------------------------------------------------------------
  // 字段是私有的，界面只能通过下面的 getter 读。
  // 好处：外部永远无法绕过 notifyListeners 直接改状态，
  // 保证"数据单向流动"，界面永远和逻辑一致。
  bool get isConnected => _connectionStatus == ConnectionStatus.connected;
  bool get isLoading => _isLoading;

  /// 当前错误的"人话版本"（v3.7 国际化）。
  ///
  /// 参数 l10n 由界面传进来：界面有 BuildContext，能取到当前语言的文案表，
  /// Provider 自己没有 —— 这就是"逻辑层不碰 UI，但要文案时由 UI 递进来"的
  /// 标准做法（比在 Provider 里存 GlobalContext 干净得多）。
  /// 返回 null = 现在没有错误，界面据此决定显不显示红色提示。
  String? errorOf(AppLocalizations l10n) {
    final key = _errorKey;
    if (key == null) return null;
    // switch 表达式（Dart 3 语法）：把文案键映射到 l10n 的具体句子。
    // default 分支返回 _errorDetail：万一某个键忘了映射，
    // 至少把原始异常显示出来，不会出现"界面上一片空白"这种更难查的情况。
    return switch (key) {
      'errEnterPort' => l10n.errEnterPort,
      'errEnterAddress' => l10n.errEnterAddress,
      'bluetoothHint' => l10n.bluetoothHint,
      'netError' => l10n.netError(_errorDetail ?? ''),
      'netFailed' => l10n.netFailed(_errorDetail ?? ''),
      _ => _errorDetail ?? key,
    };
  }

  TextEditingController get serverAddressController => _serverAddressController;
  TextEditingController get usbPortController => _usbPortController;
  ConnectionMode get connectionMode => _connectionMode;

  // ── v3.6：三 Tab 连接区的对外接口 ────────────────────────────────

  /// 某个模式的连接状态（首页 Tab 上色的唯一数据来源）。
  /// 表里没有这个模式 = 从没连过 = 未连接（Map 取不到时给兜底值）。
  ConnectionStatus statusOf(ConnectionMode mode) =>
      _modeStatus[mode] ?? ConnectionStatus.disconnected;

  /// 当前选中 Tab 的状态，界面拿它决定主按钮文案/是否可点。
  ConnectionStatus get currentModeStatus => statusOf(_connectionMode);

  /// 切换 Tab。
  /// 【重要】这里只改"在看哪个模式"，绝不断开、也绝不发起连接 ——
  /// 用户明确要求：简单切换 Tab 不会引起状态变化。
  /// 真正的动作只有一个：点当前 Tab 里的"连接"按钮。
  Future<void> setMode(ConnectionMode mode) async {
    if (_connectionMode == mode) return; // 没变就别白刷新一次
    _connectionMode = mode;
    // 记住选择，下次打开 App 还停在这个 Tab
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('connection_mode', mode.name);
    notifyListeners();
  }

  /// 主按钮的文案。三种情况：
  ///   已连接            → "断开连接"
  ///   正连着别的模式    → "连接（会先断开 WiFi）" —— 提前告诉用户代价
  ///   其余              → "连接" / "连接中…"
  ///
  /// v3.7：改成方法并收 l10n 参数（原来是 getter）。
  /// 名字保留 connectButtonTextOf 的 "Of" 后缀，是为了让"要传文案表"这件事
  /// 在调用点上一眼可见。
  String connectButtonTextOf(AppLocalizations l10n) {
    if (_isLoading) return l10n.btnConnecting;
    if (isConnected) {
      // 连着的就是当前 Tab → 断开；连着别的 Tab → 文案里点名要断开谁
      return _connectingMode == null || _connectingMode == _connectionMode
          ? l10n.btnDisconnect
          // btnConnectWithSwitch 是带占位符的句子："连接（会先断开{mode}）"，
          // 所以生成出来的是一个【方法】而不是字段，要这样传参调用。
          : l10n.btnConnectWithSwitch(modeLabel(l10n, _connectingMode!));
    }
    return l10n.btnConnect;
  }

  /// 模式名（按钮文案、状态副标题都用它）。
  /// WiFi / USB 是全球通用缩写，两种语言里都保持原样，只有"蓝牙"要翻。
  String modeLabel(AppLocalizations l10n, ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.wifi:
        return l10n.tabWifi; // 两种语言都写作 "WiFi"
      case ConnectionMode.usb:
        return l10n.tabUsb; // 两种语言都写作 "USB"
      case ConnectionMode.bluetooth:
        return l10n.tabBluetooth;
    }
  }

  // v3.7 国际化：原来这里有两个 static const 中文常量
  // （bluetoothHint / usbHint），界面和逻辑都直接引用它们。
  // 现在句子全部搬到 lib/l10n/app_*.arb 里，界面用 l10n.bluetoothHint /
  // l10n.usbHint 取 —— 逻辑层不再持有"某一种语言的句子"。
  //
  // USB 有线直连的原理说明（USB Tab 里那行小字）。
  // 原理：手机用 USB 线插到电脑上后，在电脑执行一条命令
  //   adb reverse tcp:8080 tcp:8080
  // 它把"手机自己的 8080 端口"通过 USB 线镜像回"电脑的 8080 端口"。
  // 于是手机连 127.0.0.1:8080 就等于连上了电脑上的 AudioServer，
  // 完全不走 WiFi —— 延迟更低、不受无线网络波动影响。
  // （对比 adb forward：forward 是"电脑连手机的端口"，方向相反，别搞混）

  /// 按当前 Tab 组装要连接的地址；返回 null 表示"信息不全，连不了"。
  /// WiFi 直接用输入框内容；USB 用 127.0.0.1 + 端口框拼出来。
  String? _addressForCurrentMode() {
    if (_connectionMode == ConnectionMode.usb) {
      final port = _usbPortController.text.trim();
      if (port.isEmpty) {
        _errorKey = 'errEnterPort';
        _errorDetail = null;
        return null;
      }
      return '127.0.0.1:$port';
    }
    final address = _serverAddressController.text.trim();
    if (address.isEmpty) {
      _errorKey = 'errEnterAddress';
      _errorDetail = null;
      return null;
    }
    return address;
  }

  /// 当前状态对应的"副标题文案"。
  ///
  /// v3.6：读的是 currentModeStatus（当前 Tab 自己的状态），
  /// 不是全局的 _connectionStatus —— 这样"WiFi 连着、人在 USB 页"时，
  /// 副标题说的是 USB 的情况，和 Tab 颜色保持一致，不会自相矛盾。
  ///
  /// switch 穷举：Dart 要求对枚举的 switch 必须覆盖所有值，
  /// 少写一个编译器直接报错 —— 将来加状态时忘了配文案会被立刻发现。
  ///
  /// v3.7：改成收 l10n 的方法（界面调用 `conn.connectionStatusOf(l10n)`）。
  String connectionStatusOf(AppLocalizations l10n) {
    switch (currentModeStatus) {
      case ConnectionStatus.disconnected:
        return l10n.statusTapToStart;
      case ConnectionStatus.connecting:
        return l10n.statusConnecting;
      case ConnectionStatus.connected:
        return l10n.statusReceiving;
      case ConnectionStatus.error:
        // v3.6：这里不再直接把原始异常文字铺上去。
        // 原始信息长这样："WebSocketChannelException: SocketException:
        // Connection timed out (OS Error: ..., errno = 110), address = ...,
        // port = 37590" —— 里面那个 port 是本机随机端口，不是服务器端口，
        // 摆在首页大字位置只会让人更困惑。
        // 所以这里给一句人话；原始异常仍在 errorOf() 里，界面上以小字
        // 附在按钮下方，需要排查时看得见，但不抢主视觉。
        return l10n.statusConnectFailed;
    }
  }

  /// 连接/断开切换 —— 首页那个大按钮唯一的入口。
  ///
  /// 界面只调用这一个方法，具体"该连还是该断"由这里判断，
  /// 按钮的图标/文字/状态展示保持同步，避免界面自己记状态记错。
  ///
  /// v3.6 的关键语义（用户明确要求）：
  ///   只有在【当前 Tab】里点连接，才会清除之前的"已连接/连接失败"状态，
  ///   并建立一条新连接。切 Tab 本身不触发这里。
  Future<void> toggleConnection() async {
    // 每次操作前清除上次错误提示（重新来过）
    _errorKey = null;
    _errorDetail = null;

    // 蓝牙这一格目前是占位，按了不给连（界面也会把按钮置灰，
    // 这里是双保险，防止别的入口绕过来）
    if (_connectionMode == ConnectionMode.bluetooth) {
      _errorKey = 'bluetoothHint';
      _errorDetail = null;
      notifyListeners();
      return;
    }

    if (_networkService.isConnected) {
      // 分支 A：已经连着 → 先断开。
      // 如果连着的是"别的 Tab"（比如 WiFi 连着、在 USB 页点了连接），
      // 这里断开后继续往下走，把新连接建立起来，一步到位；
      // 如果连的就是当前 Tab，那这次点击的意图就是"断开"，到此为止。
      final sameMode = _connectingMode == null || _connectingMode == _connectionMode;
      await _networkService.disconnect();
      if (sameMode) return;
    }

    // 分支 B：未连接 → 按当前 Tab 组装地址并连接
    final address = _addressForCurrentMode();
    if (address == null) {
      notifyListeners();
      return; // 卫语句：校验失败提前退出，不再往下
    }

    // 记住"这次连接属于哪个 Tab"，异步回来的 connected/error 才知道给谁上色
    _connectingMode = _connectionMode;
    // 清掉本 Tab 上一次的失败红标（用户要的就是"重新开始一次"）
    _modeStatus[_connectionMode] = ConnectionStatus.connecting;

    // 持久化：地址与 USB 端口都存下来，下次启动自动回填
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_address', address);
    await prefs.setString('usb_port', _usbPortController.text.trim());
    _serverAddress = address;

    // 发起连接。connect 内部会依次广播 connecting → connected/error，
    // 所有界面刷新都由监听 1 自动完成。
    await _networkService.connect(address);
  }

  /// 销毁清理。
  /// @override：告诉编译器和读代码的人"我在重写父类 ChangeNotifier 的
  /// dispose 方法"。重写时签名必须与父类一致。
  @override
  void dispose() {
    // 先取消全部订阅（否则流继续回调 → 操作已销毁的对象崩溃）
    _statusSubscription?.cancel();
    _audioSubscription?.cancel();
    _configSubscription?.cancel();
    _errorSubscription?.cancel();
    // 再释放文本控制器（它内部也持有监听资源）
    _serverAddressController.dispose();
    _usbPortController.dispose();
    // 最后调用父类的 dispose —— 固定套路，永远放在最末
    super.dispose();
  }
}
