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

/// 连接模式：WiFi 需要完整 IP:端口，USB 只需端口（IP 固定 127.0.0.1）
enum ConnectionMode { wifi, usb }

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
  ConnectionMode _connectionMode = ConnectionMode.wifi;

  // 注意：这个字段和 NetworkService 里的枚举是同一个类型（import 过来的），
  // 两个类共享一份枚举定义，保证语义一致。
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;

  String? _errorMessage; // 可空：null 表示"当前没有错误"，界面据此决定显不显示
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
    // 错误文字存入 _errorMessage，界面会显示红色提示。
    _errorSubscription = _networkService.errorStream.listen((error) {
      _errorMessage = error;
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
  String? get errorMessage => _errorMessage;
  TextEditingController get serverAddressController => _serverAddressController;
  TextEditingController get usbPortController => _usbPortController;
  ConnectionMode get connectionMode => _connectionMode;

  /// v3.4.5：USB 有线直连 —— 切换到 USB 模式，自动用 127.0.0.1 + 端口发起连接。
  ///
  /// 原理：手机用 USB 线插到电脑上后，在电脑执行一条命令
  ///   adb reverse tcp:8080 tcp:8080
  /// 它把"手机自己的 8080 端口"通过 USB 线镜像回"电脑的 8080 端口"。
  /// 于是手机连 127.0.0.1:8080 就等于连上了电脑上的 AudioServer，
  /// 完全不走 WiFi —— 延迟更低、不受无线网络波动影响，适合对
  /// 实时性要求最苛刻的场景。
  /// （对比 adb forward：forward 是"电脑连手机的端口"，方向相反，别搞混）
  ///
  /// 用户只需点一下这个按钮，自动填好端口并直接连接，无需再点"连接"。
  Future<void> connectUsb() async {
    _connectionMode = ConnectionMode.usb;
    notifyListeners();
    // 用 USB 端口拼接完整地址：127.0.0.1:{port}
    final port = _usbPortController.text.trim();
    if (port.isEmpty) {
      _errorMessage = '请输入端口号';
      notifyListeners();
      return;
    }
    final address = '127.0.0.1:$port';
    _serverAddressController.text = address;
    _serverAddress = address;
    notifyListeners();
    // 自动发起连接，省去用户再点一次"连接"按钮
    await toggleConnection();
  }

  /// WiFi 模式：恢复上次保存的服务器地址（不清空），切换回完整地址输入。
  /// 用户从 USB 切回 WiFi 时，不需要重新输入，上次填的 IP 还在。
  Future<void> restoreWifiAddress() async {
    _connectionMode = ConnectionMode.wifi;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('server_address') ?? '';
    // 如果上次保存的是 USB 回环地址，说明没有真正的 WiFi 历史，
    // 就留空让用户自己填；否则恢复历史地址
    if (saved.isNotEmpty && !saved.startsWith('127.0.0.1')) {
      _serverAddressController.text = saved;
      _serverAddress = saved;
    }
    notifyListeners();
  }

  /// 当前状态对应的"副标题文案"。
  ///
  /// switch 穷举：Dart 要求对枚举的 switch 必须覆盖所有值，
  /// 少写一个编译器直接报错 —— 将来加状态时忘了配文案会被立刻发现。
  String get connectionStatus {
    switch (_connectionStatus) {
      case ConnectionStatus.disconnected:
        return '点击连接按钮开始';
      case ConnectionStatus.connecting:
        return '正在连接...';
      case ConnectionStatus.connected:
        return '正在接收音频流';
      case ConnectionStatus.error:
        return _errorMessage ?? '连接错误'; // 有具体错误显示错误，没有则显示兜底文案
    }
  }

  /// 连接/断开切换 —— 页面上那个大按钮唯一的入口。
  ///
  /// 界面只调用这一个方法，具体"该连还是该断"由这里判断，
  /// 按钮的图标/文字/状态展示保持同步，避免界面自己记状态记错。
  Future<void> toggleConnection() async {
    // 每次操作前清除上次错误提示（重新来过）
    _errorMessage = null;

    if (_networkService.isConnected) {
      // 分支 A：已连接 → 执行断开
      await _networkService.disconnect();
      // 断开后 NetworkService 会广播 disconnected 状态，
      // 监听 1 自动接手后续（停音频、刷界面），这里不用重复做
    } else {
      // 分支 B：未连接 → 执行连接
      // .text 取输入框内容；.trim() 去掉首尾空格，
      // 用户手滑多打的空格不至于导致连接失败
      final address = _serverAddressController.text.trim();
      if (address.isEmpty) {
        _errorMessage = '请输入服务器地址';
        notifyListeners();
        return; // 卫语句：校验失败提前退出，不再往下
      }

      // 持久化：把地址写入本地存储，下次启动自动回填
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_address', address);
      _serverAddress = address;

      // 发起连接。connect 内部会依次广播 connecting → connected/error，
      // 所有界面刷新都由监听 1 自动完成。
      await _networkService.connect(address);
    }
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
