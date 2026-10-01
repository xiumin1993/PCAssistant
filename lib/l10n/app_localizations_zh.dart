// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'PC Assistant';

  @override
  String get heroConnected => '已连接';

  @override
  String get heroConnecting => '连接中';

  @override
  String get heroConnectFailed => '连接失败';

  @override
  String get heroNotConnected => '未连接';

  @override
  String get tabWifi => 'WiFi';

  @override
  String get tabUsb => 'USB';

  @override
  String get tabBluetooth => '蓝牙';

  @override
  String get serverAddressLabel => '电脑服务器地址';

  @override
  String get serverAddressHint => '例如: 192.168.1.100:8080';

  @override
  String get wifiSameNetworkHint => '手机与电脑需连同一个 WiFi；地址在电脑端 AudioServer 界面可查。';

  @override
  String get portLabel => '端口';

  @override
  String get usbHint => '需 USB 线插好，并在电脑执行：adb reverse tcp:8080 tcp:8080';

  @override
  String get usbIphoneHint => 'iPhone 暂无 USB 直连通道，请使用 WiFi 连接：填电脑的局域网 IP。';

  @override
  String get bluetoothHint =>
      '蓝牙通道暂未开放：经典蓝牙带宽约 1 Mbps，只够传音频、带不动画面。当前所有功能统一走 WiFi 局域网或 USB 有线直连。';

  @override
  String get btnConnect => '连接';

  @override
  String get btnDisconnect => '断开连接';

  @override
  String btnConnectWithSwitch(String mode) {
    return '连接（会先断开$mode）';
  }

  @override
  String get btnConnecting => '连接中...';

  @override
  String get statusTapToStart => '点击连接按钮开始';

  @override
  String get statusConnecting => '正在连接...';

  @override
  String get statusReceiving => '正在接收音频流';

  @override
  String get statusConnectFailed => '连接失败，请确认电脑端服务器已启动、地址与端口正确';

  @override
  String get errEnterAddress => '请输入服务器地址';

  @override
  String get errEnterPort => '请输入端口号';

  @override
  String get devSpeaker => '音响';

  @override
  String get devMic => '麦克风';

  @override
  String get devCamera => '摄像头';

  @override
  String get statusDisabled => '已禁用';

  @override
  String get statusOffline => '未连接';

  @override
  String get statusPendingCam => '待电脑请求';

  @override
  String get statusPendingMic => '待授权';

  @override
  String get statusStandby => '待命';

  @override
  String get statusPlayingNow => '正在播放';

  @override
  String get statusRecordingNow => '录音中';

  @override
  String get statusFilmingNow => '取景中';

  @override
  String get gateDisabled => '已禁用';

  @override
  String get gateEnabledOffline => '已启用 · 未连接';

  @override
  String get gateEnabledPendingCam => '已启用 · 等待电脑请求';

  @override
  String get gateEnabledPendingMic => '已启用 · 等待授权录音';

  @override
  String get gateEnabledStandby => '已启用 · 待命';

  @override
  String get gateEnabledActive => '已启用 · 使用中';

  @override
  String get gateSubDisabled => '本设备功能已关闭：会话注销、硬件不开启，电脑那边再怎么调用也唤不起它。';

  @override
  String get gateSubOffline => '功能已启用，但还没连上电脑。连上后自动进入待命。';

  @override
  String get gateSubPendingCam =>
      '相机硬件是关着的。电脑端点「请求手机开启摄像头」后，手机会弹确认横幅，同意才登记会话进入待命 —— 这一步是摄像头的隐私闸门，刻意保留。';

  @override
  String get gateSubPendingMic =>
      '手机还没有录音权限，因此麦克风没有进入待命。进入麦克风页点「授权」，系统弹窗允许一次后即可长期使用。';

  @override
  String get standbySpeaker => '会话已就绪，电脑还没在推声音。拨到「禁用」= 立刻停止接收音频流。';

  @override
  String get standbyMic => '会话已登记，麦克风硬件关闭（无绿点、不耗电）。拨到「禁用」= 立刻注销。';

  @override
  String get standbyCamera => '会话已登记，相机硬件关闭（无绿点、不耗电）。拨到「禁用」= 立刻注销会话并关闭相机。';

  @override
  String get activeSpeaker => '电脑此刻正在把声音推给手机播放。拨到「禁用」= 立即停止播放并断开该通道。';

  @override
  String get activeMic => '电脑应用此刻正在录手机麦克风，硬件已开启。拨到「禁用」= 立即注销并关麦。';

  @override
  String get activeCamera => '电脑应用此刻正持有虚拟摄像头，相机硬件开着。拨到「禁用」= 立即注销会话并关闭相机。';

  @override
  String get detailDisabled => '已禁用 · 电脑无法使用';

  @override
  String get detailOffline => '连接电脑后自动进入待命';

  @override
  String get detailPendingCam => '已连接 · 电脑请求后自动取景';

  @override
  String get detailPendingMic => '已连接 · 等待在手机上授权录音';

  @override
  String get detailStandby => '待命中 · 硬件已关闭，不耗电';

  @override
  String get detailActiveSpeaker => '正在播放电脑推来的声音';

  @override
  String get detailActiveMic => '电脑此刻正在使用你的麦克风';

  @override
  String get detailActiveCamera => '电脑此刻正在使用你的摄像头';

  @override
  String get gateOff => '← 禁用';

  @override
  String get gateOffCurrent => '← 禁用（当前）';

  @override
  String get gateOn => '启用 →';

  @override
  String get gateOnCurrent => '启用（当前）→';

  @override
  String get grantPermission => '授权';

  @override
  String get paramsTitle => '参数';

  @override
  String get micNoPermission => '手机还没有录音权限，授权后才能当电脑麦克风';

  @override
  String get micStateRecording => '录音中：麦克风硬件已开启';

  @override
  String get micStateStandby => '待命：麦克风硬件已关闭';

  @override
  String get micStateStarting => '正在开启…';

  @override
  String get micStateOff => '未启用';

  @override
  String get micUplinkBitrate => '上行码率';

  @override
  String micUplinkFormat(int khz) {
    return '$khz kHz · 单声道';
  }

  @override
  String get micUplinkSampleRate => '上行采样率';

  @override
  String get micRate48 => '48 kHz · 直通';

  @override
  String get micRate44 => '44.1 kHz · PC 重采样';

  @override
  String get micParamHint =>
      '待命中改档位即刻生效：重发一次登记（mic_start）让服务器知道新速率；正在录音则会静默重启采集，约 100ms 静音间隙，几乎无感。';

  @override
  String get micMuteLabel => '静音（会话保留，关闭手机录音）';

  @override
  String get micMutedLabel => '已静音 · 点按恢复录音';

  @override
  String get micMuteHint =>
      '静音 = 会话仍在册（电脑还看得见这台手机），但手机立刻关闭录音硬件并通知电脑丢弃残留声音；想让电脑彻底唤不起这台手机，请用顶部「禁用」。';

  @override
  String get micHowToUse =>
      '电脑上的会议 / 语音输入软件，把输入设备选为\n\"CABLE Output (VB-Audio Virtual Cable)\" 即可\n（连上电脑后手机自动待命；电脑一用麦克风手机才开录，\n电脑停用后手机立刻停止录音）';

  @override
  String get micStatusDisabled => '已禁用 —— 电脑无法使用手机麦克风';

  @override
  String get micStatusConnectedPerm => '已连接电脑，点下方按钮授权录音后即可直接使用';

  @override
  String get micStatusConnectedAuto => '连接电脑后自动进入待命，无需任何操作';

  @override
  String get micStatusMuted => '已静音 —— 电脑用麦克风时也不会录音';

  @override
  String get micStatusStandbyLong => '待命中 —— 麦克风已关闭，电脑用到时自动开启';

  @override
  String get micStatusOpening => '电脑正在使用，正在开启麦克风...';

  @override
  String get micStatusLive => '录音中 —— 电脑此刻正在使用你的麦克风';

  @override
  String get micBadgeWaitingPerm => '等待授权录音';

  @override
  String get micBadgeOff => '未启用';

  @override
  String get micBadgeMuted => '已静音 · 等待解除';

  @override
  String get micBadgeStandby => '待命中 · 麦克风硬件已关闭';

  @override
  String get micBadgeStarting => '正在开启…';

  @override
  String get micBadgeLive => '录音中 · 电脑此刻正在使用';

  @override
  String get camNoPermission => '手机还没有相机权限，授权后电脑才能使用';

  @override
  String get camQuality => '清晰度';

  @override
  String get camNoModes => '当前镜头暂无可用档位';

  @override
  String get camProbing => '探测中…（连上电脑后自动读取手机支持的档位）';

  @override
  String get camAutoHighest => '自动（最高档）';

  @override
  String get camCodec => '编码方式';

  @override
  String get camCodecAuto => '自动（硬件允许的最清晰）';

  @override
  String get camCodecActual => '当前实际：';

  @override
  String camRotate(int deg) {
    return '旋转 $deg°';
  }

  @override
  String get camParamHint =>
      '参数在任何状态都可以修改：正在取景 → 静默重启相机套用；待命 / 未连接 → 只记下选择，等相机开启时自动套用；拨到「禁用」才会锁住参数（改了也不会生效，不该给假设置）。';

  @override
  String get camFrozenLabel => '已冻结 · 点按恢复画面';

  @override
  String get camFreezeLabel => '冻结画面（会话保留，画面停住）';

  @override
  String get camHowToUse =>
      '电脑上的会议 / 相机 / 直播软件，把摄像头选为\n\"Unity Video Capture\" 即可\n（启用后手机待命；电脑一打开观看手机才开相机，\n电脑关闭观看后手机立即熄灭相机）';

  @override
  String get camIosNote =>
      'iPhone 注意：受 iOS 系统限制，摄像头必须在\n本页面亮屏待命才能推流（退后台/锁屏会断），\n麦克风与喇叭不受此限制';

  @override
  String get camRecOverlay => 'REC · 电脑正在使用你的摄像头';

  @override
  String get camPreviewOff => '相机未开启 · 待命中';

  @override
  String get camTapFullscreen => '点按全屏';

  @override
  String get camExitFullscreen => '退出全屏';

  @override
  String camStamp(String quality, String facing) {
    return '$quality · $facing';
  }

  @override
  String camRecStamp(String quality, String facing) {
    return 'REC · $quality · $facing';
  }

  @override
  String get camStatusDisabled => '已禁用 —— 电脑无法使用手机摄像头';

  @override
  String get camStatusConnectedPerm => '已连接电脑，授权相机后即可使用';

  @override
  String get camStatusStandbyAuto => '连上电脑后自动待命；也可在电脑上请求，手机确认后启用';

  @override
  String get camStatusFrozen => '已冻结 —— 电脑观看时也不会开相机';

  @override
  String get camStatusStandbyLong => '待命中 —— 相机已关闭，电脑打开观看时自动取景';

  @override
  String get camStatusOpening => '电脑正在观看，正在开启相机...';

  @override
  String get camStatusLive => '取景中 —— 电脑此刻正在使用你的摄像头';

  @override
  String get camBadgeWaitingPerm => '等待授权相机';

  @override
  String get camBadgeOff => '未启用';

  @override
  String get camBadgeFrozen => '已冻结 · 等待解除';

  @override
  String get camBadgeStandby => '待命中 · 相机硬件已关闭';

  @override
  String get camBadgeOpening => '正在开启…';

  @override
  String get camBadgeLive => '取景中 · 电脑此刻正在观看';

  @override
  String get camForceStopped => '电脑端已强制关闭摄像头';

  @override
  String get facingBack => '后置';

  @override
  String get facingFront => '前置';

  @override
  String get switchToFront => '切换前置';

  @override
  String get switchToBack => '切换后置';

  @override
  String get errConnectFirst => '请先在首页连接电脑';

  @override
  String get errMicPermission => '需要录音权限才能当电脑麦克风';

  @override
  String get errCamPermission => '需要相机权限才能当电脑摄像头';

  @override
  String get errMicDenied => '录音权限被拒绝，请在系统设置中允许';

  @override
  String get errMicBusy => '麦克风被其他应用占用，关闭后重试';

  @override
  String get errMicUnsupported => '不支持的采样率/声道组合';

  @override
  String errMicStart(String code) {
    return '麦克风启动失败: $code';
  }

  @override
  String get errCamDenied => '相机权限被拒绝，请在系统设置中允许';

  @override
  String get errCamNoLens => '手机没有对应镜头';

  @override
  String get errCamNoCaps => '读不到这颗镜头支持的画质档位，无法启动摄像头';

  @override
  String get errCamTimeout => '相机打开超时，请关闭其他相机应用重试';

  @override
  String get errCamBusy => '相机被其他应用占用，关闭后重试';

  @override
  String errCamStart(String code) {
    return '相机启动失败: $code';
  }

  @override
  String netError(String error) {
    return '连接错误: $error';
  }

  @override
  String netFailed(String error) {
    return '连接失败: $error';
  }

  @override
  String get spkMuteTitle => '本机静音';

  @override
  String get spkMuteSubtitle => '连接与电脑侧状态都保持，只是手机不出声';

  @override
  String get spkSourceLabel => '来源';

  @override
  String get spkSourceValue => '电脑系统声音（WASAPI 回环捕获）';

  @override
  String get spkFormatLabel => '音频格式';

  @override
  String get audioMono => '单声道';

  @override
  String get audioStereo => '立体声';

  @override
  String spkFormatValue(String khz, String ch) {
    return '$khz kHz · $ch · 16bit';
  }

  @override
  String get spkBitrateLabel => '链路速率';

  @override
  String spkBitrateValue(String mbps) {
    return '约 $mbps Mbps';
  }

  @override
  String get spkReceivedLabel => '已接收';

  @override
  String get spkPlayStatusLabel => '播放状态';

  @override
  String get spkPlayDisconnected => '未连接';

  @override
  String get spkPlayMuted => '接收中（本机已静音）';

  @override
  String get spkPlayPlaying => '正在播放';

  @override
  String get spkPlayWaiting => '已连接 · 等待电脑推流';

  @override
  String get spkParamsLocked =>
      '手机音量与缓冲档位（低延迟 ↔ 稳定）需要改造原生播放层（AudioTrack 的音量与 bufferDuration），本版暂未开放：音量请用机身侧键调节，缓冲由服务器按最低延迟策略固定。';

  @override
  String get spkHowToUse =>
      '电脑上无需选择任何播放设备：AudioServer 直接抓取系统声音，\n手机连上后就是电脑的第二个扬声器。\n要彻底不让手机出声，把上方滑块拨到「禁用」即可。';

  @override
  String get settingsTitle => '设置';

  @override
  String get languageTitle => '语言';

  @override
  String get langAuto => '跟随系统';

  @override
  String get langEn => 'English';

  @override
  String get langZh => '简体中文';

  @override
  String langAutoCurrent(String locale) {
    return '已识别系统语言：$locale';
  }
}
