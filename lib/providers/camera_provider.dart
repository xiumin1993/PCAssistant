// ============================================================================
// camera_provider.dart —— 手机摄像头状态管理器（v3.4 按需取景版）
// ----------------------------------------------------------------------------
// 它把三样东西粘在一起（与 mic_provider.dart 同构，可对照阅读）：
//
//   CameraService（原生采集） <--->  CameraProvider（调度+状态） <--->  界面
//                                      │
//                                      └-----> NetworkService（JPEG 帧发给 PC）
//
// v3.4 核心行为（镜像 v3.3 麦克风的"按需"哲学 + 摄像头特有的双入口）：
//
//   【双入口启用】摄像头比麦克风更敏感，不做"连上就自动待命"：
//     入口 A —— 手机上主动打开"摄像头守护"（本文件 toggle）；
//     入口 B —— PC 端 GUI 点"请求手机开启摄像头"→ 服务器推 cam_request →
//               手机出现确认横幅，用户点"同意"才登记会话（acceptRequest）。
//     无论哪个入口，都需要用户一次明确点头 —— 这是隐私底线。
//
//   【按需开硬件】登记后进入【待命 standby】：相机硬件是【关】的
//     （无绿点、不耗电）。PC 上的应用真的打开 Unity Video Capture
//     虚拟摄像头 → 服务器检测到 → 推 cam_state{active:true}
//     → 手机【此刻才】开 Camera2 取景上行；应用关掉 → 立即关硬件回待命。
//
//   【一键关死】两端各有一把"总闸"：
//     · 手机：守护开关关闭 / 大按钮停止 → 注销会话；
//     · PC：GUI"强制关闭"按钮 → 推 cam_stop{forced} → 手机无条件注销。
//     · 静音键（通话式）：会话保留但相机硬件立即关闭、画面冻结。
//
//   状态机：
//     idle ──用户启用/同意请求──> standby ──cam_state true──> live
//     live ──cam_state false──> standby ──断开/停止/强制关闭──> idle
// ============================================================================

import 'dart:async';
import 'dart:convert'; // jsonEncode / jsonDecode
import 'dart:typed_data'; // Uint8List / BytesBuilder：拼帧头用

import 'package:flutter/material.dart'; // ChangeNotifier 所在

import '../services/camera_service.dart';
import '../services/network_service.dart';

/// 摄像头会话状态枚举（界面按它显示不同文字/颜色/按钮可用性）
enum CamState {
  idle,     // 未启用（没登记会话，守护开关关着）
  standby,  // 待命：会话已登记、守护通知在跑，但相机硬件【关】
  starting, // 正在打开相机（瞬时状态）
  live,     // 取景中：PC 应用此刻正在观看，相机硬件已打开
}

/// 手机摄像头状态管理
class CameraProvider extends ChangeNotifier {
  final NetworkService _networkService; // WebSocket 出口
  final CameraService _cameraService = CameraService(); // 原生采集

  StreamSubscription? _statusSubscription;   // 连接状态（断线清理/重连恢复）
  StreamSubscription? _ackSubscription;      // cam_ack 回执
  StreamSubscription? _requestSubscription;  // cam_request PC 请求启用
  StreamSubscription? _forceStopSubscription; // cam_stop{forced} PC 强制关闭

  CamState _state = CamState.idle;
  bool _sessionEstablished = false; // 服务器已确认登记（收到 cam_ack）
  bool _serverLive = false;   // PC 是否有应用正在观看虚拟摄像头
  bool _muted = false;        // 手动静音（冻结画面）键
  bool _needsPermission = false; // 想启用但缺相机权限
  bool _guardWanted = false;  // 用户意图：想要摄像头守护（断线重连后自动恢复登记）
  bool _requestPending = false; // 收到 cam_request，等用户点"同意/忽略"
  String? _errorMessage;

  // ── 镜头与画质 ──
  String _facing = 'back'; // 设计决定：默认后置镜头
  List<CamLensCaps> _caps = const []; // 能力探测结果（发给 PC + 本地选档）
  int _selWidth = 640;      // 当前选定的画质档
  int _selHeight = 480;
  int _selFps = 30;

  // ── v3.4.1：手动旋转偏移（0/90/180/270，顺时针，单位：度）──
  // 真正的数字存在原生 CameraEngine 里（每帧压缩时套用）；
  // 这里只是镜像一份给界面显示按钮文案用。
  // 断线重连/切镜头都不会被清零（原生 stop 不重置它）。
  int _manualRotation = 0;

  // ── 预览 ──
  Uint8List? _previewJpeg;  // 最新一帧 JPEG（界面 Image.memory 直接显示）
  int _lastNotifyMs = 0;    // 预览刷新节流时间戳（10fps 够用）

  /// 上行帧魔术头：4 字节 [0x03,'C','A','M']，服务器据此把 JPEG 帧
  /// 与麦克风 PCM 分流（PCM 撞这 4 字节的概率约 2^-32，可忽略）。
  static const List<int> _frameMagic = [0x03, 0x43, 0x41, 0x4D];

  CameraProvider({required NetworkService networkService})
      : _networkService = networkService {
    // 【接线 1：JPEG 帧 → 加魔术头发 WebSocket + 刷本地预览】
    _cameraService.onFrame = (jpeg) {
      if (_state == CamState.live && !_muted) {
        // BytesBuilder：字节"黏合剂"，先塞 4 字节头再塞 JPEG 本体。
        // 比 new Uint8List(4+len) 手工拷贝整洁，内部只分配一次。
        final packet = BytesBuilder(copy: false)
          ..add(_frameMagic)
          ..add(jpeg);
        _networkService.send(packet.toBytes()); // send 内有连接保护
        _previewJpeg = jpeg; // 留一份给界面画预览
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastNotifyMs >= 100) {
          // 节流：相机每秒最多 30 帧，界面 10fps 刷新足够顺滑
          _lastNotifyMs = now;
          notifyListeners();
        }
      }
    };

    // 【接线 2：连接状态变化】
    _statusSubscription = _networkService.connectionStatusStream.listen((s) {
      if (s == ConnectionStatus.connected) {
        // 与麦克风不同：摄像头连上【不】自动登记（双入口设计）。
        // 但若用户之前开着守护（_guardWanted），重连后自动恢复登记。
        if (_guardWanted && _state == CamState.idle) {
          _enterStandbyInternal();
        }
      } else if (s == ConnectionStatus.disconnected) {
        // 断线：硬件与本地状态全部清零，但保留 _guardWanted 意图，
        // 下次连上自动恢复待命（体验连续，不用重新点开关）。
        _sessionEstablished = false;
        _serverLive = false;
        _muted = false;
        _requestPending = false;
        if (_state != CamState.idle) {
          _cameraService.stop();
          _cameraService.stopGuardService();
          _state = CamState.idle;
          _previewJpeg = null;
          notifyListeners();
        }
      }
    });

    // 【接线 3：PC 回执 → 记账会话登记完成】
    _ackSubscription = _networkService.camAckStream.listen((_) {
      _sessionEstablished = true;
      notifyListeners();
    });

    // 【接线 4：PC 观看状态 → 驱动相机硬件开/关（按需取景核心）】
    _networkService.camStateStream.listen((active) {
      if (_serverLive == active) return; // 状态没变，什么都不做
      _serverLive = active;
      if (active) {
        // PC 应用开始观看 → 待命中且没冻结，才开相机硬件
        if (_state == CamState.standby && !_muted) {
          _openCamera();
        } else {
          notifyListeners();
        }
      } else {
        // PC 应用关闭摄像头 → 硬件立即关掉，回待命（绿点熄灭）
        if (_state == CamState.live) {
          _closeCamera();
        } else {
          notifyListeners();
        }
      }
    });

    // 【接线 5：PC 请求启用 → 亮出确认横幅，等用户点"同意"】
    _requestSubscription = _networkService.camRequestStream.listen((_) {
      if (!_networkService.isConnected) return;
      if (_state != CamState.idle) return; // 已在守护中，无需再确认
      _requestPending = true;
      _errorMessage = null;
      notifyListeners();
    });

    // 【接线 6：PC 强制关闭 → 无条件注销（隐私总闸，不给拒绝的机会）】
    _forceStopSubscription =
        _networkService.camForceStopStream.listen((_) {
      if (_state == CamState.idle && !_guardWanted) return;
      _guardWanted = false;
      _requestPending = false;
      stop(silent: true);
      _errorMessage = '电脑端已强制关闭摄像头';
      notifyListeners();
    });
  }

  // --------------------------------------------------------------------------
  // Getters（界面只读出口）
  // --------------------------------------------------------------------------
  CamState get state => _state;
  bool get isLive => _state == CamState.live;
  bool get isStandby => _state == CamState.standby;
  bool get isBusy => _state == CamState.starting;
  bool get isMuted => _muted;
  bool get serverLive => _serverLive;
  bool get needsPermission => _needsPermission;
  bool get hasSession => _sessionEstablished;
  bool get requestPending => _requestPending;
  bool get guardWanted => _guardWanted;
  String? get errorMessage => _errorMessage;
  String get facing => _facing;
  Uint8List? get previewJpeg => _previewJpeg;
  int get selWidth => _selWidth;
  int get selHeight => _selHeight;
  int get selFps => _selFps;

  /// 当前镜头的中文文案（切换按钮用）
  String get facingText => _facing == 'back' ? '后置' : '前置';

  /// 切换按钮的文案（v2 设计稿：不给前置/后置两个按钮，
  /// 只给一个"切换"按钮，文字指向另一颗镜头）
  String get switchButtonText =>
      _facing == 'back' ? '切换前置' : '切换后置';

  /// 选定画质文案，如 "1280×720 @ 30fps"
  String get qualityText => '$_selWidth×$_selHeight @ ${_selFps}fps';

  /// v3.4.1：当前手动旋转角度（0/90/180/270）
  int get manualRotation => _manualRotation;

  /// v3.4.1：点一次"旋转90°"→ 原生偏移 +90（循环），下一帧立即生效。
  /// 相机没开时也可以按：数字存在原生引擎里，开相机后自动套用。
  Future<void> rotateManual90() async {
    _manualRotation = await _cameraService.rotateManual();
    notifyListeners();
  }

  /// 状态对应的中文文案（详情页大字）
  String get statusText {
    switch (_state) {
      case CamState.idle:
        if (_needsPermission) {
          return '已连接电脑，点下方按钮授权相机后即可使用';
        }
        return '打开守护开关，或在电脑上请求后确认，即可当电脑摄像头';
      case CamState.standby:
        return _muted
            ? '已冻结 —— 电脑观看时也不会开相机'
            : '待命中 —— 相机已关闭，电脑打开观看时自动取景';
      case CamState.starting:
        return '电脑正在观看，正在开启相机...';
      case CamState.live:
        return '取景中 —— 电脑此刻正在使用你的摄像头';
    }
  }

  /// 首页守护开关的副标题
  String get guardianSubtitle {
    switch (_state) {
      case CamState.idle:
        return _needsPermission ? '等待授权相机' : '未启用';
      case CamState.standby:
        return _muted ? '已冻结 · 等待解除' : '待命中 · 相机硬件已关闭';
      case CamState.starting:
        return '正在开启…';
      case CamState.live:
        return '取景中 · 电脑此刻正在观看';
    }
  }

  // --------------------------------------------------------------------------
  // 启用路径（两个入口汇到同一个 _enterStandbyInternal）
  // --------------------------------------------------------------------------

  /// 首页守护开关 / 详情页大按钮统一入口：启用 or 彻底关闭
  Future<void> toggle() async {
    if (_state != CamState.idle) {
      _guardWanted = false; // 用户主动关 → 断线重连也不再自动恢复
      await stop();
      return;
    }
    if (!_networkService.isConnected) {
      _errorMessage = '请先在首页连接电脑';
      notifyListeners();
      return;
    }
    if (!await _cameraService.ensurePermission()) {
      _needsPermission = true;
      _errorMessage = '需要相机权限才能当电脑摄像头';
      notifyListeners();
      return;
    }
    _needsPermission = false;
    _guardWanted = true; // 记住用户意图（供断线重连恢复）
    await _enterStandbyInternal();
  }

  /// PC 请求横幅上的"同意"按钮
  Future<void> acceptRequest() async {
    _requestPending = false;
    if (!_networkService.isConnected) {
      _errorMessage = '请先在首页连接电脑';
      notifyListeners();
      return;
    }
    if (!await _cameraService.ensurePermission()) {
      _needsPermission = true;
      _errorMessage = '需要相机权限才能当电脑摄像头';
      notifyListeners();
      return;
    }
    _needsPermission = false;
    _guardWanted = true;
    await _enterStandbyInternal();
  }

  /// PC 请求横幅上的"忽略"按钮（不注销、不报错，静默收起）
  void declineRequest() {
    _requestPending = false;
    notifyListeners();
  }

  /// 进入待命：能力探测 → 挂守护通知 → 向服务器报能力 + 登记会话。
  /// 注意这里【不】打开相机硬件 —— 那是 cam_state 信号的事。
  Future<void> _enterStandbyInternal() async {
    if (_state != CamState.idle) return; // 幂等
    if (!_networkService.isConnected) return;

    _state = CamState.starting; // 借"启动中"闪一下，表示正在登记
    _errorMessage = null;
    _needsPermission = false;
    notifyListeners();

    // 第一步：能力探测（不开相机，纯查询"这台手机最高能跑什么画质"）
    try {
      _caps = await _cameraService.getCapabilities();
      _pickBestProfile(); // 按当前镜头挑最高档
    } catch (_) {
      // 探测失败不致命：用保守默认 640×480@30 继续
    }

    // 第二步：守护前台服务（息屏不被杀，PC 唤醒指令才能送达）
    await _cameraService.startGuardService();

    // 第三步：把能力清单报给 PC（GUI 显示"手机最高支持什么画质"）
    _networkService.send(jsonEncode({
      'type': 'cam_capabilities',
      'cams': _caps.map((c) => c.toMap()).toList(),
    }));

    // 第四步：登记会话（语义同 mic_start —— 我上线了，需要我时推 cam_state）
    _networkService.send(jsonEncode({
      'type': 'cam_start',
      'facing': _facing,
      'width': _selWidth,
      'height': _selHeight,
      'fps': _selFps,
    }));

    _state = CamState.standby;
    // 重置服务器活跃标记：确保新一轮 cam_state:true 不被去重跳过
    // （断线重连场景：_serverLive 可能还是上次的 true，不重置会卡死在待命）
    _serverLive = false;
    notifyListeners();
  }

  /// 从能力清单里给当前镜头挑"最高档"：
  /// 面积最大的一档；帧率取 min(该档最高帧率, 30) —— 网络场景 30fps 封顶。
  /// v3.4.4：手动模式下如果手动档在新镜头上也受支持，就保持手动档不动。
  void _pickBestProfile() {
    if (!_autoProfile && _manualProfileSupportedHere()) return;
    CamLensCaps? lens;
    for (final c in _caps) {
      if (c.facing == _facing) lens = c;
    }
    if (lens == null || lens.sizes.isEmpty) return; // 保持默认 640×480
    final best = lens.sizes.first; // 原生已按面积从大到小排好
    _selWidth = best.width;
    _selHeight = best.height;
    _selFps = best.maxFps.clamp(1, 30);
    _autoProfile = true; // 手动档在当前镜头上不存在 → 回退自动
  }

  // ── v3.4.4 手动画质档 ──────────────────────────────────────────
  // true  = 自动挑选（能力探测后取最高档，原有行为）
  // false = 用户在界面上手动指定的档位
  bool _autoProfile = true;

  /// 当前镜头支持的全部分辨率档位（给界面下拉框用）
  List<CamSizeCaps> get lensSizes {
    for (final c in _caps) {
      if (c.facing == _facing) return c.sizes;
    }
    return const []; // 还没探测到能力时返回空列表，界面据此禁用选择器
  }

  /// 是否处于"自动挑档"模式
  bool get autoProfile => _autoProfile;

  /// 手动档（宽×高）在当前镜头的能力清单里是否存在。
  /// 用途：前后置镜头能力不同，切镜头时手动档可能要"作废"回自动。
  bool _manualProfileSupportedHere() {
    for (final c in _caps) {
      if (c.facing != _facing) continue;
      for (final s in c.sizes) {
        if (s.width == _selWidth && s.height == _selHeight) return true;
      }
    }
    return false;
  }

  /// 用户手动选择某一档：帧率自动取该档上限（封顶 30fps）
  Future<void> selectProfile(CamSizeCaps size) async {
    if (_selWidth == size.width && _selHeight == size.height && !_autoProfile) {
      return; // 没变化，不折腾相机
    }
    _autoProfile = false;
    _selWidth = size.width;
    _selHeight = size.height;
    _selFps = size.maxFps.clamp(1, 30);
    await _applyProfileChange();
  }

  /// 恢复"自动挑最高档"模式
  Future<void> setAutoProfile() async {
    if (_autoProfile) return;
    _autoProfile = true;
    _pickBestProfile();
    await _applyProfileChange();
  }

  /// 画质档变化后的统一善后：
  /// live 状态 → 重启相机硬件套用新档；standby → 重发 cam_start 更新登记；
  /// idle → 什么都不用做（下次进待命会用新档）。
  Future<void> _applyProfileChange() async {
    notifyListeners();
    if (_state == CamState.live) {
      await _cameraService.stop();
      final error = await _cameraService.start(
        facing: _facing,
        width: _selWidth,
        height: _selHeight,
        fps: _selFps,
      );
      if (error != null) {
        _errorMessage = _errorText(error);
        _state = CamState.standby; // 起不来就退回待命，不算致命
      }
    } else if (_state != CamState.idle) {
      _networkService.send(jsonEncode({
        'type': 'cam_start',
        'facing': _facing,
        'width': _selWidth,
        'height': _selHeight,
        'fps': _selFps,
      }));
    }
    notifyListeners();
  }

  /// 打开相机硬件并开始上行（只在 PC 正在观看 & 未冻结时被调用）
  Future<void> _openCamera() async {
    if (_state == CamState.live || _state == CamState.starting) return;
    _state = CamState.starting;
    notifyListeners();

    final error = await _cameraService.start(
      facing: _facing,
      width: _selWidth,
      height: _selHeight,
      fps: _selFps,
    );
    if (error != null) {
      _state = CamState.standby; // 开相机失败退回待命，等下一次唤醒
      _errorMessage = _errorText(error);
      notifyListeners();
      return;
    }
    _state = CamState.live;
    _errorMessage = null;
    notifyListeners();
  }

  /// 关闭相机硬件回待命（PC 停用 / 用户按冻结 都走到这里）
  Future<void> _closeCamera() async {
    await _cameraService.stop();
    _previewJpeg = null;
    if (_state != CamState.idle) _state = CamState.standby;
    notifyListeners();
  }

  /// 切换前/后置镜头（v2 设计稿：单按钮，相机开着时才能按）。
  /// 原生内部 stop→start 沿用当前画质档；切完更新按钮文案。
  Future<void> switchLens() async {
    if (_state != CamState.live) return; // 未取景时按钮是灰的，这里双保险
    final newFacing = await _cameraService.switchLens();
    if (newFacing != _facing) {
      _facing = newFacing;
      _pickBestProfile(); // 前后置能力可能不同，重挑档位
      // 档位变了但相机已开着：重启一次以套用新镜头的最佳画质
      await _cameraService.stop();
      final error = await _cameraService.start(
        facing: _facing,
        width: _selWidth,
        height: _selHeight,
        fps: _selFps,
      );
      if (error != null) {
        _errorMessage = _errorText(error);
        _state = CamState.standby;
      }
      notifyListeners();
    }
  }

  /// 冻结键（通话软件式闭麦的摄像头版）：
  /// 按下 = 真关相机硬件（绿点灭），会话保留，PC 端画面停在最后一帧；
  /// 再按 = 若电脑正在看则立刻重开相机，否则安静待命。
  Future<void> toggleMute() async {
    _muted = !_muted;
    if (_muted) {
      _previewJpeg = null;
      if (_state == CamState.live) {
        await _closeCamera(); // 冻结 = 硬件立即关闭
      } else {
        notifyListeners();
      }
    } else {
      if (_state == CamState.standby && _serverLive) {
        await _openCamera();
      } else {
        notifyListeners();
      }
    }
  }

  /// 彻底关闭：注销会话 + 关相机 + 撤守护通知
  /// @param silent true = 不主动给服务器发 cam_stop
  ///               （PC 强制关闭场景：那边已经关了，不用再回执）
  Future<void> stop({bool silent = false}) async {
    // v3.4.12：注销 = 用户不再要这个守护了，【意图】也要一起清掉。
    // 之前只有 toggle() 关闭分支会清 _guardWanted，而首页"摄像头守护"开关
    // 关闭走的是 stop()（见 home_screen.dart）→ 意图位残留 true，
    // 于是断线重连后 App 会自作主张把相机会话重新登记回去，
    // 电脑一开虚拟摄像头手机就悄悄开机 —— 违背用户刚刚亲手关掉的事实。
    // 隐私类状态必须"关了就真关了"，所以在这里统一清（幂等，多处调用无害）。
    _guardWanted = false;
    if (!silent && _networkService.isConnected && _sessionEstablished) {
      _networkService.send(jsonEncode({'type': 'cam_stop'}));
    }
    await _cameraService.stop();
    await _cameraService.stopGuardService();
    _sessionEstablished = false;
    _serverLive = false;
    _muted = false;
    _requestPending = false;
    _state = CamState.idle;
    _previewJpeg = null;
    notifyListeners();
  }

  /// 原生错误码 → 中文提示（界面显示用）
  String _errorText(String code) {
    switch (code) {
      case 'PERMISSION_DENIED':
        return '相机权限被拒绝，请在系统设置中允许';
      case 'NO_CAMERA':
        return '手机没有对应镜头';
      case 'OPEN_TIMEOUT':
        return '相机打开超时，请关闭其他相机应用重试';
      case 'SESSION_FAILED':
        return '相机被其他应用占用，关闭后重试';
      default:
        return '相机启动失败: $code';
    }
  }

  /// 销毁清理：取消订阅 + 关相机 + 撤服务（防泄漏的标准收尾）
  @override
  void dispose() {
    _statusSubscription?.cancel();
    _ackSubscription?.cancel();
    _requestSubscription?.cancel();
    _forceStopSubscription?.cancel();
    _cameraService.dispose();
    super.dispose();
  }
}
