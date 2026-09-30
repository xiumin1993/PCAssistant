// ============================================================================
// mic_provider.dart —— 手机麦克风状态管理器（v3.3 按需录音版）
// ----------------------------------------------------------------------------
// 它把三样东西粘在一起：
//
//   MicService（原生采集） <--->  MicProvider（调度+状态） <--->  界面
//                                      │
//                                      └-----> NetworkService（把 PCM 发给 PC）
//
// v3.3 核心行为（用户明确要求："电脑开始用我才录，电脑停我立马停"）：
//
//   连接成功 → 进入【待命 standby】：只挂前台服务 + 向服务器登记会话，
//              麦克风硬件是【关】的 —— 不录音、不耗电、无录音小绿点。
//   PC 应用打开麦克风（录 CABLE Output）→ 服务器 250ms 内检测到，
//              推 mic_state{active:true} → 手机【此刻才】打开 AudioRecord 上行。
//   PC 应用关闭麦克风 → 服务器推 mic_state{active:false} → 手机【立刻】停采集，
//              回到待命。
//
//   全程零点击。为什么现在敢用"唤醒"方案：早期 PKEY 占用检测在虚拟声卡上
//   永远不触发才被迫改成常开；现在服务器改用 WASAPI 音频会话枚举，已实测
//   可靠（开/关都能在 0.5 秒内感知），所以恢复"用时才开"的合理设计。
//
//   保留的人工控制：
//     · 静音键 —— 真关硬件（比"闭嘴"更彻底的隐私承诺）；解除静音时若
//       电脑正在用则自动恢复采集；
//     · 守护开关（首页）—— 彻底注销会话，连待命都不留。
//
//   状态机：
//     idle ──连接──> standby ──mic_state true──> live
//     live ──mic_state false──> standby ──断开/关守护──> idle
// ============================================================================

import 'dart:async';
import 'dart:convert'; // jsonEncode：把 Map 转成 JSON 字符串

import 'package:flutter/material.dart'; // ChangeNotifier 所在

import '../services/mic_service.dart';
import '../services/network_service.dart';

// v3.7 国际化：文案表类型（由界面把实例传进 errorOf / statusTextOf）
import '../l10n/app_localizations.dart';

/// 麦克风会话状态枚举（界面按它显示不同文字/按钮颜色）
enum MicState {
  idle,     // 未启用（未连接，或用户手动关闭守护）
  standby,  // 待命：会话已登记、前台服务在跑，但麦克风硬件【关闭】
  starting, // 正在打开麦克风（瞬时状态，通常 <0.3 秒）
  live,     // 录音上行中：电脑此刻正在使用麦克风，手机硬件已打开
}

/// 手机麦克风状态管理
class MicProvider extends ChangeNotifier {
  final NetworkService _networkService; // WebSocket 出口
  final MicService _micService = MicService(); // 原生采集

  StreamSubscription? _statusSubscription; // 连接状态订阅（自动待命的触发器）
  StreamSubscription? _ackSubscription;    // mic_ack 回执订阅

  MicState _state = MicState.idle;
  bool _sessionEstablished = false; // 服务器已确认登记（收到 mic_ack）
  bool _serverLive = false; // PC 是否有应用正在录 CABLE Output（服务器的权威判断）
  bool _muted = false;      // 手动静音键：按下后即使电脑在用也不开麦

  // ── v3.4.4 上行采样率选项 ──────────────────────────────────────
  // 48000（默认）= 与 PC 声卡混音速率一致，服务器逐样本直通（零风险）；
  // 44100 = 手机按 44.1k 录音上行，服务器注入引擎自动线性插值重采样到 48k。
  // 改档即时生效：正在录音会静默重启采集，待命中只更新登记信息。
  int _sampleRate = 48000;
  int get sampleRate => _sampleRate;

  /// 可选的采样率档位（AudioRecord 对两者都有硬性保证支持）
  static const List<int> sampleRateChoices = [48000, 44100];

  /// 切换上行采样率
  Future<void> setSampleRate(int sr) async {
    if (sr == _sampleRate) return;
    _sampleRate = sr;
    notifyListeners();
    if (_state == MicState.live) {
      // 正在上行：关硬件 → 用新速率重开（用户几乎无感，约 100ms 静音间隙）
      await _closeMic();
      if (_serverLive && !_muted) {
        await _openMic();
      }
    } else if (_state != MicState.idle && _sessionEstablished) {
      // 待命：重新登记一次，让服务器知道新速率
      _networkService.send(jsonEncode({
        'type': 'mic_start',
        'sample_rate': _sampleRate,
        'channels': 1,
        'format': 'pcm_s16le',
      }));
    }
  }
  bool _needsPermission = false; // 连接了但缺录音权限 → 首页显示"启用"按钮
  // v3.7 国际化：错误存【文案键】而不是中文句子（详见 connection_provider 同款注释）。
  String? _errorKey; // null = 当前无错误
  String? _errorDetail; // 原始细节（如原生错误码），不参与翻译

  // ── v3.6：本设备的功能总闸（"启用/禁用"块控制，值由 DeviceProvider 存本地）──
  // false = 用户明确禁用过手机麦克风：
  //   · 连上电脑不再自动进待命（不登记会话）；
  //   · 就算收到 mic_state:true 也不开硬件；
  //   · 关闭那一刻会主动注销已有会话（发 mic_stop），电脑那边随之再也唤不起。
  // 这是用户要的"唯一手动否决权"——麦克风页不再有静音键，禁用块就是那道闸。
  bool _enabled = true;

  double _level = 0; // 最新一帧响度（0.0~1.0）
  final List<double> _bars = []; // 电平滚动历史（界面画条形图用）
  int _lastNotifyMs = 0;  // 上次 notifyListeners 的时间戳（节流用）

  /// 构造函数：注入网络服务（和 ConnectionProvider 同款依赖注入套路）
  MicProvider({required NetworkService networkService})
      : _networkService = networkService {
    // 【接线 1：PCM 数据 → WebSocket】
    // 原生每采到一块就回调这里，直接塞进已连接的通道发给 PC。
    // 只有 live（电脑正在用、硬件已开）且没按静音才放行。
    _micService.onData = (bytes) {
      if (_state == MicState.live && !_muted) {
        _networkService.send(bytes); // send 内部有连接才发的保护
      }
    };

    // 【接线 2：响度 → 电平条数据】
    _micService.onLevel = (lv) {
      _level = _muted ? 0 : lv; // 静音时电平条也归零，视觉一致
      _bars.add(_level);
      if (_bars.length > 28) _bars.removeAt(0); // 只留最近 28 帧
      // 节流：音频帧每秒约 100 个，界面 100ms 刷一次（10fps）足够流畅
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNotifyMs >= 100) {
        _lastNotifyMs = now;
        notifyListeners();
      }
    };

    // 【接线 3：WebSocket 连上 → 自动进入待命（零操作的核心）】
    _statusSubscription = _networkService.connectionStatusStream.listen((s) {
      if (s == ConnectionStatus.connected) {
        _autoStandby();
      } else if (s == ConnectionStatus.disconnected) {
        // 断线：清掉一切（PC 端会话也随之消失）
        _sessionEstablished = false;
        _serverLive = false;
        _muted = false;
        if (_state != MicState.idle) {
          _micService.stop();          // 硬件若开着，关掉
          _micService.stopStandbyService();
          _state = MicState.idle;
          _bars.clear();
          notifyListeners();
        }
      }
    });

    // 【接线 4：PC 回执 → 确认会话登记完成】
    // mic_ack 若带 active=true（连上时电脑已经在用麦克风），
    // network_service 会把它当作一条 mic_state 推给接线 5，这里只管记账。
    _ackSubscription = _networkService.micAckStream.listen((_) {
      _sessionEstablished = true;
      notifyListeners();
    });

    // 【接线 5：PC 占用状态 → 驱动麦克风硬件开/关（v3.3 的核心开关）】
    _micStateListener();
  }

  /// 监听服务器推来的 mic_state：这是"电脑用/停"的权威信号，
  /// 直接决定手机麦克风硬件开还是关。
  void _micStateListener() {
    _networkService.micStateStream.listen((active) {
      if (_serverLive == active) return; // 状态没变，什么都不做
      _serverLive = active;

      if (active) {
        // 电脑开始用麦克风 → 若我在待命且没按静音，立刻开麦
        if (_state == MicState.standby && !_muted) {
          _openMic();
        } else {
          notifyListeners(); // 静音中/启动中：只刷新文案
        }
      } else {
        // 电脑停止使用 → 若硬件开着，立刻关闭回待命
        if (_state == MicState.live) {
          _closeMic();
        } else {
          notifyListeners();
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // Getters（界面只读出口）
  // --------------------------------------------------------------------------
  MicState get state => _state;
  bool get isLive => _state == MicState.live;
  bool get isStandby => _state == MicState.standby;
  bool get isBusy => _state == MicState.starting;
  bool get isMuted => _muted;           // 静音键是否按下
  bool get serverLive => _serverLive;   // 电脑是否有应用正在录 CABLE Output
  bool get needsPermission => _needsPermission; // 首页据此显示"启用麦克风"
  bool get hasSession => _sessionEstablished;

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
      'errMicPermission' => l10n.errMicPermission,
      'errMicDenied' => l10n.errMicDenied,
      'errMicBusy' => l10n.errMicBusy,
      'errMicUnsupported' => l10n.errMicUnsupported,
      'errMicStart' => l10n.errMicStart(_errorDetail ?? ''),
      _ => _errorDetail ?? key,
    };
  }

  double get level => _level;
  List<double> get bars => List.unmodifiable(_bars); // 只读快照，防界面乱改

  /// 状态对应的人话文案（详情页大字用）。
  ///
  /// v3.7 国际化：原来是硬编码中文的 getter，现在改成收 AppLocalizations 的
  /// 方法。命名上带 `Of` 后缀 = "要传文案表才能拿到句子"。
  /// （目前界面自己拼了大字，这两个方法是留给设备页统一改造时用的，
  ///   保留而不删除，是为了不丢掉这里已经写清楚的优先级判断。）
  String statusTextOf(AppLocalizations l10n) {
    // v3.6：禁用优先于一切状态 —— 功能闸关着时，别的话都不成立
    if (!_enabled) return l10n.micStatusDisabled;
    switch (_state) {
      case MicState.idle:
        return _needsPermission
            ? l10n.micStatusConnectedPerm
            : l10n.micStatusConnectedAuto;
      case MicState.standby:
        return _muted ? l10n.micStatusMuted : l10n.micStatusStandbyLong;
      case MicState.starting:
        return l10n.micStatusOpening;
      case MicState.live:
        return l10n.micStatusLive;
    }
  }

  /// 首页守护开关的副标题（一眼知道手机在干嘛）
  String guardianSubtitleOf(AppLocalizations l10n) {
    switch (_state) {
      case MicState.idle:
        return _needsPermission ? l10n.micBadgeWaitingPerm : l10n.micBadgeOff;
      case MicState.standby:
        return _muted ? l10n.micBadgeMuted : l10n.micBadgeStandby;
      case MicState.starting:
        return l10n.micBadgeStarting;
      case MicState.live:
        return l10n.micBadgeLive;
    }
  }

  // --------------------------------------------------------------------------
  // 自动待命：连接成功即触发，全程零点击
  // --------------------------------------------------------------------------

  /// 连接成功后的自动进入待命。
  /// 静默检查权限：没有权限不弹扰窗，只置 needsPermission，
  /// 由首页"启用麦克风"按钮让用户主动点一次（符合 Android 权限规范）。
  Future<void> _autoStandby() async {
    if (_state != MicState.idle) return; // 已在待命/工作中，幂等
    if (!_networkService.isConnected) return;
    if (!_enabled) return; // v3.6：设备被禁用 → 连上也不登记、不待命

    if (!await _micService.hasPermission()) {
      _needsPermission = true;
      notifyListeners();
      return;
    }
    _needsPermission = false;
    await enterStandby();
  }

  /// 进入待命：挂前台守护服务 + 向服务器登记会话。
  /// 注意：这里【不】打开麦克风硬件 —— 那是 mic_state 信号的事。
  Future<void> enterStandby() async {
    if (_state != MicState.idle) return;
    if (!_networkService.isConnected) {
      _setError('errConnectFirst');
      notifyListeners();
      return;
    }

    _state = MicState.starting; // 借"启动中"闪一下，表示正在登记
    _setError(null);
    _needsPermission = false;
    notifyListeners();

    // 守护前台服务：息屏后进程不被杀，服务器的唤醒指令才能随时送达
    await _micService.startStandbyService();

    // 登记会话：告诉 AudioServer "我上线了，需要我时推 mic_state 唤醒"
    _networkService.send(jsonEncode({
      'type': 'mic_start',
      'sample_rate': _sampleRate, // v3.4.4：跟随用户选择（默认 48000）
      'channels': 1,
      'format': 'pcm_s16le',
    }));

    _state = MicState.standby;
    // 若登记瞬间电脑已经在用（mic_ack 会带 active=true，随后由接线 5 处理），
    // 这里做一次兜底同步：_serverLive 已被置 true 就直接开麦
    if (_serverLive && !_muted) {
      await _openMic();
    } else {
      notifyListeners();
    }
  }

  /// 打开麦克风硬件并开始上行（只在电脑正在用 & 未静音时被调用）
  Future<void> _openMic() async {
    if (_state == MicState.live || _state == MicState.starting) return;
    if (!_enabled) return; // v3.6：双保险 —— 禁用状态下绝不开硬件
    _state = MicState.starting;
    notifyListeners();

    // 权限兜底（正常流程 _autoStandby 已确认；这里防系统撤销权限的极端情况）
    if (!await _micService.ensurePermission()) {
      _state = MicState.standby;
      _needsPermission = true;
      _setError('errMicPermission');
      notifyListeners();
      return;
    }

    // 开原生采集（采样率跟随用户选择，单声道；44.1k 时服务器自动重采样）
    final error = await _micService.start(
        sampleRate: _sampleRate, channels: 1);
    if (error != null) {
      _state = MicState.standby; // 开麦失败退回待命，等下一次唤醒再试
      _reportNativeError(error);
      notifyListeners();
      return;
    }

    _state = MicState.live;
    _setError(null);
    notifyListeners();
  }

  /// 关闭麦克风硬件，回到待命（电脑停用 / 用户按静音 都会走到这里）
  Future<void> _closeMic() async {
    await _micService.stop();
    _bars.clear();
    _level = 0;
    if (_state != MicState.idle) _state = MicState.standby;
    notifyListeners();
  }

  /// 手动静音键：通话软件式闭麦 ——
  /// v3.3 语义升级：按下 = 【真的关掉麦克风硬件】（隐私最彻底），
  /// 会话保持登记；再按一次：若电脑正在用则立刻重新开麦，否则安静待命。
  Future<void> toggleMute() async {
    _muted = !_muted;
    if (_networkService.isConnected && _sessionEstablished) {
      _networkService.send(jsonEncode({
        'type': 'mic_mute',
        'muted': _muted, // 服务器同步丢弃/恢复注入 + 清残留尾音
      }));
    }
    if (_muted) {
      _bars.clear();
      _level = 0;
      if (_state == MicState.live) {
        await _closeMic(); // 静音 = 硬件立即关闭
      } else {
        notifyListeners();
      }
    } else {
      // 解除静音：电脑正在用则马上恢复采集，否则等下一次 mic_state
      if (_state == MicState.standby && _serverLive) {
        await _openMic();
      } else {
        notifyListeners();
      }
    }
  }

  /// v3.6：功能总闸（音响/麦克风/摄像头三台设备共用同一套语义）。
  /// 关掉 = 立刻注销会话（电脑那边再也唤不起）；
  /// 打开 = 若已连着电脑，马上回到待命（硬件仍是关的，不录音）。
  /// 持久化不在这儿做 —— DeviceProvider 统一存本地存储，
  /// 它才是"三台设备开关"的唯一账本，这里只负责执行。
  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    if (!on) {
      await stop(); // 注销 + 关硬件 + 撤守护通知
    } else if (_networkService.isConnected) {
      await _autoStandby();
    }
    notifyListeners();
  }

  bool get enabled => _enabled;

  /// 首页主按钮 / 详情页大按钮统一入口：启用待命 or 彻底关闭
  Future<void> toggle() async {
    if (_state != MicState.idle) {
      await stop();
    } else {
      // 手动启用（含权限申请）：先拿权限，再进待命
      if (!_networkService.isConnected) {
        _setError('errConnectFirst');
        notifyListeners();
        return;
      }
      if (!await _micService.ensurePermission()) {
        _needsPermission = true;
        _setError('errMicPermission');
        notifyListeners();
        return;
      }
      _needsPermission = false;
      await enterStandby();
    }
  }

  /// 彻底关闭：注销会话 + 停采集 + 撤守护通知
  Future<void> stop() async {
    if (_networkService.isConnected && _sessionEstablished) {
      _networkService.send(jsonEncode({'type': 'mic_stop'}));
    }
    await _micService.stop();
    await _micService.stopStandbyService();
    _sessionEstablished = false;
    _serverLive = false;
    _muted = false;
    _state = MicState.idle;
    _bars.clear();
    _level = 0;
    notifyListeners();
  }

  /// 原生错误码 → 记录对应错误。
  ///
  /// v3.7 国际化：以前这里直接返回拼好的中文句子（"麦克风启动失败: $code"），
  /// 现在只登记【文案键】，原始错误码留在 _errorDetail 里给界面填进占位符。
  /// 这样同一段原生逻辑在中/英界面下都能给出正确的人话。
  void _reportNativeError(String code) {
    switch (code) {
      case 'PERMISSION_DENIED':
        _setError('errMicDenied');
      case 'INIT_FAILED':
        _setError('errMicBusy');
      case 'BAD_BUFFER':
        _setError('errMicUnsupported');
      default:
        _setError('errMicStart', code);
    }
  }

  /// 销毁清理：取消订阅 + 停采集 + 停服务（防泄漏的标准收尾）
  @override
  void dispose() {
    _statusSubscription?.cancel();
    _ackSubscription?.cancel();
    _micService.dispose();
    super.dispose();
  }
}
