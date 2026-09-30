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

// v3.7 国际化：文案表类型（由界面把实例传进 errorOf / statusTextOf 等）
import '../l10n/app_localizations.dart';

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
  // v3.7 国际化：错误存【文案键】+ 原始细节，不再存中文句子
  String? _errorKey;
  String? _errorDetail;

  // ── v3.6：本设备的功能总闸（页顶"启用/禁用"块控制，值由 DeviceProvider 存本地）──
  // false = 用户禁用了手机摄像头：不登记会话、收到 cam_state/cam_request 也不开硬件，
  // 关闭那一刻会主动注销（发 cam_stop）。它就是用户要的"唯一手动否决权"。
  bool _enabled = true;

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
        if (_guardWanted && _state == CamState.idle && _enabled) {
          _enterStandbyInternal();
        }
        // v3.4.13：连上就把"这台手机能跑什么画质"探出来缓存。
        // 探测走 CameraCharacteristics，【不需要打开相机硬件】，
        // 所以待命之前、甚至禁用状态下都能探 —— 画质下拉框因此随时可用。
        ensureCaps();
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
      if (!_enabled) return; // v3.6：设备已禁用 → 连横幅都不弹，闸门说了算
      if (_state != CamState.idle) return; // 已在守护中，无需再确认
      _requestPending = true;
      _setError(null);
      notifyListeners();
    });

    // 【接线 6：PC 强制关闭 → 无条件注销（隐私总闸，不给拒绝的机会）】
    _forceStopSubscription =
        _networkService.camForceStopStream.listen((_) {
      if (_state == CamState.idle && !_guardWanted) return;
      _guardWanted = false;
      _requestPending = false;
      stop(silent: true);
      _setError('camForceStopped');
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
  /// 记录/清除一条错误。只存文案键（+ 可选细节），句子由界面翻译。
  void _setError(String? key, [String? detail]) {
    _errorKey = key;
    _errorDetail = detail;
  }

  /// 当前错误的人话版本（v3.7 国际化）；null = 没有错误。
  String? errorOf(AppLocalizations l10n) {
    final key = _errorKey;
    if (key == null) return null;
    return switch (key) {
      'errConnectFirst' => l10n.errConnectFirst,
      'errCamPermission' => l10n.errCamPermission,
      'camForceStopped' => l10n.camForceStopped,
      'errCamDenied' => l10n.errCamDenied,
      'errCamNoLens' => l10n.errCamNoLens,
      'errCamTimeout' => l10n.errCamTimeout,
      'errCamBusy' => l10n.errCamBusy,
      'errCamStart' => l10n.errCamStart(_errorDetail ?? ''),
      _ => _errorDetail ?? key,
    };
  }

  String get facing => _facing;
  Uint8List? get previewJpeg => _previewJpeg;
  int get selWidth => _selWidth;
  int get selHeight => _selHeight;
  int get selFps => _selFps;

  /// 当前镜头的文案（切换按钮、预览角标用）
  String facingTextOf(AppLocalizations l10n) =>
      _facing == 'back' ? l10n.facingBack : l10n.facingFront;

  /// 切换按钮的文案（v2 设计稿：不给前置/后置两个按钮，
  /// 只给一个"切换"按钮，文字指向另一颗镜头）
  String switchButtonTextOf(AppLocalizations l10n) =>
      _facing == 'back' ? l10n.switchToFront : l10n.switchToBack;

  /// 选定画质文案，如 "1280×720 @ 30fps"
  /// —— 纯数字与单位，全球通用，不进文案表。
  String get qualityText => '$_selWidth×$_selHeight @ ${_selFps}fps';

  /// v3.4.1：当前手动旋转角度（0/90/180/270）
  int get manualRotation => _manualRotation;

  /// v3.4.1：点一次"旋转90°"→ 原生偏移 +90（循环），下一帧立即生效。
  /// 相机没开时也可以按：数字存在原生引擎里，开相机后自动套用。
  Future<void> rotateManual90() async {
    _manualRotation = await _cameraService.rotateManual();
    notifyListeners();
  }

  /// 状态对应的人话文案（详情页大字）
  String statusTextOf(AppLocalizations l10n) {
    // v3.6：禁用优先于一切状态
    if (!_enabled) return l10n.camStatusDisabled;
    switch (_state) {
      case CamState.idle:
        if (_needsPermission) return l10n.camStatusConnectedPerm;
        return l10n.camStatusStandbyAuto;
      case CamState.standby:
        return _muted ? l10n.camStatusFrozen : l10n.camStatusStandbyLong;
      case CamState.starting:
        return l10n.camStatusOpening;
      case CamState.live:
        return l10n.camStatusLive;
    }
  }

  /// 首页守护开关的副标题
  String guardianSubtitleOf(AppLocalizations l10n) {
    switch (_state) {
      case CamState.idle:
        return _needsPermission ? l10n.camBadgeWaitingPerm : l10n.camBadgeOff;
      case CamState.standby:
        return _muted ? l10n.camBadgeFrozen : l10n.camBadgeStandby;
      case CamState.starting:
        return l10n.camBadgeOpening;
      case CamState.live:
        return l10n.camBadgeLive;
    }
  }

  // --------------------------------------------------------------------------
  // 启用路径（两个入口汇到同一个 _enterStandbyInternal）
  // --------------------------------------------------------------------------

  /// v3.6：功能总闸（与 MicProvider.setEnabled 同一套语义）。
  /// 关掉 = 注销会话 + 关相机 + 撤守护（电脑那边再也唤不起）；
  /// 打开 = 若已连着电脑，直接回到待命（硬件仍关着，不取景）。
  /// 值的持久化统一由 DeviceProvider 负责，这里只执行动作。
  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    if (!on) {
      _guardWanted = false; // 禁用是更强的意图，重连后也不要自动恢复
      await stop();
    } else if (_networkService.isConnected) {
      _guardWanted = true; // 重新启用 = 用户要这个功能了
      await _enterStandbyInternal();
    }
    notifyListeners();
  }

  bool get enabled => _enabled;

  /// 首页守护开关 / 详情页大按钮统一入口：启用 or 彻底关闭
  Future<void> toggle() async {
    if (_state != CamState.idle) {
      _guardWanted = false; // 用户主动关 → 断线重连也不再自动恢复
      await stop();
      return;
    }
    if (!_networkService.isConnected) {
      _setError('errConnectFirst');
      notifyListeners();
      return;
    }
    if (!await _cameraService.ensurePermission()) {
      _needsPermission = true;
      _setError('errCamPermission');
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
      _setError('errConnectFirst');
      notifyListeners();
      return;
    }
    if (!await _cameraService.ensurePermission()) {
      _needsPermission = true;
      _setError('errCamPermission');
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

  /// v3.4.13：能力探测（幂等 + 缓存）。
  ///
  /// 为什么单独拎出来：探测每颗镜头"支持哪些分辨率、最高多少帧"用的是
  /// CameraCharacteristics，这是一份静态说明书，【不需要也不打开相机硬件】。
  /// 之前它被塞进"进待命"的流程里，导致一个不合理的使用体验：
  /// 手机还只是待命，用户就想把清晰度调低一点省流量，结果下拉框压根不出现。
  /// 现在一连上就探一次，界面随时能拿到档位表。
  ///
  /// _capsReady 用来区分"还没探完"和"探完了但没有档位"，
  /// 界面据此显示"探测中…"而不是干脆藏掉整行。
  bool _capsReady = false;
  bool get capsReady => _capsReady;

  Future<void> ensureCaps() async {
    if (_capsReady) return; // 探过了，直接用缓存
    _capsReady = true; // 先置位：并发调用只探一次
    try {
      _caps = await _cameraService.getCapabilities();
      _pickBestProfile(); // 按当前镜头挑最高档
      notifyListeners(); // 档位表到了 → 下拉框该刷新
    } catch (_) {
      _capsReady = false; // 探失败留个机会下次再探（不致命：有保守默认档）
    }
  }

  /// 进入待命：能力探测 → 挂守护通知 → 向服务器报能力 + 登记会话。
  /// 注意这里【不】打开相机硬件 —— 那是 cam_state 信号的事。
  Future<void> _enterStandbyInternal() async {
    if (_state != CamState.idle) return; // 幂等
    if (!_networkService.isConnected) return;
    if (!_enabled) return; // v3.6：设备被禁用 → 任何唤醒路径都进不了待命

    _state = CamState.starting; // 借"启动中"闪一下，表示正在登记
    _setError(null);
    _needsPermission = false;
    notifyListeners();

    // 第一步：确保能力清单已探出（连上时通常已经探过，这里幂等兜底）。
    // 探测失败不致命：用保守默认 640×480@30 继续。
    await ensureCaps();

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
        _reportNativeError(error);
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

  /// 打开相机硬件并开始上行（只在 PC 正在观看 & 未冻结 & 未被禁用时被调用）
  Future<void> _openCamera() async {
    if (_state == CamState.live || _state == CamState.starting) return;
    if (!_enabled) return; // v3.6：双保险 —— 禁用状态下绝不开硬件
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
      _reportNativeError(error);
      notifyListeners();
      return;
    }
    _state = CamState.live;
    _setError(null);
    notifyListeners();
  }

  /// 关闭相机硬件回待命（PC 停用 / 用户按冻结 都走到这里）
  Future<void> _closeCamera() async {
    await _cameraService.stop();
    _previewJpeg = null;
    if (_state != CamState.idle) _state = CamState.standby;
    notifyListeners();
  }

  /// 切换前/后置镜头。
  ///
  /// v3.4.13 起【任何状态都能切】（用户："任何时候都可以修改摄像头清晰度"，
  /// 镜头是同一回事）：
  ///   · 取景中(live)：真的让原生 stop→start 换镜头，并套用新镜头的档位；
  ///   · 待命/未登记：只把"默认镜头"这个偏好翻过来 + 重挑档位 + 重发登记，
  ///     完全不碰相机硬件（硬件本来就是关着的，没东西可切）。
  Future<void> switchLens() async {
    if (_state != CamState.live) {
      // 非取景态：只改意图，等下一次开相机自然生效
      _facing = _facing == 'back' ? 'front' : 'back';
      await ensureCaps(); // 档位表可能还没探到（未连接时也能预设）
      _pickBestProfile(); // 前后置能力不同，重挑该镜头的最佳档
      await _applyProfileChange(); // 待命→重发 cam_start；idle→只记账
      return;
    }
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
        _reportNativeError(error);
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

  /// 原生错误码 → 记录对应错误（v3.7：只存文案键，句子交给界面翻译）
  void _reportNativeError(String code) {
    switch (code) {
      case 'PERMISSION_DENIED':
        _setError('errCamDenied');
      case 'NO_CAMERA':
        _setError('errCamNoLens');
      case 'OPEN_TIMEOUT':
        _setError('errCamTimeout');
      case 'SESSION_FAILED':
        _setError('errCamBusy');
      default:
        _setError('errCamStart', code);
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
