// ============================================================================
// device_provider.dart —— 三台设备（音响 / 麦克风 / 摄像头）的总闸与状态账本
// ----------------------------------------------------------------------------
// v3.6 改版新增的一层。它【不重复实现】任何采集/播放逻辑，只做两件事：
//
//   1. 记账：每台设备"用户启没启用"（存本地，重启 App 还认）；
//   2. 翻译：把三个底层 Provider 的技术状态（idle/standby/live）
//      翻译成界面要的那句人话 —— 已禁用 / 未连接 / 待命 / 使用中，
//      首页三张入口卡、页面顶栏徽标、页首的启用/禁用块，全都读这里，
//      保证同一个设备在任何位置显示的状态词严格一致。
//
// 为什么要有这一层，而不是让界面各自判断？
//   因为"状态词"要出现在 4 个地方（首页卡、页面顶栏、页首闸门、说明文案），
//   每处都写一遍 switch 就一定会写歪（历史上已经歪过一次）。
//   集中一处翻译，界面只管拿字符串和颜色上色。
//
// 依赖方向（很重要，别搞反）：
//   DeviceProvider ──读──> MicProvider / CameraProvider / AudioService
//   DeviceProvider ──写──> 上面三者的 setEnabled()（把闸门执行下去）
//   底层 Provider 【不】反向依赖本文件 —— 它们只认自己的 _enabled 布尔。
// ============================================================================
// ── 文件说明书（速览，初学者可先背这一段）──────────────────────────────
// 【管什么】三台设备（音响/麦克风/摄像头）各自的"用户启没启用"布尔账本，
//   外加把底层技术状态翻译成界面上五档统一状态词（DeviceUiStatus）。
// 【谁调用它】首页三张入口卡与授权横幅（lib/screens/home_screen.dart 里的
//   Consumer<DeviceProvider>）、三个设备详情页顶栏徽标和页首禁用开关。
//   界面全部走"只读方法"（statusOf/statusLabelOf/isEnabled…），没有例外。
// 【它调用谁】读：ConnectionProvider.isConnected、MicProvider/CameraProvider
//   的 isLive/isStandby、AudioService.isPlaying；写：三者的 setEnabled()
//   和 AudioService.setMuted()。注册顺序见 lib/main.dart（必须排在被读者之后）。
// 【状态怎么流转】用户拨禁用开关 → setEnabled() 记内存+存 SharedPreferences
//   → 转发底层执行 → 底层 notifyListeners → 本类 _onSourceChanged 跟着
//   notifyListeners → 界面重建、重新读 statusOf() 上色。
// 【产品原则·唯一否决权】全 App 只有设备详情页顶部那个"大字写明当前是
//   禁用还是启用"的总闸能关掉一台设备；页面里旧的"启用/停止"按钮、
//   麦克风页的静音键都已删除——两处开关必然有一处骗人，只留一处才可信。
//   唯一例外是音响的"临时静音"：只关本机出声、不动会话，性质是播放参数。
// ============================================================================

import 'package:flutter/material.dart'; // ChangeNotifier / Color / IconData
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_service.dart';
import '../l10n/app_localizations.dart'; // v3.7：状态词的翻译表（由界面传进来）
import 'camera_provider.dart';
import 'connection_provider.dart';
import 'mic_provider.dart';

/// 三台设备的枚举。用 enum 而不是字符串：
/// 写错设备名（'camra'）编译期就报错，字符串只能等运行时崩。
enum PcDevice { speaker, mic, camera }

/// 界面的五档状态（比底层 Provider 的枚举少而稳）：
///   disabled      已禁用   —— 用户拨了总闸，功能整体关闭
///   offline       未连接   —— 没连着电脑，谈不上用不用
///   pendingConsent 待电脑请求 —— 连着电脑，但这台设备需要电脑先发请求、
///                              手机确认后才登记会话（只有摄像头走这一档）
///   standby       待命     —— 会话已登记，硬件关着（不耗电、无绿点）
///   active        使用中   —— 电脑此刻真的在用它
// 五档各自"对用户说的话"（对应 statusLabelOf 的文案，一处对一句）：
//   disabled       → "我被你关了，去详情页拨回来"（红）
//   offline        → "还没连上电脑，谈不上用不用"（灰）
//   pendingConsent → "链路是通的，只差一次人工确认（电脑请求/录音授权）"（琥珀）
//   standby        → "随时可用，但硬件此刻关着，不耗电不打扰你"（绿）
//   active         → "电脑这一刻真的在用它，注意隐私"（蓝）
enum DeviceUiStatus {
  disabled,
  offline,
  pendingConsent,
  standby,
  active,
}

/// 三设备总闸 + 状态账本
class DeviceProvider extends ChangeNotifier {
  // 注入进来的四个依赖（都是 final：构造时给一次，终身不换）
  final ConnectionProvider _connection;
  final MicProvider _mic;
  final CameraProvider _camera;
  final AudioService _audio;

  // 每台设备的启用状态。默认全 true —— 用户的设计是"默认都是待命状态"，
  // 禁用是要用户明确去拨的闸，不是出厂默认。
  // 为什么 isEnabled() 的 `?? true` 和这里的初始 true 是同一语义的两道保险：
  // "没有明确记录 = 启用"。默认若是 false，新用户装上后要翻三个页面各点一次
  // 启用才能用，产品第一步就劝退；⚠ 注意：真要把默认改成 false，
  // 下面 _load() 里 `?? true` 的兜底和已存盘的旧键都要一起想清楚，
  // 否则两处默认打架，禁用/启用会表现得心口不一。
  final Map<PcDevice, bool> _enabled = {
    PcDevice.speaker: true,
    PcDevice.mic: true,
    PcDevice.camera: true,
  };

  // 音响的临时静音（会话保留，只是不出声）。
  // 注意它和"禁用"是两码事，界面上也分开放：静音在参数区，禁用在大闸门。
  bool _speakerMuted = false;

  // 订阅三个 Provider 的变化：它们一有动静本类就跟着 notifyListeners，
  // 界面才能"电脑开始用了 → 首页卡片自己变绿"。
  // 用的是 ChangeNotifier 自带的 addListener（不是 Stream，所以不需要
  // StreamSubscription，但 dispose 里必须成对 removeListener）。
  // ⚠ 注意：_audio（AudioService）没有挂监听——它是普通 Provider、
  // 不继承 ChangeNotifier，播/停变化不会叫醒本类。音响从"使用中"变回
  // "待命"时，徽标要等其他监听源（连接/麦克风/摄像头）顺带触发刷新才会变。
  // 若将来发现音响状态显示迟钝，先想到这里，但修它要动 main.dart 的分层，
  // 不要在本文件里私自补救。

  DeviceProvider({
    required ConnectionProvider connection,
    required MicProvider mic,
    required CameraProvider camera,
    required AudioService audio,
  })  : _connection = connection,
        _mic = mic,
        _camera = camera,
        _audio = audio {
    _load(); // 异步读本地存储恢复上次的启用状态，不阻塞构造

    // ChangeNotifier 没有 Stream，但它的 addListener 就是"变化了就叫我"。
    // 三个来源都挂同一个回调 _onSourceChanged（下面 cancel 时要成对移除）。
    _connection.addListener(_onSourceChanged);
    _mic.addListener(_onSourceChanged);
    _camera.addListener(_onSourceChanged);
  }

  /// 三个底层任何一个变了，本类就要通知界面（状态词可能变了）。
  void _onSourceChanged() => notifyListeners();

  // --------------------------------------------------------------------------
  // 持久化：启用/禁用要活得过 App 重启
  // --------------------------------------------------------------------------
  // 为什么必须持久化：如果只记在内存里，用户杀一次 App 再打开，
  // 被他明确禁用的麦克风又悄悄回到待命态 —— 等于他的否决被系统遗忘了。

  /// 本地存储的键名前缀。集中一个常量，将来改键名只改一处。
  // 实际键名 = 前缀 + 枚举名，例如 device_enabled_speaker / device_enabled_mic。
  // 拼 d.name 而不是手写字符串，枚举改名时键名自动跟着变；
  // 老键读不到会走 ?? true 默认启用，不会崩，只是用户得重拨一次闸。
  static const String _prefsPrefix = 'device_enabled_';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final d in PcDevice.values) {
      // getBool 取不到返回 null（从没存过）→ ?? true 兜底成"默认启用"
      final saved = prefs.getBool('$_prefsPrefix${d.name}');
      if (saved != null) _enabled[d] = saved;
    }
    // 把恢复出来的开关"执行"到底层（否则只是本类记了个数，没起作用）
    await _applyAll();
    notifyListeners();
  }

  /// 把 _enabled 表里的三台设备状态同步给各自的执行者。
  Future<void> _applyAll() async {
    await _audio.setEnabled(_enabled[PcDevice.speaker]!);
    await _mic.setEnabled(_enabled[PcDevice.mic]!);
    await _camera.setEnabled(_enabled[PcDevice.camera]!);
  }

  /// 拨动某台设备的总闸。
  /// 顺序：先记本地 → 再执行动作。反过来会有个窗口期：
  /// 动作触发了一连串回调，回调里读到"还没更新"的开关，界面闪一下错误状态。
  // "为什么禁用时连上电脑也不登记会话"的保险丝不住在本类：setEnabled(false)
  // 只是把布尔拨下去，真正的拦截在底层 —— MicProvider / CameraProvider 收到
  // connected 事件时先查自己的 _enabled，false 就直接跳过登记（见
  // lib/providers/mic_provider.dart 与 camera_provider.dart 里的 _enabled 注释）。
  // 所以"闸门说了算"是全链路行为：禁用 → 不登记 → 收不到唤醒 → 硬件永不打开。
  Future<void> setEnabled(PcDevice device, bool on) async {
    if (_enabled[device] == on) return;
    _enabled[device] = on;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefsPrefix${device.name}', on);

    // 分派给对应的执行者（三个 Provider/AudioService 都有同名的 setEnabled，
    // 语义也一致：关=注销、开=回待命），这里用 switch 显式写三行，
    // 比"塞进一个 List 遍历"更好读，将来某台设备要加特殊处理也不用改结构。
    switch (device) {
      case PcDevice.speaker:
        await _audio.setEnabled(on);
      case PcDevice.mic:
        await _mic.setEnabled(on);
      case PcDevice.camera:
        await _camera.setEnabled(on);
    }
    notifyListeners();
  }

  /// 音响临时静音（只影响本机播放，不影响会话与电脑侧）
  // 再强调一遍边界：静音 ≠ 否决权。它只是"这台音箱暂时不出声"的播放参数，
  // 会话照常保留、电脑还以为声音在放；真正的关设备只有上面的禁用总闸。
  // 这也是"麦克风页的静音键被删、音响静音却被留下"的原因：
  // 麦克风静音会给人"电脑收不到我声音"的错觉（其实上行仍在跑），
  // 涉及隐私的开关必须用一个说清楚状态的禁用闸门，不能用静音键。
  Future<void> setSpeakerMuted(bool on) async {
    _speakerMuted = on;
    await _audio.setMuted(on);
    notifyListeners();
  }

  bool get speakerMuted => _speakerMuted;

  // --------------------------------------------------------------------------
  // 只读出口：界面拿这些去上色、配文案
  // --------------------------------------------------------------------------

  // 只读出口：Map 取不到键会返回 null（可空类型 ? 的又一次体现），
  // `?? true` 把"没记录"兜底成"启用"——与构造时的初始值同一默认哲学。
  bool isEnabled(PcDevice device) => _enabled[device] ?? true;

  /// 某台设备此刻该显示成五档中的哪一档。
  /// 判断顺序就是优先级：禁用 > 未连接 > 使用中 > 待命 > 待电脑请求。
  // 为什么"禁用"必须排在"未连接"前面？—— 设备被禁用又恰好没连电脑时，
  // 用户该看到的提醒是"你自己把它关了（拨回来就能用）"，而不是笼统的
  // "未连接"把人支去查网线。顺序换过来，闸门就等于在说谎。
  DeviceUiStatus statusOf(PcDevice device) {
    if (!isEnabled(device)) return DeviceUiStatus.disabled;
    if (!_connection.isConnected) return DeviceUiStatus.offline;

    switch (device) {
      case PcDevice.speaker:
        // 音响"使用中"= 原生 AudioTrack 正在播（且没被本机静音）
        return (_audio.isPlaying && !_speakerMuted)
            ? DeviceUiStatus.active
            : DeviceUiStatus.standby;
      case PcDevice.mic:
        if (_mic.isLive) return DeviceUiStatus.active;
        if (_mic.isStandby) return DeviceUiStatus.standby;
        // 连着电脑却还没进待命，只可能是"还没授权录音"（缺权限时不自动弹窗）。
        // 这时说"未连接"是假话（链路明明是通的），单列一档。
        return DeviceUiStatus.pendingConsent;
      case PcDevice.camera:
        // 摄像头比麦克风多一档：出于隐私，它【不】在连上时自动登记会话，
        // 必须电脑那边点"请求手机摄像头"、手机弹横幅确认后才进待命。
        // 所以"连着电脑但没会话"是一种正常状态，不能谎称待命，
        // 也不能显示成未连接（那会让人以为链路断了）。
        if (_camera.isLive) return DeviceUiStatus.active;
        if (_camera.isStandby) return DeviceUiStatus.standby;
        return DeviceUiStatus.pendingConsent;
    }
  }

  // --------------------------------------------------------------------------
  // 文案出口（v3.7 国际化）
  // --------------------------------------------------------------------------
  // 下面这一批方法原来返回硬编码中文，现在统一改成"收 AppLocalizations 参数"。
  // 为什么在本类里做映射、而不是让界面直接 switch？
  //   因为同一句状态词要出现在 4 个地方（首页卡、页面顶栏、页首闸门、说明文案），
  //   集中一处翻译才不会再写歪 —— 这个类的职责没变，只是"词典"换成了多语的。
  // 命名约定：所有需要文案表的方法都以 `Of(l10n)` 结尾，一眼看出要传什么。

  /// 状态词（首页卡片徽标、页面顶栏徽标共用）。
  String statusLabelOf(AppLocalizations l10n, PcDevice device) {
    switch (statusOf(device)) {
      case DeviceUiStatus.disabled:
        return l10n.statusDisabled;
      case DeviceUiStatus.offline:
        return l10n.statusOffline;
      case DeviceUiStatus.pendingConsent:
        // 这一档对两台设备含义不同：摄像头是"等电脑发请求"，
        // 麦克风是"等用户在手机上授权录音"。文案分开说才不误导。
        return device == PcDevice.camera
            ? l10n.statusPendingCam
            : l10n.statusPendingMic;
      case DeviceUiStatus.standby:
        return l10n.statusStandby;
      case DeviceUiStatus.active:
        // 三台设备"使用中"各自的人话不一样，照着实物说：
        // 音响在放声音、麦克风在录、摄像头在取景。
        switch (device) {
          case PcDevice.speaker:
            return l10n.statusPlayingNow;
          case PcDevice.mic:
            return l10n.statusRecordingNow;
          case PcDevice.camera:
            return l10n.statusFilmingNow;
        }
    }
  }

  /// 页首大闸门上的那行大字：把"启用状态"和"工作状态"拼成一句，
  /// 用户不用去猜滑块颜色是什么意思（这是本轮最关键的辨识度要求）。
  String gateHeadlineOf(AppLocalizations l10n, PcDevice device) {
    switch (statusOf(device)) {
      case DeviceUiStatus.disabled:
        return l10n.gateDisabled;
      case DeviceUiStatus.offline:
        return l10n.gateEnabledOffline;
      case DeviceUiStatus.pendingConsent:
        return device == PcDevice.camera
            ? l10n.gateEnabledPendingCam
            : l10n.gateEnabledPendingMic;
      case DeviceUiStatus.standby:
        return l10n.gateEnabledStandby;
      case DeviceUiStatus.active:
        return l10n.gateEnabledActive;
    }
  }

  /// 大闸门下面那句"后果说明"。
  String gateSubtextOf(AppLocalizations l10n, PcDevice device) {
    switch (statusOf(device)) {
      case DeviceUiStatus.disabled:
        return l10n.gateSubDisabled;
      case DeviceUiStatus.offline:
        return l10n.gateSubOffline;
      case DeviceUiStatus.pendingConsent:
        return device == PcDevice.camera
            ? l10n.gateSubPendingCam
            : l10n.gateSubPendingMic;
      case DeviceUiStatus.standby:
        return _standbyLine(l10n, device);
      case DeviceUiStatus.active:
        return _activeLine(l10n, device);
    }
  }

  String _standbyLine(AppLocalizations l10n, PcDevice device) {
    switch (device) {
      case PcDevice.speaker:
        return l10n.standbySpeaker;
      case PcDevice.mic:
        return l10n.standbyMic;
      case PcDevice.camera:
        return l10n.standbyCamera;
    }
  }

  String _activeLine(AppLocalizations l10n, PcDevice device) {
    switch (device) {
      case PcDevice.speaker:
        return l10n.activeSpeaker;
      case PcDevice.mic:
        return l10n.activeMic;
      case PcDevice.camera:
        return l10n.activeCamera;
    }
  }

  /// 状态对应的颜色（徽标底色、卡片描边都读它，一处定义全局一致）。
  // Color(0xFFxxxxxx) 是 32 位 ARGB 整数：前两位 FF = 不透明度（255=全实），
  // 后六位是 RRGGBB 色值。改后六位 = 换颜色；把 FF 改成别的数 = 半透明，
  // 徽标会透出背景变脏——新手最容易误改的就是这两位。
  Color statusColor(PcDevice device) {
    switch (statusOf(device)) {
      case DeviceUiStatus.disabled:
        return const Color(0xFFC62828); // 红：功能被关掉
      case DeviceUiStatus.offline:
        return const Color(0xFF9E9E9E); // 灰：还没连
      case DeviceUiStatus.pendingConsent:
        return const Color(0xFFB26A00); // 琥珀：连着，但等一次人工确认
      case DeviceUiStatus.standby:
        return const Color(0xFF0F8A43); // 绿：已就绪待命
      case DeviceUiStatus.active:
        return const Color(0xFF1565C0); // 蓝：正在使用（比绿更"热"一档）
    }
  }

  /// 设备名（首页卡片标题、页面顶栏都会用到）。
  /// 名字也要翻：英文界面里 "Speaker / Microphone / Camera" 才自然。
  String nameOf(AppLocalizations l10n, PcDevice device) {
    switch (device) {
      case PcDevice.speaker:
        return l10n.devSpeaker;
      case PcDevice.mic:
        return l10n.devMic;
      case PcDevice.camera:
        return l10n.devCamera;
    }
  }

  /// 设备图标（Material 内置图标常量，不用引外部图片）
  IconData iconOf(PcDevice device) {
    switch (device) {
      case PcDevice.speaker:
        return Icons.speaker;
      case PcDevice.mic:
        return Icons.mic;
      case PcDevice.camera:
        return Icons.videocam;
    }
  }

  /// 卡片下面那行小字：一句话说清"现在这台设备在干嘛"。
  String detailLineOf(AppLocalizations l10n, PcDevice device) {
    switch (statusOf(device)) {
      case DeviceUiStatus.disabled:
        return l10n.detailDisabled;
      case DeviceUiStatus.offline:
        return l10n.detailOffline;
      case DeviceUiStatus.pendingConsent:
        return device == PcDevice.camera
            ? l10n.detailPendingCam
            : l10n.detailPendingMic;
      case DeviceUiStatus.standby:
        return l10n.detailStandby;
      case DeviceUiStatus.active:
        switch (device) {
          case PcDevice.speaker:
            return l10n.detailActiveSpeaker;
          case PcDevice.mic:
            return l10n.detailActiveMic;
          case PcDevice.camera:
            return l10n.detailActiveCamera;
        }
    }
  }

  /// 销毁：移除监听（addListener 必须成对 removeListener，否则内存泄漏）
  @override
  void dispose() {
    _connection.removeListener(_onSourceChanged);
    _mic.removeListener(_onSourceChanged);
    _camera.removeListener(_onSourceChanged);
    super.dispose();
  }
}
