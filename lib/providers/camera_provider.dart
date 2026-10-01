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
//     入口 A —— 手机上主动打开"摄像头守护"（本文件 toggle / 总闸 setEnabled）；
//     入口 B —— PC 端 GUI 点"请求手机开启摄像头"→ 服务器推 cam_request →
//               手机【直接】登记会话进待命（v3.8 起不再弹确认横幅）。
//     v3.8 变更说明：原先入口 B 要求用户在手机上再点一次"同意"，现按产品
//     要求取消 —— 用户把摄像头总闸拨到"启用"那一刻已经表态过，
//     不必对同一件事点头两次；真正的否决权仍在总闸（拨"禁用"= 彻底不给用）。
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

// ----------------------------------------------------------------------------
// 【文件说明书 · 给初学者】上面那段是"行为规格书"，这段是"新手导游图"
// ----------------------------------------------------------------------------
// 这个类管什么：手机"当 PC 摄像头"这件事的全部状态与决策。
//   它自己不直接开相机、也不直接写 socket，它只做判断：
//   什么时候允许 CameraService 打开相机硬件、什么时候允许 NetworkService 发帧、
//   界面此刻该显示哪个词、按钮该不该亮。这类"管数据 + 做决策"的类就叫 Provider。
// 它持有的状态（下面每个字段都有逐条注释）：
//   _state（四态枚举）/ _enabled（功能总闸）/ _sessionEstablished（PC 登记确认没）
//   / _serverLive（PC 那边是否真的有人在看）/ _muted（冻结键）
//   / _guardWanted（用户的意图）
//   / 镜头与画质档位 / 预览帧 / 错误文案键。
// 谁会调用它（向上，界面层 —— 界面文件由别人负责，这里只给指引）：
//   · lib/screens/camera_screen.dart —— 摄像头详情页（大按钮、冻结键、切镜头、
//     画质下拉框、旋转 90°、全屏预览），整页包在 Consumer<CameraProvider> 里；
//   · lib/screens/home_screen.dart —— 首页"摄像头守护"开关
//     （v3.8 起不再有 PC 请求确认横幅：cam_request 直接进待命）；
//   · lib/providers/device_provider.dart —— 把三个 Provider 的技术状态翻译成
//     界面要的五档状态词，并把用户的启用/禁用下发成 setEnabled(bool)。
// 它调用谁（向下，服务层）：CameraService（原生 Camera2）+ NetworkService（WebSocket）。
// 与 PC 端的握手顺序（摄像头版，一步步）：
//   ① 手机连上 WebSocket（连接本身归 ConnectionProvider 管，本类只旁观状态流）
//   ② connected → ensureCaps() 探画质档位（读相机"静态说明书"，不开硬件）
//   ③ 用户开守护(toggle)，或 PC 发 cam_request（v3.8 起免确认，直接登记）
//      → 发 cam_capabilities（能力清单）→ 发 cam_start（登记会话）
//   ④ PC 回 cam_ack → _sessionEstablished=true → 进 standby（相机依然关着）
//   ⑤ PC 上的应用真的打开虚拟摄像头 → PC 推 cam_state{active:true}
//      → 手机【此刻才】开 Camera2（live），JPEG 帧带 4 字节魔术头持续上行
//   ⑥ PC 应用关闭摄像头 → cam_state{active:false} → 关硬件回 standby
//   ⑦ 用户关守护 / 手机断线 / PC 发 cam_stop{forced} → 一路退回 idle
// 新手常问：本文件没有 Timer、没有 Isolate、没有 SharedPreferences、没有
//   Completer、也没有 mounted 判断 —— 这些概念在下面用到的地方会说明为什么不需要，
//   以及它们在项目里分别由哪个文件负责。
// ----------------------------------------------------------------------------

// dart:async：Dart 内置的异步库（不用额外安装）。
// 本文件用它拿两个类型：Stream（流）和 StreamSubscription（订阅句柄）。
// 流 = "随时间陆续吐出数据的管道"；订阅句柄 = 你接住这根水管后拿到的"开关把手"，
// 将来要关水管（dispose 时）必须靠它，所以凡是 listen() 都要把返回值存进字段。
import 'dart:async';
// dart:convert：提供 jsonEncode / jsonDecode。
// jsonEncode(一个 Map) 把它变成 JSON 文本字符串 —— 本项目所有"控制帧"
// （cam_start / cam_stop / cam_capabilities）都是这样发给 PC 的。
import 'dart:convert'; // jsonEncode / jsonDecode
// dart:typed_data：Uint8List = "无符号 8 位整型数组"，即原始字节数组。
// JPEG 图片、PCM 音频在网络上跑的都是它；BytesBuilder 用来把几段字节拼一根。
import 'dart:typed_data'; // Uint8List / BytesBuilder：拼帧头用

// flutter/material：这里真正要的其实只有 ChangeNotifier 这一个基类
// （它定义在 flutter/foundation 里，material 会顺带导出）。
// 之所以 import material 而不是 foundation，是项目统一的省事写法。
import 'package:flutter/material.dart'; // ChangeNotifier 所在
import 'package:shared_preferences/shared_preferences.dart';

// 服务层：CameraService 是"原生相机的 Dart 遥控器"（MethodChannel/EventChannel），
// NetworkService 是"WebSocket 收发器"。Provider 夹在中间做调度。
import '../services/camera_service.dart';
import '../services/network_service.dart';

// v3.7 国际化：文案表类型（由界面把实例传进 errorOf / statusTextOf 等）
// 为什么要界面传进来：Provider 活在没有 BuildContext 的地方，
// 它不知道用户当前用的是中文还是英文，所以只存"文案键"，句子交给界面翻。
import '../l10n/app_localizations.dart';

// ── enum 是什么？（新手关键概念）──
// enum（枚举）= 给"只能是那几种情况"的东西列一张清单。
// 摄像头的会话生命周期只有 4 个合法位置，如果用字符串表示（'live'），
// 手滑写成 'liv' 编译器不会拦你，只能等运行时出问题；
// 用 enum 就写错即编译失败。而且对 enum 做 switch 时，
// Dart 要求"穷举"（4 个都得处理，少一个就报错），这是自动的保护网。
// enum 的每个值都是单例对象，可以用CamState.live 这种"类.值"的方式引用。
//
// ── 状态机文字版流程图（本类内部的四态，界面五档由 DeviceProvider 再翻译一次）──
//
//   【idle 未启用】 触发：App 启动、断线、stop()、PC 强制关闭
//        │         界面：首页开关灰、大字"未启用"，只有"启用"按钮可点
//        │ 用户拨守护开关(toggle→_enterStandbyInternal)
//        │ 或 PC 发 cam_request（v3.8 起直接进待命，无需再点同意）
//        ▼
//   【starting 登记/开相机中】（瞬时态，通常一闪而过 <0.5 秒）
//        │         界面："正在开启…"；它同时被借用作"正在向 PC 登记"的过渡态
//        ├─ 登记成功 → 【standby】；开相机失败 → 退回 【standby】（不算致命）
//        ▼
//   【standby 待命】 触发：cam_ack 已回、会话在册，但相机硬件【关】（无绿点不耗电）
//        │         界面："待命中 · 相机硬件已关闭"
//        │ PC 推 cam_state{active:true} → _openCamera()
//        ▼
//   【live 取景中】 相机硬件已开，JPEG 帧正发给 PC
//        │         界面："取景中 · 电脑此刻正在观看"，预览画面在动
//        └─ PC 推 cam_state{active:false} → _closeCamera() → 回 【standby】
//   任何时刻：断线 / 用户关守护 / PC 强制关闭 → 直接回 【idle】
//   冻结键(_muted) 是把 live 拽回 standby 的另一条边（会话保留，见 toggleMute）。
//
// 注意这里【没有】disabled 这一态：功能总闸是一个独立的布尔 _enabled，
// 因为"禁用"和"现在在干什么"是两个正交的问题（详见 DeviceProvider 的五档状态）。
//
// ── 界面五态（disabled/offline/pendingConsent/standby/active）与本类的对应关系 ──
// 这五档不是本类定义的，它们在 lib/providers/device_provider.dart 的
// DeviceUiStatus 枚举里；那边把"本类的字段 + 连接状态"合起来算出该显示哪个词：
//   disabled      已禁用     ← _enabled==false（压倒一切，别的都不看）
//   offline       未连接     ← ConnectionProvider 说没连着电脑
//   pendingConsent 待电脑请求 ← 连着电脑但 _state==idle（摄像头特有：
//                              它【不】自动登记，要 PC 发 cam_request
//                              或用户先在手机上开守护；v3.8 起收到请求即登记）
//   standby       待命       ← isStandby（_state==standby，硬件关）
//   active        使用中     ← isLive（_state==live，取景中，词是"取景中"）
// 对用户分别意味着：
//   已禁用=我不会被用到，也别指望电脑能唤醒我；未连接=链路还没通；
//   待电脑请求=我准备好了但需要你（或电脑那边）先说一声；
//   待命=电脑一打开观看我就自己开相机，不用你动手；使用中=相机硬件亮着、画面正在走。
// 一句话记住分工：本类只管"技术上到哪一步了"，五态只管"该对用户说什么话"。
/// 摄像头会话状态枚举（界面按它显示不同文字/颜色/按钮可用性）
enum CamState {
  idle,     // 未启用（没登记会话，守护开关关着）
  standby,  // 待命：会话已登记、守护通知在跑，但相机硬件【关】
  starting, // 正在打开相机（瞬时状态）
  live,     // 取景中：PC 应用此刻正在观看，相机硬件已打开
}

// ── extends ChangeNotifier 是什么意思？（Flutter 状态管理第一课）──
// ChangeNotifier 是 Flutter 提供的一个"可以被监听变化的"基类，
// 它内部只干一件事：维护一份"监听者名单"，并暴露一个方法 notifyListeners()。
// 谁 addListener 注册过，调用 notifyListeners() 就会把名单上的人全部叫一遍。
//
// provider 这个包（pubspec.yaml 里的依赖）把这套机制接到了 Widget 树上：
//   ChangeNotifierProvider<CameraProvider>  ← main.dart 里注册（全 App 单例）
//   Consumer<CameraProvider>                ← 页面用它会 addListener + 自动重建，
//                                             build 里拿到的 provider 就是"最新数据"
//   context.watch<CameraProvider>()         ← 等价于 Consumer，但只重建它所在的
//                                             那个 widget，粒度更细、范围更小
//   context.read<CameraProvider>()          ← 【只在按钮 onTap 这类回调里用】：
//                                             只取一次实例、不建立监听关系，
//                                             所以改了数据界面不会刷新（省性能）
// 三者的取舍：要在 build 里"随数据变化重画"→ watch/Consumer；
// 只是"点一下调个方法"→ read（参见 lib/screens/camera_screen.dart、
// lib/screens/home_screen.dart 里的用法）。
//
// 为什么"改了字段就必须 notifyListeners()"？
//   Dart 不会自动发现"某个变量被改了"。界面是上次 build 时留下的快照，
//   你不喊一声，它就永远显示旧值（按钮不亮、状态词不动）。
//   本类的规矩是：状态字段一律私有（带 _ 前缀）+ 公开 getter 只读，
//   改状态的唯一入口是这些方法，方法末尾统一 notifyListeners()，
//   这样"数据"和"界面"就不会打架。
/// 手机摄像头状态管理
class CameraProvider extends ChangeNotifier {
  // final：一经赋值终身不换。_networkService 不是自己 new 出来的，
  // 而是构造函数"注入"进来的（依赖注入：本类不关心是谁造的 WebSocket，
  // 好处是测试时能塞一个假的进来）。
  // NetworkService 是全 App 共用一个实例（见 main.dart），
  // 所有 Provider 都订阅它的流，所以它是 broadcast（广播）流。
  final NetworkService _networkService; // WebSocket 出口
  // 这个是自己 new 的：CameraService 只是两条平台通道的"翻译壳"，
  // 本身很轻，不依赖别人，所以直接构造（字段初始化的默认写法）。
  final CameraService _cameraService = CameraService(); // 原生采集

  // ── 四条订阅句柄（StreamSubscription? 是可空类型）──
  // 类型带 ? = "可以是 null"。为什么初始是 null？
  // 因为"还没订阅过"这件事必须能表示出来；Dart 的空安全会强制你
  // 在使用前判空（这里用 ?. 语法：为 null 就整句跳过，不会崩）。
  // 规矩：凡是 listen() 出来的都必须存进一个字段，并在 dispose() 里 cancel()，
  // 否则对象销毁后回调还会被触发 → 内存泄漏 / 操作已销毁对象崩溃。
  StreamSubscription? _statusSubscription;   // 连接状态（断线清理/重连恢复）
  StreamSubscription? _ackSubscription;      // cam_ack 回执
  StreamSubscription? _requestSubscription;  // cam_request PC 请求启用
  StreamSubscription? _forceStopSubscription; // cam_stop{forced} PC 强制关闭
  // ⚠ 注意：接线 4（camStateStream，PC 观看状态）的 listen 返回值【没有】存进
  // 字段，因此 dispose() 里无法取消它。实际影响很小（NetworkService 和本类
  // 都是 App 级单例、同生共死），但如果将来把 CameraProvider 改成可重建的，
  // 这里会变成重复回调的隐患。属于"要不要修由你定"的遗留点，未改代码。

  // ── 下面这些就是这个类的"全部家当"：界面读的就是它们，别的都是中间产物 ──
  CamState _state = CamState.idle;
  bool _sessionEstablished = false; // 服务器已确认登记（收到 cam_ack）
  bool _serverLive = false;   // PC 是否有应用正在观看虚拟摄像头
  bool _muted = false;        // 手动静音（冻结画面）键
  bool _needsPermission = false; // 想启用但缺相机权限
  // _guardWanted 是一个"意图位"（intent flag）：它记录的不是现状，
  // 而是"用户希不希望有这个功能"。断线时状态会清零，但这个意图要留着，
  // 重连后据此自动恢复登记 —— 用户就不必重新拨一次开关。
  // 隐私设备必须严格区分"现状"和"意图"：现状说关就关，意图也要跟着关，
  // 否则会出现"用户明明关了、重连后相机又悄悄打开"的可怕行为（见 stop()）。
  bool _guardWanted = false;  // 用户意图：想要摄像头守护（断线重连后自动恢复登记）
  // v3.8：这里原本还有一个 _requestPending（"收到 cam_request，等用户点同意"）。
  // 取消二次确认后它永远不会变 true，连同 acceptRequest()/declineRequest()
  // 与首页的 _ConsentBanner 一起删除 —— 留着只会让读代码的人以为还有这道关。
  // v3.7 国际化：错误存【文案键】+ 原始细节，不再存中文句子
  // 为什么？Provider 没有 BuildContext，拿不到当前语言；
  // 把"我看到什么错"和"这句话怎么说"分开，界面才能翻译。
  // String? 可空：null 表示"当前没有错误"，界面据此决定红字显不显示。
  String? _errorKey;
  String? _errorDetail;

  // ── v3.6：本设备的功能总闸（页顶"启用/禁用"块控制，值由 DeviceProvider 存本地）──
  // false = 用户禁用了手机摄像头：不登记会话、收到 cam_state/cam_request 也不开硬件，
  // 关闭那一刻会主动注销（发 cam_stop）。它就是用户要的"唯一手动否决权"。
  //
  // 【闸门（gate）为什么要这么设计 —— 产品要求，不是技术限制】
  // 1. 用户只想要【一个】开关就能彻底关掉这台设备。如果"禁用"只是界面隐藏按钮，
  //    PC 那边仍可能通过 cam_request / cam_state 把相机唤醒 —— 那就不叫关掉了。
  // 2. 所以 _enabled=false 时，连上了也【不登记会话】：不发 cam_start，
  //    PC 的会话表里根本没这台手机，它再怎么点"请求摄像头"都找不到人。
  // 3. 【两道保险】（belt-and-suspenders）：
  //    第一道在入口 —— _enterStandbyInternal() 和接线 5 都先查 _enabled，走不进待命；
  //    第二道在执行 —— _openCamera() 再查一次 _enabled，绝不碰硬件。
  //    看起来重复，但入口以后可能增加（定时任务、新的 PC 指令、别的页面调用），
  //    第二道是"最后一道墙"，比信任所有调用者安全得多。
  // 4. 值的持久化在 DeviceProvider（SharedPreferences，键 device_enabled_camera），
  //    本类只负责"执行动作"，账本只有一份，不会出现两处记得不一样。
  bool _enabled = true;

  // ── 镜头与画质 ──
  String _facing = 'back'; // 设计决定：默认后置镜头
  List<CamLensCaps> _caps = const []; // 能力探测结果（发给 PC + 本地选档）
  // const [] = 编译期就确定的"空列表常量"，不能往里加东西，
  // 用它当"还没探测到"的初始值最省内存（不用 new 一个空 List）。
  // ==========================================================================
  // 【v3.8.3 通则】画质档 / 帧率只能来自手机自己上报的能力清单，代码不许造。
  // 每台手机的 CMOS + HAL 支持的档位都不一样（有的最高 960×720@30，
  // 有的是 1920×1080@60，还有的只有 4 档），任何写死的"通用档"在 A 机上是
  // 浪费、在 B 机上可能根本不支持。所以这里初始值用 0 = 【未知】，
  // 只有 ensureCaps() 探到真实清单后由 _pickBestProfile() / selectProfile()
  // 填上真值；填不上就判定 profileKnown == false，绝不开相机。
  //
  // 为什么不能给"保险默认值"：一旦给了 640×480@30，探测失败时 App 会【安静地】
  // 用这个假档去登记会话并打开硬件 —— 用户看到的是"能出画面但很糊"，
  // 而不是"这台机器报不出能力"。假档会掩盖问题，也违背"跟着设备走"。
  // ==========================================================================
  int _selWidth = 0;        // 当前选定的画质档（0 = 还没从手机拿到）
  int _selHeight = 0;
  int _selFps = 0;

  /// 当前档位是否【真的来自手机能力清单】。
  /// false = 探测没完成 / 这台机器的这颗镜头一档都报不出来 → 不许开相机、
  /// 不许向 PC 登记会话（否则 PC 会按一个凭空编出的分辨率去开虚拟摄像头）。
  bool get profileKnown => _selWidth > 0 && _selHeight > 0 && _selFps > 0;
  // v3.8：帧率【不再】人为封顶 30fps。以前 clamp(1, 30) 是写给"省带宽、防发热"
  // 的老顾虑，结果把本来能跑 60fps 的机也按到 30，用户肉眼可见地卡。
  // 现在的规则是"跟着设备走"：能力探测报这档最高多少 fps，App 就用多少。
  // 代价（发热、上行带宽）由用户自己决定 —— 界面下拉框可以随时切回低帧率档。

  // ── v3.4.1：手动旋转偏移（0/90/180/270，顺时针，单位：度）──
  // 真正的数字存在原生 CameraEngine 里（每帧压缩时套用）；
  // 这里只是镜像一份给界面显示按钮文案用。
  // 断线重连/切镜头都不会被清零（原生 stop 不重置它）。
  // 为什么只"镜像一份"：数据的真主人是原生，Dart 这边留一份副本只为让按钮
  // 能显示"旋转90°→180°"这种文字。这类"显示副本"不参与任何决策，
  // 所以就算和原生短暂不一致也不会出错。
  int _manualRotation = 0;

  // ── 预览 ──
  // Uint8List? 可空：null = 此刻没有画面（未启用/已关相机），界面就画占位图。
  Uint8List? _previewJpeg;  // 最新一帧 JPEG（界面 Image.memory 直接显示）
  int _lastNotifyMs = 0;    // 预览刷新节流时间戳

  /// 【v3.8.4】预览帧的**独立通知通道**，界面只让预览卡订阅它。
  /// 为什么必须另开一条：相机一秒出 10~30 帧，若每帧都 notifyListeners()，
  /// 整页 Consumer 会跟着重建同样多次。实测（Redmi 4X，8×A53，960×720）主线程
  /// （Dart UI）独吃 1.66 核 —— 比 4 条 JPEG 压缩流水线加起来还贵，
  /// 抢占了本该给采集流水线的核，反过来把相机帧率压到 11fps（背压）。
  /// 改成"帧只走这条通道"后：帧刷新只重建预览卡那一个 widget，
  /// 整页仍然只在【状态真的变了】时才重建（那本来就是低频事件）。
  /// ⚠ 帧刷新请一律用 previewFrame，**不要**改成 notifyListeners()。
  final ValueNotifier<Uint8List?> previewFrame = ValueNotifier(null);

  /// 【v3.11】预览纹理 —— 相机画面直通 GPU 的那块纹理（含 id / 摆正方式 / 尺寸）。
  ///
  /// 有值时界面用 `Texture(textureId: id)` 显示预览：画面从 HAL 进 GPU，
  /// 不经过 CPU 解码，也就没有"每秒 20 多次解一张 960×720 位图"的开销
  /// （那正是预览卡顿的根源）。
  /// null = 这台机没走纹理通道，界面退回原来的 `Image.memory` 解码预览。
  ///
  /// 为什么不是 final/常量：切镜头会重建纹理（id 变），停相机后纹理作废，
  /// 所以每次开/切/停都要重新问原生一次（见 _refreshPreviewTexture）。
  CamPreviewTexture? _previewTexture;
  CamPreviewTexture? get previewTexture => _previewTexture;

  /// 开相机 / 切镜头之后重新取一次预览纹理。
  /// 取不到就置 null —— 界面据此自动退回 JPEG 解码预览，永远不会白屏。
  Future<void> _refreshPreviewTexture() async {
    _previewTexture = await _cameraService.previewTextureId();
  }

  // ══════════════════════════════════════════════════════════════════
  // 【v3.16】编码方式（JPEG / H.264 / H.265）
  // ══════════════════════════════════════════════════════════════════
  // 上行画面以前只有一种压缩格式（JPEG，软件编码）。现在设备有硬件编码器时
  // 可以走 H.264 / H.265：同码率下明显更清楚，或用同样的画质省 2~3 倍码率。
  //
  // 三个值要分清：
  //   _codec        —— 【用户意图】下拉框选的那个。null = 自动。
  //   _codecOptions —— 【设备能力】这台机在当前画质下能跑哪几种（按清晰度降序）。
  //   _activeCodec  —— 【实际结果】原生此刻真在用的。可能与 _codec 不同：
  //                    选了 H265 但编码器起不来时会降级，界面要显示实际值。

  /// 持久化键：用户选过的编码方式（下次开 App 沿用）
  static const String _kCodecPref = 'cam_codec';

  /// 用户选的编码方式。null = 【自动】—— 由原生按硬件能力挑清晰度最高的。
  String? _codec;
  String? get codec => _codec;

  /// 可用的编码方式，按清晰度从高到低。末尾永远是 'JPEG'（软件兜底）。
  List<String> _codecOptions = const ['JPEG'];
  List<String> get codecOptions => _codecOptions;

  /// 原生实际在用的编码方式（'JPEG' / 'H264' / 'H265'）
  String _activeCodec = 'JPEG';
  String get activeCodec => _activeCodec;

  /// 读回上次的选择。只在初始化时调一次，失败就保持自动（不影响任何功能）。
  Future<void> _loadCodecPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_kCodecPref);
      if (v != null && v.isNotEmpty) _codec = v;
    } catch (_) {
      // 读偏好失败无所谓：最多是回到自动选择，不会有任何功能损失
    }
  }

  /// 重新问一次"这台机在当前画质下能跑哪些编码方式"。
  ///
  /// 必须带档位一起问：硬件编码器对分辨率/帧率有门槛，档位一变结论就变。
  /// 用户之前选的若已不在列表里（换了手机、或档位变了）→ 自动回到"自动"。
  Future<void> _refreshCodecOptions() async {
    if (!profileKnown) return; // 档位还没探到，问了也没意义
    final opts = await _cameraService.codecOptions(
      width: _selWidth,
      height: _selHeight,
      fps: _selFps,
    );
    _codecOptions = opts;
    if (_codec != null && !opts.contains(_codec)) _codec = null;
  }

  /// 切换编码方式。传 null = 回到自动（按硬件挑最清楚的）。
  ///
  /// 取景中切换会立刻生效（原生重建编码器，中间一两帧可能为空，不会断流）；
  /// 非取景态只记账，下次开相机时使用。
  Future<void> selectCodec(String? codec) async {
    _codec = codec;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (codec == null) {
        await prefs.remove(_kCodecPref);
      } else {
        await prefs.setString(_kCodecPref, codec);
      }
    } catch (_) {
      // 存不下只是"下次不记得"，本次选择照样生效
    }
    if (_state == CamState.live) {
      final err = await _cameraService.setCodec(codec);
      if (err != null) _reportNativeError(err);
      // 以原生回的"实际值"为准：选了 H265 但起不来时会降级成别的
      _activeCodec = await _cameraService.currentCodec();
    }
    notifyListeners();
  }

  /// 【v3.12】屏幕横竖变了之后，重新问一次"画面该怎么摆正"。
  ///
  /// 为什么需要：摆正角度 = 传感器安装角 + 手机当前持握方向，进全屏会强制
  /// 转成横屏、退出又转回竖屏，角度是跟着变的。但纹理是在开相机那一刻建的，
  /// 它的 orient 不会自己更新 —— 不重问一次，全屏画面就会歪着。
  ///
  /// 只有摆正方式【真的变了】才通知界面重建，避免无意义的刷新。
  Future<void> refreshPreviewOrient() async {
    if (_previewTexture == null) return; // 没走纹理通道就无所谓
    final t = await _cameraService.previewTextureId();
    if (t == null) return;
    final old = _previewTexture!;
    if (t.orient != old.orient || t.id != old.id) {
      _previewTexture = t;
      notifyListeners();
    }
  }
  // "节流"（throttle）= 一段时间内只放行一次。间隔由 _previewThrottleMs 决定。
  // v3.8 之前这里写死 100ms —— 等于把本地预览锁死在 10fps，而相机明明在出 30fps，
  // 这是"界面看着卡"的最直接原因。现在改为跟随实际帧率（见 _previewThrottleMs）。
  int _previewThrottleMs = 33;
  // 预览刷新间隔 = 1000 / 当前帧率，再夹在 [42, 100] 之间（v3.8.3）：
  //   · 下限 42ms —— 预览最多 ~24fps。曾试过跟帧率走满 30fps，实测低端机
  //     反而更卡（整页重建 + 解码把 UI 线程挤爆），24fps 已足够连贯；
  //   · 上限 100ms —— 保底节流，防止相机报了超低帧率时界面却在疯狂重建。
  //   · 15fps → 66ms（跟随）；30fps → 42ms；60fps → 42ms（封顶生效）。
  // 每次 _pickBestProfile() / selectProfile() 换档时都会重算这个值。

  /// 上行帧魔术头：4 字节 [0x03,'C','A','M']，服务器据此把 JPEG 帧
  /// 与麦克风 PCM 分流（PCM 撞这 4 字节的概率约 2^-32，可忽略）。
  // 0x03 是十六进制写法（= 十进制 3，控制字符 ETX），
  // 'C''A''M' 三个字节是字符的 ASCII 码（Dart 里单字符字符串取 codeUnit）。
  // static const = "类级常量"：整个 App 只有一份，编译期就算好，
  // 写成 const List<int> 而不是 final，表示连内容都不可改。
  // 为什么要魔术头：WebSocket 只给"帧"这一层，文本/二进制都往同一条通道塞，
  // PC 端需要一眼判断这堆字节是"摄像头 JPEG"还是"麦克风 PCM"，
  // 于是约定：二进制帧的前 4 个字节是身份证，后面才是正文。
  // ⚠ 注意：这个约定只在【手机→PC】方向用；PC→手机的系统声音 PCM 不加头，
  // 由 network_service.dart 按"音频数据流"单独分发，改协议时两端要一起改。
  // 关于 JPEG 质量与帧大小：压缩质量（例如 70~85）和"每帧多大"都不在本文件里，
  // 它们写死在 Android 原生 CameraEngine.kt 的压缩参数里（YUV→JPEG 在那边做）。
  // 质量调大 = 画面细节更好但每帧可能从 ~40KB 涨到 ~150KB，30fps 下就是
  // 4.5MB/s 的上行带宽，WiFi 会直接拥塞、延迟堆积、手机发烫掉帧；
  // 质量调小 = 省带宽但画面出现块状马赛克。要调它请改原生，不要在这里加参数。
  static const List<int> _frameMagic = [0x03, 0x43, 0x41, 0x4D];

  // ── 构造函数：本类的"接线总装" ──
  // 语法点：参数包在 {} 里 = 命名参数；required = 必传；
  // 冒号后面那段 `: _networkService = networkService` 叫【初始化列表】，
  // 是给 final 字段赋值的唯一机会（final 一旦进入函数体就不能再改）。
  // 构造函数没有函数体式的"返回值"，它做的事就是把 6 条线接上。
  // 谁 new 它：main.dart 里的 ChangeNotifierProvider<CameraProvider>(create: ...)。
  CameraProvider({required NetworkService networkService})
      : _networkService = networkService {
    // 【v3.16】读回上次选的编码方式（读不到就保持"自动"，不影响任何功能）
    _loadCodecPref();
    // 【接线 1：JPEG 帧 → 加魔术头发 WebSocket + 刷本地预览】
    // onFrame 是 CameraService 暴露的一个"回调槽"（类型是函数：
    // void Function(Uint8List jpeg)?）。这里把一个匿名函数（lambda）塞进去，
    // 原生每出一帧就调用它一次 —— 这就是"观察者/回调"套路，
    // 服务层因此不需要认识 Provider（依赖方向保持单向）。
    // 尾随的 ; 别漏：赋值语句结束后，构造函数体继续往下接其它线。
    _cameraService.onFrame = (jpeg) {
      // 只有"取景中且没冻结"才放行：待命时硬件本来就关着（不会有帧），
      // 这里是防"刚按冻结、原生最后一帧还在路上"这种竞态。
      if (_state == CamState.live && !_muted) {
        // BytesBuilder：字节"黏合剂"，先塞 4 字节头再塞 JPEG 本体。
        // 比 new Uint8List(4+len) 手工拷贝整洁，内部只分配一次。
        // copy: false = "别复制，我给的数组我保证不改"，省一次内存拷贝
        //（每帧都拷一次几十 KB 的话，一秒 30 帧就是白烧 CPU）。
        // .. 是【级联操作符】（cascade）：对同一个对象连续调用多个方法，
        // 第三个 `..add(jpeg)` 作用的还是那个 BytesBuilder，而不是返回值。
        // 等价于写成 b.add(...); b.add(...); 但更紧凑，且不会误用返回值。
        final packet = BytesBuilder(copy: false)
          ..add(_frameMagic)
          ..add(jpeg);
        _networkService.send(packet.toBytes()); // send 内有连接保护
        // send 的参数类型是 dynamic（String 和字节数组都能传）：
        // 文本帧发 JSON 控制指令、二进制帧发音视频字节，同一个方法搞定。
        // 未连接时它会静默丢弃（见 network_service.dart 的 send），
        // 所以这里不必再判一次 isConnected；断线时相机也会被接线 2 关掉。
        // 【v3.11】预览走 GPU 纹理时，界面根本用不到 JPEG ——
        // 那这一帧就只管上传 PC，一次都不惊动 UI 线程（连 ValueNotifier
        // 都不通知，预览卡不再被每秒重建二十几次）。
        // 只有"没拿到纹理通道"的老路径才照旧把帧递给 Image.memory 解码。
        if (_previewTexture == null) {
          _previewJpeg = jpeg; // 留一份给界面画预览
          final now = DateTime.now().millisecondsSinceEpoch;
        // 取"从 1970-01-01 UTC 起算的毫秒数"，是整数，做减法比 DateTime
        // 对象轻便得多（这个回调一秒可能被叫 30 次，能省则省）。
        // v3.8：节流间隔跟随实际帧率（相机出多少帧，界面就刷多少帧），
        // 不再是写死的 100ms。相机一秒出 N 帧时每帧都刷 = 一秒重建 N 次界面，
        // 这个上限由 _previewThrottleMs 的 16ms 下限托底，不会失控。
          if (now - _lastNotifyMs >= _previewThrottleMs) {
            _lastNotifyMs = now;
            // 【v3.8.4】只推给预览卡，不再 notifyListeners() 惊动整页
            //（理由见 previewFrame 字段注释：整页重建是主线程 1.66 核的元凶）。
            previewFrame.value = jpeg;
          }
        }
      }
    };

    // 【接线 2：连接状态变化】
    // listen((s) {...})：订阅状态流，每次 NetworkService 广播一个新状态，
    // 这个匿名函数就被调用一次，参数 s 是最新的 ConnectionStatus 枚举值。
    // 返回值是 StreamSubscription，必须存进 _statusSubscription 以便 dispose。
    _statusSubscription = _networkService.connectionStatusStream.listen((s) {
      if (s == ConnectionStatus.connected) {
        // 与麦克风不同：摄像头连上【不】自动登记（双入口设计）。
        // 但若用户之前开着守护（_guardWanted），重连后自动恢复登记。
        // 三个条件缺一不可：有意图(_guardWanted) + 当前确实空闲(_state==idle)
        // + 闸门开着(_enabled)。这里就是"闸门第一道保险"的入口检查之一。
        if (_guardWanted && _state == CamState.idle && _enabled) {
          _enterStandbyInternal();
        }
        // v3.4.13：连上就把"这台手机能跑什么画质"探出来缓存。
        // 探测走 CameraCharacteristics，【不需要打开相机硬件】，
        // 所以待命之前、甚至禁用状态下都能探 —— 画质下拉框因此随时可用。
        // 返回值（Future）没有 await：探测是"后台慢慢做"的，
        // 结果到达时 ensureCaps 内部自己 notifyListeners()，界面自动刷新。
        ensureCaps();
      } else if (s == ConnectionStatus.disconnected) {
        // 断线：硬件与本地状态全部清零，但保留 _guardWanted 意图，
        // 下次连上自动恢复待命（体验连续，不用重新点开关）。
        _sessionEstablished = false;
        _serverLive = false;
        _muted = false;
        // 只有"确实不在 idle"才去做关闭动作：idle 时没什么可关，
        // 也不该 notifyListeners（否则断线会白白重建一次界面）。
        if (_state != CamState.idle) {
          _cameraService.stop();
          _cameraService.stopGuardService();
          _state = CamState.idle;
          _previewJpeg = null;
          previewFrame.value = null; // 预览卡也要跟着清掉最后一帧旧画面
          notifyListeners();
        }
      }
    });
    // ⚠ 注意：这个回调里没有 else 分支处理 ConnectionStatus.error/connecting。
    // NetworkService 连接失败时会先广播 error（不是 disconnected），
    // 于是"连不上"时这里的清理分支不会走。当前行为是安全的（此时状态本就是
    // idle、硬件本就是关的），但如果将来在 connected 之外还挂别的资源，
    // error 会漏清理。只记录，不改代码。
    // ⚠ 另外：_cameraService.stop()/stopGuardService() 在这里没有 await
    //（回调本身不是 async）。原生调用仍会发出，只是 Dart 不等它完成，
    // 所以 notifyListeners() 可能先于"硬件真的关掉"返回。

    // 【接线 3：PC 回执 → 记账会话登记完成】
    // 协议细节：手机发 cam_start 后，PC 端 Rust 会把这条会话登记进表，
    // 并回一帧文本 JSON：{"type":"cam_ack", 可选 "active":true/false}。
    // active 字段由 network_service.dart 拆出来当成一条 cam_state 广播，
    // 所以这里【只管记账】：_sessionEstablished = true。
    // 参数写成 (_) 表示"这个值我用不上"（camAckStream 的类型是 Stream<String>，
    // 内容固定是 'cam_ack' 这个字符串，不需要看）。
    _ackSubscription = _networkService.camAckStream.listen((_) {
      _sessionEstablished = true;
      notifyListeners();
    });
    // ⚠ 注意：这里没有"cam_ack 超时"的兜底。如果 PC 那边丢了这条回执，
    // _sessionEstablished 会一直停在 false，后续 stop() 里的注销帧
    // （cam_stop）也就不会发出去 —— PC 端那条会话要等 TCP 断开才被发现。
    // 项目里没有任何 Dart 侧 Timer/心跳（超时判定目前在 PC 端 Rust 里做），
    // 要不要补一个 5 秒等 ack 的 Timer 由你定，代码未改。

    // 【接线 4：PC 观看状态 → 驱动相机硬件开/关（按需取景核心）】
    // 协议：PC 用 WASAPI/虚拟摄像头句柄数等办法判断"有没有应用真的在看"，
    // 变化时推 {"type":"cam_state","active":true/false}；
    // network_service.dart 解析出 active 后往 camStateStream（Stream<bool>）广播。
    // 这是"手机只在被看的这一刻才开相机硬件"的机制，省电也护隐私。
    _networkService.camStateStream.listen((active) {
      if (_serverLive == active) return; // 状态没变，什么都不做
      // 这叫【去重】（dedupe）：PC 会周期性重发同一条状态，
      // 若不去重，每次都 notifyListeners 就会白白重建界面、
      // 更糟的是会重复调用 _openCamera（虽有幂等保护，但没必要冒险）。
      _serverLive = active;
      if (active) {
        // PC 应用开始观看 → 待命中且没冻结，才开相机硬件
        // 注意这里【没有】判 _enabled：闸门由 _openCamera 内部第二道保险把关，
        // 禁用态下会走到 else 分支，只刷新界面文案、不碰硬件。
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
    // ⚠ 注意：这条订阅的返回值没有保存（见字段区的说明），dispose 时无法 cancel。

    // 【接线 5：PC 请求启用 → 直接进待命（v3.8：取消二次确认）】
    // 协议：PC GUI 上点"请求手机开启摄像头" → 推 {"type":"cam_request"}
    // （没有 payload 字段，所以 camRequestStream 的类型是 Stream<void>，
    //  参数写成 (_) 因为压根没有值可看）。
    //
    // 【v3.8 行为变更（应产品要求）】旧行为：置 _requestPending = true →
    // 首页弹"同意/忽略"横幅 → 用户点"同意"(acceptRequest) 才登记会话。
    // 新行为：PC 一发请求就【直接】登记。理由 ——
    //   1) 用户已经在手机上把摄像头总闸拨到"启用"（DeviceGate，键
    //      device_enabled_camera 持久化），那一次拨动本身就是他的授权；
    //      再让他对同一件事点第二次头，等于同一件事问两遍。
    //   2) 横幅是"等用户来处理"的异步界面，用户不在手机前时请求会一直挂着，
    //      PC 端看到的是"点了请求但手机没反应"，看起来像故障。
    // 仍保留的三道闸（一道不少，只是不再多问一句）：
    //   ① 没连上 → 不动；② 总闸关着 → 不动；③ 已在守护中 → 幂等不动。
    // 另外相机权限检查从"横幅的同意按钮"搬到了这里（见下方注释），
    // 免得登记出一条永远开不了硬件的会话。
    // 真正的否决权依然在总闸：想彻底不给用，去摄像头详情页拨"禁用"。
    _requestSubscription = _networkService.camRequestStream.listen((_) async {
      // 第一道闸：没连着就别登记（登记帧没人收，白做一次）
      if (!_networkService.isConnected) return;
      // 下面这条判断就是"闸门第一道保险"：PC 的唤醒意图在入口就被拦掉，
      // 禁用态下连一丝反应都没有 —— 用户才有真正的否决权。
      if (!_enabled) return; // v3.6：设备已禁用 → 闸门说了算，不进待命
      if (_state != CamState.idle) return; // 已在守护中，幂等退出
      // v3.8：横幅上那次"同意"被取消后，【权限检查必须自己补上】——
      // 原来它由 acceptRequest() 负责（用户点头后顺带弹系统授权窗）。
      // 不补会怎样：会话照样登记成功，但真到 _openCamera() 那一刻
      // 才被原生以 PERMISSION_DENIED 拒绝 —— 用户看到的是"登记了却开不了"。
      // ensurePermission() 内部先静默查一次，只有确实没授权才弹系统窗；
      // 此刻弹是合理的：总闸已被用户拨到"启用"，PC 又明确请求了，
      // 属于 Android 认可的"用到之前才问"，不像"刚连上就问"那样突袭。
      if (!await _cameraService.ensurePermission()) {
        _needsPermission = true; // 相机页会亮出琥珀横幅 + "授权"按钮
        _setError('errCamPermission');
        notifyListeners();
        return;
      }
      _needsPermission = false;
      _guardWanted = true; // 记住意图：这是"已授权"的等价物，断线重连自动恢复
      // 不 await：登记过程内部自己 notifyListeners，界面会跟着走。
      // 走的是和 toggle() 同一个终点 —— 检查不被绕过（见 _enterStandbyInternal）。
      _enterStandbyInternal();
    });
    // ⚠ 注意：这里 3 个 early-return 都没有留日志，PC 端点了请求但手机
    // 悄无声息时，排查只能靠推理（是没连？被禁用？还是已在待命？）。
    // 按铁律未改代码，是否加 debugPrint 由你定。

    // 【接线 6：PC 强制关闭 → 无条件注销（隐私总闸，不给拒绝的机会）】
    // 协议：PC GUI 的"强制关闭"开关 → 推 {"type":"cam_stop","forced":true}。
    // network_service.dart 只在 forced == true 时才往 camForceStopStream 广播，
    // 手机自己发出去的那种 {"type":"cam_stop"}（不带 forced）不会绕回来。
    _forceStopSubscription =
        _networkService.camForceStopStream.listen((_) {
      // 已经彻底空闲（没会话、也没意图）就没什么可关的，避免重复通知
      if (_state == CamState.idle && !_guardWanted) return;
      _guardWanted = false;
      stop(silent: true);
      _setError('camForceStopped');
      notifyListeners();
    });
    // ⚠ 注意：stop() 是 async 但这里没 await（回调不是 async 函数）。
    // 后果：stop() 只有"同步部分"（清 _guardWanted、发 cam_stop）先跑，
    // 它的异步尾巴（await 原生 stop 之后把 _state 置 idle 并再通知一次）
    // 会排在这次 _setError('camForceStopped') 之后才执行。
    // 顺序不影响最终结果（两边都不动 _errorKey），但界面上可能出现两次连续重建。
    // 未改代码，仅记录。
  }

  // --------------------------------------------------------------------------
  // Getters（界面只读出口）
  // --------------------------------------------------------------------------
  // 语法点：`CamState get state => _state;` 是"只读属性"的写法。
  //   get 关键字 = 定义一个不用括号的取值方法，界面写 provider.state 而不是
  //   provider.get_state()；=> 是"箭头函数"，等于 { return _state; }。
  // 为什么不直接把字段做成 public（去掉下划线）？
  //   因为外部一旦能 `provider.state = ...` 随便改，就绕过了 notifyListeners()，
  //   界面会显示旧值、硬件会失控。私有字段(_xxx) + 只读 getter
  //   是 Flutter 状态管理的标准围栏："改只能走我的方法，读随便读"。
  // 下面几个 bool getter 是"派生状态"（从 _state 算出来的），不是新存的字段，
  // 好处是永远不会和 _state 不一致；界面读 isLive 比写
  // provider.state == CamState.live 干净，也更少改代码。
  CamState get state => _state;
  bool get isLive => _state == CamState.live;
  bool get isStandby => _state == CamState.standby;
  bool get isBusy => _state == CamState.starting;
  bool get isMuted => _muted;
  bool get serverLive => _serverLive;
  bool get needsPermission => _needsPermission;
  bool get hasSession => _sessionEstablished;
  bool get guardWanted => _guardWanted;
  /// 记录/清除一条错误。只存文案键（+ 可选细节），句子由界面翻译。
  // 语法点：参数包在 [] 里 = 【可选位置参数】，调用时可以省略：
  //   _setError('errCamNoLens')          → detail 为 null
  //   _setError('errCamStart', code)     → 传了细节
  // 传 null 就是"清除当前错误"（_errorKey 变回 null，界面红字消失）。
  void _setError(String? key, [String? detail]) {
    _errorKey = key;
    _errorDetail = detail;
  }
  // ⚠ 注意：_setError 只写字段、不调 notifyListeners（它被当作"内部小工具"，
  // 由调用它的方法统一通知）。新加调用点时如果忘了 notifyListeners，
  // 错误文字就不会显示出来 —— 这是本类反复出现的一对小动作，值得留意。

  /// 当前错误的人话版本（v3.7 国际化）；null = 没有错误。
  // switch 表达式（Dart 3 语法）：`return switch (x) { 值 => 结果, ... };`
  // 和老式 switch 语句的区别：它有【返回值】，每个分支是一行 `=>`，
  // 不用写 break，也不会"穿透"到下一个分支。
  // 最后一行 `_ => ...` 是 default 分支（下划线表示"其余全部"）。
  // 为什么要 default：万一将来 _setError 塞进一个没登记过的键，
  // 至少把原始细节显示出来，不会出现"界面一片空白"这种更难查的情况。
  String? errorOf(AppLocalizations l10n) {
    final key = _errorKey;
    if (key == null) return null;
    // 上面这句是【卫语句】（guard clause）：先把"没错误"这种常见情况提前返回，
    // 剩下的代码就不用多套一层 if，缩进更浅、读起来更直。
    return switch (key) {
      'errConnectFirst' => l10n.errConnectFirst,
      'errCamPermission' => l10n.errCamPermission,
      'camForceStopped' => l10n.camForceStopped,
      'errCamDenied' => l10n.errCamDenied,
      'errCamNoLens' => l10n.errCamNoLens,
      'errCamTimeout' => l10n.errCamTimeout,
      'errCamBusy' => l10n.errCamBusy,
      // v3.8.3：手机报不出可用档位（能力探测空 / 该镜头一档都没有）
      'errCamNoCaps' => l10n.errCamNoCaps,
      'errCamStart' => l10n.errCamStart(_errorDetail ?? ''),
      // ?? 是"空合并"：左边是 null 就用右边兜底。
      // _errorDetail 是 String?，而 l10n.errCamStart 要求传非空 String，
      // 所以要 ?? '' 才过得了编译（这是空安全最常见的一个坑）。
      _ => _errorDetail ?? key,
    };
  }

  // ── 以下四个是"细节参数"的只读出口：画质下拉框、预览角标要用 ──
  String get facing => _facing;
  Uint8List? get previewJpeg => _previewJpeg;
  int get selWidth => _selWidth;
  int get selHeight => _selHeight;
  int get selFps => _selFps;

  /// 当前镜头的文案（切换按钮、预览角标用）
  // `条件 ? A : B` 是三元表达式（如果/就/否则 一行的写法），
  // 返回 String? 那种"要么是这个要么是那个"的场景用它最省。
  String facingTextOf(AppLocalizations l10n) =>
      _facing == 'back' ? l10n.facingBack : l10n.facingFront;

  /// 切换按钮的文案（v2 设计稿：不给前置/后置两个按钮，
  /// 只给一个"切换"按钮，文字指向另一颗镜头）
  // 所以这里判断的是"当前是哪颗"，但显示的是"切过去之后是哪颗"，
  // 别把方向看反：当前后置 → 按钮写"切换到前置"。
  String switchButtonTextOf(AppLocalizations l10n) =>
      _facing == 'back' ? l10n.switchToFront : l10n.switchToBack;

  /// 选定画质文案，如 "1280×720 @ 30fps"
  /// —— 纯数字与单位，全球通用，不进文案表。
  // 字符串插值：'$_selWidth' 会把变量值嵌进字符串；
  // 需要更复杂的表达式或紧跟字母时必须用 ${} 包起来 ——
  // ${_selFps}fps 里那个 {} 就是在跟后面的 'f' 抢边界（不包就解析不了）。
  // 档位未知时返回占位串（界面只在 live 状态才显示它，live 就一定是已知档，
  // 这里只是防止 0×0 @ 0fps 这种"代码造出来的数字"出现在任何角落）。
  String get qualityText =>
      profileKnown ? '$_selWidth×$_selHeight @ ${_selFps}fps' : '--';

  /// v3.4.1：当前手动旋转角度（0/90/180/270）
  int get manualRotation => _manualRotation;

  /// v3.4.1：点一次"旋转90°"→ 原生偏移 +90（循环），下一帧立即生效。
  /// 相机没开时也可以按：数字存在原生引擎里，开相机后自动套用。
  // Future<void> = "这件事会完成，但没有返回值"。
  // async 标记函数为异步函数（函数体内才能用 await）；
  // await 会【暂停这个函数】直到平台通道调用返回结果，它不阻塞界面动画 ——
  // Dart 是单线程事件循环，await 期间主 isolate 可以去处理别的任务。
  // 注意 await 之后这里直接改字段并通知：Provider 不是 Widget，
  // 没有"已销毁还去 setState"的风险，所以不需要 mounted 判断；
  // 但界面层（camera_screen.dart 的 StatefulWidget）在 await 之后
  // 用 context 前必须 if (!mounted) return;，这是两回事。
  Future<void> rotateManual90() async {
    _manualRotation = await _cameraService.rotateManual();
    notifyListeners();
  }

  /// 状态对应的人话文案（详情页大字）
  // 这是"状态 → 用户能看懂的一句话"的翻译器（参见 lib/screens/camera_screen.dart）。
  // 优先级顺序是刻意的：禁用压过一切 —— 闸都拉下了，别的话都不成立。
  // 界面五档（disabled/offline/pendingConsent/standby/active）的完整翻译在
  // lib/providers/device_provider.dart 的 statusOf/statusLabelOf，
  // 这里只是摄像头页内的那句大字，两处措辞要对齐。
  String statusTextOf(AppLocalizations l10n) {
    // v3.6：禁用优先于一切状态
    if (!_enabled) return l10n.camStatusDisabled;
    switch (_state) {
      // 老式 switch 语句：这里每个 case 都以 return 结尾，
      // Dart 的 case 不会像 C 那样"穿透"（不写 break 也不会掉进下一个 case）。
      // 对 enum 的 switch 必须穷举 4 个值，少写一个编译器就报错。
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
  // ⚠ 注意：idle 分支给的 camStatusStandbyAuto 文案是
  //   "连上电脑后自动待命；也可在电脑上请求，手机确认后启用" ——
  //   前半句和摄像头【不自动待命、必须人工同意】的真实行为不符
  //   （那是麦克风的行为，两句被共用了）。属于文案瑕疵，不是逻辑缺陷，
  //   要不要拆一个新键由你定，代码未改。

  /// 首页守护开关的副标题
  // 同一个状态在两个位置有两套话术：详情页说长句（解释原理），
  // 首页开关下说短句（一眼扫过）。两处都要跟着 _muted 变，别漏。
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
  // 启用路径（三个入口汇到同一个 _enterStandbyInternal）
  // --------------------------------------------------------------------------
  // "三条路、一个门"：用户在手机上开开关(toggle)、PC 发 cam_request（接线 5，
  // v3.8 起直接登记，不再弹确认）、以及总闸拨回启用(setEnabled)
  // 是【三个不同的入口】，但都必须走完整同样的检查（连接？权限？闸门？），
  // 所以真正登记的动作只留一份实现（_enterStandbyInternal），避免几条路走偏。

  /// v3.6：功能总闸（与 MicProvider.setEnabled 同一套语义）。
  /// 关掉 = 注销会话 + 关相机 + 撤守护（电脑那边再也唤不起）；
  /// 打开 = 若已连着电脑，直接回到待命（硬件仍关着，不取景）。
  /// 值的持久化统一由 DeviceProvider 负责，这里只执行动作。
  // 谁调它：只有 DeviceProvider.setEnabled(PcDevice.camera, on)（见
  // lib/providers/device_provider.dart），它先写 SharedPreferences
  // （键 device_enabled_camera）再调这里 —— 顺序不能反，否则动作触发的
  // 一连串回调会读到还没更新的旧开关值，界面闪一下错误状态。
  Future<void> setEnabled(bool on) async {
    // 幂等卫语句：值没变就别白折腾一圈（否则每次界面重建都可能重发登记消息）
    if (_enabled == on) return;
    _enabled = on;
    if (!on) {
      _guardWanted = false; // 禁用是更强的意图，重连后也不要自动恢复
      await stop();
    } else if (_networkService.isConnected) {
      _guardWanted = true; // 重新启用 = 用户要这个功能了
      await _enterStandbyInternal();
    }
    // 注意这个 else-if：拨到"启用"但【还没连电脑】时什么都不做 ——
    // 等接线 2 收到 connected 时，会因为 _guardWanted=false 也不自动登记
    // （摄像头不像麦克风那样"连上就待命"：要么用户先开守护，
    //  要么 PC 发 cam_request）。这是有意为之，不是漏写。
    notifyListeners();
  }
  // ⚠ 注意两点（都不改代码，只登记行为）：
  // 1) _guardWanted = true 写在这个分支里，意味着"用户拨总闸到启用"被当成
  //    了对摄像头的同意（它确实是用户在手机上主动做的操作）。
  //    v3.8 之后这条与 PC 的 cam_request 口径一致了：都是"用户已经表态过
  //    → 直接进待命"，不再有"拨了启用还得再点一次同意"的双层确认。
  // 2) PC 强制关闭时接线 6 把 _guardWanted 清了，但 _enabled 仍是 true。
  //    于是页首闸门看着还是"启用"，用户再拨一次也走不到这里（第一行
  //    `if (_enabled == on) return` 就退出了），想恢复只能去点首页守护开关。

  bool get enabled => _enabled;

  /// 首页守护开关 / 详情页大按钮统一入口：启用 or 彻底关闭
  // 界面上的写法（参见 lib/screens/camera_screen.dart 的
  // onPressed: () => provider.toggle()）：按钮只关心"现在开还是关"，
  // 具体该启用还是该注销由这个方法判断，界面不用自己记状态。
  Future<void> toggle() async {
    if (_state != CamState.idle) {
      // 分支 A：已经在跑（standby / starting / live）→ 这次点击是"彻底关闭"
      _guardWanted = false; // 用户主动关 → 断线重连也不再自动恢复
      await stop();
      // 卫语句：这条路到此为止，别掉进下面的"启用"逻辑
      return;
    }
    // 分支 B：当前空闲 → 这次点击是"启用"。下面两个检查都是"闸门式"的：
    // 不满足就记一条错误 + 通知界面 + 提前退出（三个动作成对出现，缺一不可）。
    if (!_networkService.isConnected) {
      _setError('errConnectFirst');
      notifyListeners();
      return;
    }
    // ensurePermission：静默查一次，没有权限就弹系统授权窗问用户一次。
    // await 在这里暂停，直到用户在系统弹窗上点了"允许/不允许"才继续 ——
    // 这就是为什么这个方法必须是 async。
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
  // ⚠ 注意：toggle() 自己不判 _enabled。界面在禁用态会把它灰掉
  // （camera_screen.dart 里 paramsLocked = !provider.enabled），
  // 但真被绕过时这里的检查顺序是：连接 → 权限 → 进 _enterStandbyInternal
  // 才被闸门拦下。副作用是"可能弹一次系统权限窗但什么也没登记"。

  // v3.8：这里原本还有 acceptRequest() / declineRequest() 两个方法
  //（PC 请求横幅上的"同意 / 忽略"）。二次确认取消后：
  //   · "同意"要做的事已被接线 5 直接做完（_guardWanted = true + 进待命）；
  //   · "忽略"这个动作不再存在 —— 想不给用就去拨总闸到"禁用"。
  // 两者连同首页横幅一起删除，不留"看起来还能拒绝"的死入口。

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

  // 【幂等】(idempotent) = 同一件事调一次和调十次结果一样。
  // 这里靠 _capsReady 做到：第一次进去就把它置 true，后面再调立刻 return。
  // 为什么顺序是"先置位再 await"：getCapabilities() 是异步的，期间
  // 可能又有别的地方（接线 2、_enterStandbyInternal、switchLens）调进来，
  // 若等结果回来才置位，那几次调用就都会真的去探一遍（重复的平台通道往返）。
  // 这是新手最容易写错的"异步竞态"套路之一，值得记住这个解法。
  Future<void> ensureCaps() async {
    if (_capsReady) return; // 探过了，直接用缓存
    _capsReady = true; // 先置位：并发调用只探一次
    // try/catch：把"可能抛异常"的代码包起来，抛了就跳进 catch 而不是整个 App 崩。
    // catch (_) 的 _ 表示"异常对象我不用看"（本项目的策略是"探测失败不致命"）。
    // 这里没有 finally —— finally 是"无论成功失败都要做的收尾"（比如关文件），
    // 本方法不需要，成功/失败分别已经在 try 和 catch 里处理干净了。
    try {
      _caps = await _cameraService.getCapabilities();
      _pickBestProfile(); // 按当前镜头挑最高档
      // 【v3.16】档位定下来之后才能问"这台机能硬件编码哪些格式" ——
      // 硬件编码器对分辨率/帧率有门槛，档位一变结论就变。
      await _refreshCodecOptions();
      notifyListeners(); // 档位表与编码方式都到了 → 下拉框该刷新
    } catch (_) {
      // 探失败：留个机会下次再探（比如下次进待命时）。
      // 注意这里【不编档位】—— _selWidth/Height/Fps 保持 0，
      // profileKnown 为 false，开相机的入口会拦下来并给用户明确提示。
      _capsReady = false;
    }
  }
  // ⚠ 注意：失败时只把 _capsReady 复原，没有记 _errorKey 也没有 debugPrint。
  // 表现是"画质下拉框一直显示探测中…"，用户不知道原因。是否补日志由你定。

  /// 进入待命：能力探测 → 挂守护通知 → 向服务器报能力 + 登记会话。
  /// 注意这里【不】打开相机硬件 —— 那是 cam_state 信号的事。
  // 这是启用入口（toggle / setEnabled / 接线 5 的 cam_request）共同的终点，
  // 私有方法（带 _）：
  // 界面不许直接调它，必须走那两个公开入口 —— 保证检查不被绕过。
  Future<void> _enterStandbyInternal() async {
    if (_state != CamState.idle) return; // 幂等
    if (!_networkService.isConnected) return;
    if (!_enabled) return; // v3.6：设备被禁用 → 任何唤醒路径都进不了待命

    // 借"启动中"闪一下：登记要走两次 await（探测 + 原生服务），
    // 不先 notifyListeners 的话界面会像"点了没反应"。
    _state = CamState.starting; // 借"启动中"闪一下，表示正在登记
    _setError(null);
    _needsPermission = false;
    notifyListeners();

    // 第一步：确保能力清单已探出（连上时通常已经探过，这里幂等兜底）。
    await ensureCaps();

    // 【v3.8.3】探不到档位 = 这台手机的这颗镜头没告诉我们它支持什么。
    // 此时【绝不】用代码编一个档位去登记 / 开硬件：
    //   · 编的分辨率 PC 端不知道真假，虚拟摄像头会按错的尺寸初始化；
    //   · 原生拿一个设备不支持的尺寸去 openCamera 会直接 SESSION_FAILED；
    //   · 更糟的是"能出画面但糊得莫名其妙"，用户完全无从判断原因。
    // 所以这里停下来，把状态退回 idle 并给用户一条明确提示。
    if (!profileKnown) {
      _setError('errCamNoCaps');
      _state = CamState.idle;
      notifyListeners();
      return;
    }

    // 第二步：守护前台服务（息屏不被杀，PC 唤醒指令才能送达）
    // Android 为了省电会杀后台进程；前台服务 = 挂一条常驻通知，
    // 向系统声明"我在干正经事别杀我"。它本身【不开相机】，只保活进程。
    await _cameraService.startGuardService();
    // 内部 try/catch 已把"通知权限被拒"吞掉（见 camera_service.dart），
    // 所以这里 await 不会抛，最坏情况只是息屏后唤醒不稳。

    // 第三步：把能力清单报给 PC（GUI 显示"手机最高支持什么画质"）
    // 协议：文本帧 JSON，type=cam_capabilities，
    //   cams = [ {facing:'back', sizes:[{width,height,maxFps}...] }, {front...} ]
    // _caps.map((c) => c.toMap()).toList() 是【集合方法】三连：
    //   map = 把每个元素加工成另一种类型（CamLensCaps → Map），返回的还是惰性
    //   的可迭代对象，所以要 .toList() 变成真正的 List 才能被 jsonEncode。
    //   同类的还有 where（筛选）、firstWhere（取第一个命中）、any/contains（判断）。
    _networkService.send(jsonEncode({
      'type': 'cam_capabilities',
      'cams': _caps.map((c) => c.toMap()).toList(),
    }));

    // 第四步：登记会话（语义同 mic_start —— 我上线了，需要我时推 cam_state）
    // 协议：type=cam_start，四个字段告诉 PC 这条会话的内容
    //   facing=镜头('back'/'front')，width/height=分辨率，fps=帧率。
    // PC 收到后登记会话表并回 cam_ack（可能附带 active=true，见接线 3）。
    // 这里的 send 没有 await：WebSocket 写出去就完事，回执走 camAckStream。
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
    // 原理见接线 4 的第一行 `if (_serverLive == active) return;` ——
    // 它就是靠"和上次不一样"来判断的，所以进新会话时必须清掉旧记忆。
    _serverLive = false;
    notifyListeners();
  }
  // ⚠ 注意：cam_start 发出去后本方法就当成功了，没有等 cam_ack、也没有超时。
  // 若回执丢失，界面显示"待命中"而 _sessionEstablished 仍是 false
  // （后果见接线 3 的说明）。要不要加 ack 超时由你定，代码未改。

  /// 从能力清单里给当前镜头挑"最高档"：
  /// 面积最大的一档，帧率取该档的【最高帧率】。
  /// v3.4.4：手动模式下如果手动档在新镜头上也受支持，就保持手动档不动。
  // v3.8：clamp 的上限从 30 拿掉 —— 不再替设备做主。
  // 下限保留 1：某些镜头会报出 maxFps=0，传 0 给原生会导致相机直接不出帧。
  void _pickBestProfile() {
    // 手动画质优先：用户手动指定过（_autoProfile=false）且这个档在【当前镜头】
    // 上也存在，就别替他改主意。（切镜头时前后置能力常常不同，才需要判一下）
    if (!_autoProfile && _manualProfileSupportedHere()) return;
    // CamLensCaps? 可空局部变量：null = "这颗镜头压根不在清单里"。
    // for 而不是 firstWhere：清单通常只有 2 项（前置+后置），直接循环最省事。
    // 这里取的是【最后一个】匹配项 —— 原生按 facing 唯一返回，实际不会冲突。
    CamLensCaps? lens;
    for (final c in _caps) {
      if (c.facing == _facing) lens = c;
    }
    // 【v3.8.3】这里【不回退到任何写死的档位】：探不到就保持 0（未知），
    // profileKnown 会是 false，开相机的入口会拦下。给"保险默认值"的代价是
    // 在用户不知情的情况下用一个设备可能根本不支持的尺寸去开硬件。
    if (lens == null || lens.sizes.isEmpty) return;
    // 挑"最高档"：先比面积，面积相同再比帧率（例如 1280×720 与 720×1280 面积
    // 一样，取帧率高的那个）。两条依据都来自手机上报的 maxFps，代码不编。
    var best = lens.sizes.first;
    for (final s in lens.sizes) {
      final bigger = s.width * s.height > best.width * best.height;
      final sameButFaster = s.width * s.height == best.width * best.height &&
          s.maxFps > best.maxFps;
      if (bigger || sameButFaster) best = s;
    }
    _selWidth = best.width;
    _selHeight = best.height;
    // clamp 只挡"设备报了 0fps 这种非法值"（传 0 给原生会导致相机不出帧），
    // 上限 240 是防 HAL 把某个异常大的数报出来，不干涉正常设备。
    _selFps = best.maxFps.clamp(1, 240);
    _syncPreviewThrottle();
    _autoProfile = true; // 手动档在当前镜头上不存在 → 回退自动
  }

  /// 预览刷新间隔 = 1000 / 当前帧率，结果夹在 [42, 100]（≈24fps 封顶）。
  /// 每次换档后跟着算一遍，保证"界面刷新节奏"永远不超过"相机出帧节奏"。
  // ~/ 是 Dart 的整数除（商向下取整，直接丢掉小数），用来避免 double。
  void _syncPreviewThrottle() {
    // 档位未知时用 33ms（≈30fps）—— 这只是【界面重建节奏】，不影响相机档位，
    // 也不是给设备编帧率：相机没起来时本来也没有帧可刷。
    if (!profileKnown) {
      _previewThrottleMs = 33;
      return;
    }
    // 上限夹在 [42, 100]（≈24fps 封顶）：
    //   · 42ms —— 预览刷新上限约 24fps。以前跟着帧率走到 30fps 后实测反而更卡：
    //     每次刷新是【整页 Consumer 重建】+ 一张 JPEG 解码，30fps 时低端机的
    //     UI 线程被 4 路压缩流水线挤占，重建排不上队。24fps 人眼已经很连贯
    //     （电影就是 24fps），把省下的算力还给流水线（保上行帧率）。
    //   · 100ms —— 保底节流，防止相机报了超低帧率时界面却在疯狂重建。
    //   · 15fps → 66ms（跟随）；30fps → 42ms；60fps → 42ms（封顶生效）。
    // 每次换档后都会重算，保证"界面刷新节奏"永远不超过"相机出帧节奏"。
    _previewThrottleMs = (1000 ~/ _selFps).clamp(42, 100);
  }

  // ── v3.4.4 手动画质档 ──────────────────────────────────────────
  // true  = 自动挑选（能力探测后取最高档，原有行为）
  // false = 用户在界面上手动指定的档位
  // 为什么要这个位：切镜头 / 重连都会重新挑档，如果用户明确选过 480p 省流量，
  // 程序不能"热心地"给他改回最高清。这一个布尔就是"别自作主张"的记号。
  bool _autoProfile = true;

  /// 当前镜头支持的全部分辨率档位（给界面下拉框用）
  // 参见 lib/screens/camera_screen.dart：它拿这个列表拼 DropdownMenuItem，
  // 空列表时把下拉框禁掉（provider.capsReady 用来显示"探测中…"）。
  // 返回类型 List<CamSizeCaps>：getter 每次循环现算，列表很小（通常 3~8 项），
  // 比缓存一份更简单也不会出现不一致。
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
  // 双层 for + continue：`continue` 表示"这一轮跳过、进下一轮"，
  // 用它先排掉不是当前镜头的项，比嵌套 if 少一层缩进。
  bool _manualProfileSupportedHere() {
    for (final c in _caps) {
      if (c.facing != _facing) continue;
      for (final s in c.sizes) {
        if (s.width == _selWidth && s.height == _selHeight) return true;
      }
    }
    // 两层循环都走完还没 return true，说明这颗镜头的档位表里没有当前这一档
    return false;
  }

  /// 用户手动选择某一档：帧率自动取该档上限（v3.8 起不再封顶 30fps）
  Future<void> selectProfile(CamSizeCaps size) async {
    if (_selWidth == size.width && _selHeight == size.height && !_autoProfile) {
      return; // 没变化，不折腾相机
    }
    _autoProfile = false;
    _selWidth = size.width;
    _selHeight = size.height;
    _selFps = size.maxFps.clamp(1, 240); // 只挡非法值，不挡高帧率
    _syncPreviewThrottle();
    await _applyProfileChange();
  }

  /// 恢复"自动挑最高档"模式
  Future<void> setAutoProfile() async {
    // 已经是自动态就什么都不做（幂等）：避免重复挑档 + 重复发登记帧
    if (_autoProfile) return;
    _autoProfile = true;
    _pickBestProfile();
    await _applyProfileChange();
  }

  /// 画质档变化后的统一善后：
  /// live 状态 → 重启相机硬件套用新档；standby → 重发 cam_start 更新登记；
  /// idle → 什么都不用做（下次进待命会用新档）。
  // 通知了两次 notifyListeners：开头一次让按钮/文字先响应，
  // 结尾一次把"相机真的重启完了"的最终状态铺给界面（中间是耗时操作）。
  Future<void> _applyProfileChange() async {
    notifyListeners();
    // 【v3.8.3】档位未知时不许拿 0×0@0 去开相机 / 登记会话。
    // 正常流程到不了这里（进待命时已经拦过一道），这里是防"以后有人新增调用点"。
    if (!profileKnown) return;
    if (_state == CamState.live) {
      // 取景中换档：唯一办法是 stop → start（Camera2 换流必须重建 session）。
      // 用户会看到画面黑一下约 0.1~0.5 秒，这是硬件限制，不是 bug。
      await _cameraService.stop();
      final error = await _cameraService.start(
        facing: _facing,
        width: _selWidth,
        height: _selHeight,
        fps: _selFps,
        // 【v3.16】null = 让原生按硬件能力自动挑（见 selectCodec 的说明）
        codec: _codec,
      );
      // CameraService 的错误约定（原生侧同规则）：
      // start 返回 Future<String?> —— null = 成功；非 null 是错误码字符串。
      // 这是"用返回值而不是抛异常"表达失败的写法，好处是调用方必须去看结果。
      if (error != null) {
        _reportNativeError(error);
        _state = CamState.standby; // 起不来就退回待命，不算致命
      } else {
        await _refreshPreviewTexture(); // 【v3.11】重建后的预览纹理 id
      }
    } else if (_state != CamState.idle) {
      // 待命/登记中：硬件没开，只要把 PC 那边记的档位更新一下就行
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
  // 这是"按需取景"落地的唯一开硬件入口，也就是【闸门第二道保险】所在：
  // 上面三个调用点（接线 4、_applyProfileChange、toggleMute）都没判 _enabled，
  // 全靠这里这一行守住"禁用=绝不亮硬件"的最后底线。
  // 两层检查（入口 + 执行）不是冗余：入口拦的是"不该做的事"，
  // 执行拦的是"万一有人新增了调用点"。安全相关的分支要宁可重复。
  Future<void> _openCamera() async {
    // 幂等：已经在取景 / 正在开的过程中就退出，
    // 防止 cam_state 连来两次 true 时开两次相机（原生会报 SESSION_FAILED）。
    if (_state == CamState.live || _state == CamState.starting) return;
    if (!_enabled) return; // v3.6：双保险 —— 禁用状态下绝不开硬件
    // 【v3.8.3】档位未知 = 手机没告诉我们它支持什么 → 不开硬件。
    // （正常路径在进待命时已拦过；这里是"入口 + 执行"双保险的执行侧。）
    if (!profileKnown) {
      _setError('errCamNoCaps');
      _state = CamState.standby;
      notifyListeners();
      return;
    }
    _state = CamState.starting;
    notifyListeners();

    // 交给原生开 Camera2 + 起采集线程 + 订阅 JPEG 水管（见 camera_service.dart）。
    // 参数就是当前选定档位；原生内部还会把 fps 再限幅一次（双保险）。
    // 注意【没有 try/catch】：CameraService.start 用"返回错误码"而不是抛异常
    // 来表达失败，所以下面是判 error != null，而不是 catch。
    final error = await _cameraService.start(
      facing: _facing,
      width: _selWidth,
      height: _selHeight,
      fps: _selFps,
      codec: _codec,
    );
    if (error != null) {
      // 失败不退回 idle 而是回 standby：会话还在册，PC 下次说"我要看"还能再试。
      // 这样用户不必重新点一遍开关，也不会因为一次抢占失败就整个功能没了。
      _state = CamState.standby; // 开相机失败退回待命，等下一次唤醒
      _reportNativeError(error);
      notifyListeners();
      return;
    }
    // 【v3.11】相机起来了 → 取预览纹理 id，界面据此切到 GPU 直通预览
    await _refreshPreviewTexture();
    // 【v3.16】以原生回的"实际在用"为准：选了 H265 但编码器起不来时会降级，
    // 界面显示这个实际值，用户才知道真实情况（而不是以为选了却没生效）。
    _activeCodec = await _cameraService.currentCodec();
    _state = CamState.live;
    _setError(null);
    notifyListeners();
  }
  // ⚠ 注意：帧的发送是靠接线 1 的 onFrame 回调，条件写的是 `_state == live`。
  // 本方法把 _state 置 live 之前，原生其实已经在出帧了，
  // 那几帧会被【丢掉】（不进 WebSocket、也不进预览）—— 影响只是开头少几帧画面。

  /// 关闭相机硬件回待命（PC 停用 / 用户按冻结 都走到这里）
  // 为什么不清 _sessionEstablished：会话登记仍然有效（PC 那边还认这台手机），
  // 下次 cam_state:true 来时可以直接开硬件，不必重新走一遍 cam_start。
  Future<void> _closeCamera() async {
    await _cameraService.stop();
    // 预览也要清掉：否则界面会留着最后一帧，看起来像"还在取景"的假画面
    _previewJpeg = null;
    // 【v3.11】相机关了，那块预览纹理也被原生回收了 —— 必须一起作废，
    // 否则界面会拿着一个已释放的 id 去采样（表现为黑屏或花屏）。
    _previewTexture = null;
    // 这行的写法值得学：idle 是"彻底关闭"，不该被降级成 standby，
    // 所以要加条件；其它态（live/starting）都回 standby。
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
  // 语法点：'back' ↔ 'front' 的翻转用三元表达式一行搞定
  //（当前是 back 就变 front，否则变 back），等价于 if/else 四行。
  // ⚠ 注意：_facing 用的是 String 而不是枚举（'back'/'front'），
  // 写错成 'btc' 编译器不会拦 —— 全链路（Dart/原生/PC）都靠这个字面值对齐。
  // 现状保持不动，改成 enum 的代价不小，是否要改由你定。
  Future<void> switchLens() async {
    if (_state != CamState.live) {
      // 非取景态：只改意图，等下一次开相机自然生效
      _facing = _facing == 'back' ? 'front' : 'back';
      await ensureCaps(); // 档位表可能还没探到（未连接时也能预设）
      _pickBestProfile(); // 前后置能力不同，重挑该镜头的最佳档
      await _applyProfileChange(); // 待命→重发 cam_start；idle→只记账
      return;
    }
    // live 分支：相机硬件正开着，换镜头必须让原生 stop→start 重建。
    // switchLens() 返回的是"原生实际切到的镜头"（'back'/'front'），
    // 之所以要接住返回值再比一次，而不是直接用 Dart 侧翻转后的值：
    // 有些手机只有一颗镜头，或原生切换失败，它会回原值 —— 以原生为准。
    final newFacing = await _cameraService.switchLens();
    if (newFacing != _facing) {
      _facing = newFacing;
      _pickBestProfile(); // 前后置能力可能不同，重挑档位
      // 【v3.8.3】新镜头报不出档位（极少见，比如外挂镜头）：就此停下，
      // 不拿"上一颗镜头的档"或代码编的默认值去重建 session。
      if (!profileKnown) {
        _setError('errCamNoCaps');
        _state = CamState.standby;
        notifyListeners();
        return;
      }
      // 档位变了但相机已开着：重启一次以套用新镜头的最佳画质
      await _cameraService.stop();
      final error = await _cameraService.start(
        facing: _facing,
        width: _selWidth,
        height: _selHeight,
        fps: _selFps,
        // 【v3.16】null = 让原生按硬件能力自动挑（见 selectCodec 的说明）
        codec: _codec,
      );
      if (error != null) {
        _reportNativeError(error);
        _state = CamState.standby;
      } else {
        await _refreshPreviewTexture(); // 【v3.11】切镜头会重建纹理，id 会变
        // 【v3.16】档位可能跟着镜头变了 → 可用的编码方式也会变，重问一次
        await _refreshCodecOptions();
        _activeCodec = await _cameraService.currentCodec();
      }
      notifyListeners();
    }
    // ⚠ 注意：newFacing == _facing 时（切换没成功 / 单镜头机型）这里静默无事：
    // 既不记错误也不 notifyListeners，用户点了按钮却没有任何反馈。
    // 只记录，未改代码。
  }

  /// 冻结键（通话软件式闭麦的摄像头版）：
  /// 按下 = 真关相机硬件（绿点灭），会话保留，PC 端画面停在最后一帧；
  /// 再按 = 若电脑正在看则立刻重开相机，否则安静待命。
  // 界面上的写法参见 lib/screens/camera_screen.dart：
  // provider.isMuted 决定按钮画"冻结/解冻"哪个图标，onPressed 都调这个方法。
  // 注意这里 _muted 是"先翻转再分支"，两条分支最后都会走到 notifyListeners
  // （要么由 _closeCamera/_openCamera 内部调，要么在 else 里调），不会漏刷新。
  Future<void> toggleMute() async {
    // ! 是逻辑非：true 变 false、false 变 true —— 一行翻转开关
    _muted = !_muted;
    if (_muted) {
      _previewJpeg = null;
      if (_state == CamState.live) {
        await _closeCamera(); // 冻结 = 硬件立即关闭
      } else {
        // 待命态按冻结：硬件本来就关着，只刷新一下文案（"已冻结"）
        notifyListeners();
      }
    } else {
      // 解冻：只有"电脑确实在看"才值得重新开硬件，否则继续省电
      if (_state == CamState.standby && _serverLive) {
        await _openCamera();
      } else {
        notifyListeners();
      }
    }
  }
  // ⚠ 注意：_muted 与摄像头的"闸门"不同 —— 它不发消息通知 PC，
  // PC 端只是收不到新帧（画面停在最后一帧），并不会知道手机已冻结。
  // 麦克风那边有 mic_mute 帧（见 mic_provider.dart 的 toggleMute）。要不要对齐由你定。

  /// 彻底关闭：注销会话 + 关相机 + 撤守护通知
  /// @param silent true = 不主动给服务器发 cam_stop
  ///               （PC 强制关闭场景：那边已经关了，不用再回执）
  // 命名参数（{bool silent = false}）：调用方必须写 stop(silent: true)，
  // 读代码的人一眼知道 true 是什么意思 —— 比 stop(true) 这种"裸布尔"清楚得多。
  // 有默认值 ⇒ 界面可以直接 provider.stop()。
  Future<void> stop({bool silent = false}) async {
    // v3.4.12：注销 = 用户不再要这个守护了，【意图】也要一起清掉。
    // 之前只有 toggle() 关闭分支会清 _guardWanted，而首页"摄像头守护"开关
    // 关闭走的是 stop()（见 home_screen.dart）→ 意图位残留 true，
    // 于是断线重连后 App 会自作主张把相机会话重新登记回去，
    // 电脑一开虚拟摄像头手机就悄悄开机 —— 违背用户刚刚亲手关掉的事实。
    // 隐私类状态必须"关了就真关了"，所以在这里统一清（幂等，多处调用无害）。
    _guardWanted = false;
    // 发 cam_stop 的三个前提同时成立才有意义：
    //   !silent（不是 PC 那边已经关好的场景）+ 还连着（不然发了也没人收）
    //   + 真的登记过（_sessionEstablished，不然 PC 表里压根没这条会话）。
    if (!silent && _networkService.isConnected && _sessionEstablished) {
      _networkService.send(jsonEncode({'type': 'cam_stop'}));
    }
    // 协议：{"type":"cam_stop"} 由手机发给 PC，表示"我不再提供摄像头了"，
    // PC 收到后注销会话（此后不会再推 cam_state 唤醒本机）。
    // 注意【不带】forced 字段 —— forced 是 PC→手机方向的"强制关闭"标志，
    // 见 network_service.dart 的解析分支，两个方向共用同一个 type 靠字段区分。
    await _cameraService.stop();
    await _cameraService.stopGuardService();
    // 下面这一段是"回到出厂账面"：五个字段逐一清回初始值。
    // 为什么连 _muted 也要清：下次用户重新启用时，应当是全新一次开始，
    // 不能带着上次的冻结残留（他会以为还是活的，其实画面停着）。
    _sessionEstablished = false;
    _serverLive = false;
    _muted = false;
    _state = CamState.idle;
    _previewJpeg = null;
    notifyListeners();
  }
  // ⚠ 注意：stop() 不清 _needsPermission，也不清 _errorKey；
  // 目前行为是"关闭后仍保留上次的提示"。是否符合预期由你定，代码未改。

  /// 原生错误码 → 记录对应错误（v3.7：只存文案键，句子交给界面翻译）
  // 这是一张"原生协议 → 界面文案键"的翻译表，集中一处才好维护。
  // 错误码字符串是 Android 侧 CameraEngine.kt 约定回传的（见 camera_service.dart
  // 的 start：成功 success(null)，失败 success("错误码")）。
  // Dart 3 的 switch 语句 case 不再穿透，所以每个 case 不用写 break。
  // default 分支把原始码留进 _errorDetail，界面会填进"启动失败: {code}"这句里，
  // 保证任何没见过的新错误码也至少能被看到（而不是显示一片空白）。
  void _reportNativeError(String code) {
    switch (code) {
      case 'PERMISSION_DENIED':
        _setError('errCamDenied');
      case 'NO_CAMERA':
        _setError('errCamNoLens');
      // v3.8.3：上层没从手机探到档位就调开相机（尺寸/帧率为 0）→
      // 原生拒绝执行。映射到"读不到档位"这条提示，而不是笼统的启动失败。
      case 'BAD_SIZE':
        _setError('errCamNoCaps');
      case 'OPEN_TIMEOUT':
        _setError('errCamTimeout');
      case 'SESSION_FAILED':
        _setError('errCamBusy');
      default:
        _setError('errCamStart', code);
    }
  }

  /// 销毁清理：取消订阅 + 关相机 + 撤服务（防泄漏的标准收尾）
  // 为什么必须"取消订阅"：这条订阅是构造函数里挂的，而 NetworkService 是
  // 全局长命的对象 —— 本类被销毁后，流仍然会把事件投递给这个已经没了的对象，
  // 轻则内存泄漏（整个 Provider 连同它的相机服务都被引用着不放），
  // 重则在已销毁对象上继续跑逻辑。?. 是空安全调用：没订阅过就整句跳过。
  // 顺序也是套路：先断外部事件源（订阅），再释放内部资源（相机/服务），
  // 最后一定要 super.dispose() —— 父类 ChangeNotifier 要清自己的监听者名单，
  // 而且它会标记"本对象已销毁"，之后再 notifyListeners 会直接断言失败。
  @override
  void dispose() {
    _statusSubscription?.cancel();
    _ackSubscription?.cancel();
    _requestSubscription?.cancel();
    _forceStopSubscription?.cancel();
    // _cameraService.dispose() 内部就是 stop() + stopGuardService()
    _cameraService.dispose();
    previewFrame.dispose(); // 独立预览通道也要关，否则热重载后会残留监听
    super.dispose();
  }
  // ⚠ 注意：本类实际有 5 条订阅，这里只取消了 4 条 ——
  // 接线 4（camStateStream）没存句柄所以取消不了（见字段区的 ⚠）。
  // 另外 dispose 里没调 stop()，也就是不会给 PC 发 cam_stop：
  // 靠 _cameraService.dispose() 关硬件、靠 TCP 断开让 PC 侧自己清会话。
  // 现状未改，是否要补由你定。
}
