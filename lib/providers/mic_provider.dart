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

// ----------------------------------------------------------------------------
// 【文件说明书 · 给初学者】上面是"行为规格书"，这段是"新手导游图"
// ----------------------------------------------------------------------------
// 这个类管什么：手机"当 PC 麦克风"这件事的全部状态与决策。
//   它不亲自录音（MicService 干）、不亲自发包（NetworkService 干），
//   它只维护一组状态字段并决定：什么时候允许开录音硬件、PCM 字节能不能发出去、
//   界面此刻该显示哪个词、电平条该画多高。
// 它持有的状态：_state（四态枚举）/ _enabled（功能总闸）/ _sessionEstablished
//   （PC 是否已登记这条会话）/ _serverLive（PC 那边是否真的有人在录）
//   / _muted（静音键）/ _needsPermission（缺权限）/ _sampleRate（采样率）
//   / _level 与 _bars（电平条数据）/ 错误文案键。
// 谁会调用它（向上，界面层 —— 界面文件由别人负责，这里只给指引）：
//   · lib/screens/mic_screen.dart —— 麦克风详情页（静音键、采样率选择、电平条）；
//   · lib/screens/home_screen.dart —— 首页"麦克风守护"开关与设备入口卡；
//   · lib/providers/device_provider.dart —— 把本类的技术状态翻译成界面五档词，
//     并把用户的启用/禁用下发成 setEnabled(bool)（它才是 SharedPreferences 账本）。
// 它调用谁（向下，服务层）：MicService（原生 AudioRecord 采集）
//   + NetworkService（WebSocket，把 PCM 和控制帧发给 PC 的 Rust AudioServer）。
// 与 PC 端的握手顺序（麦克风版，比摄像头少一步"人工同意"）：
//   ① 手机连上 WebSocket（连接归 ConnectionProvider 管，本类只旁观状态流）
//   ② connected → _autoStandby()：静默查权限 → 挂前台守护服务
//      → 发 {"type":"mic_start","sample_rate":...,"channels":1,"format":"pcm_s16le"}
//   ③ PC 回 {"type":"mic_ack", 可能带 "active":true} → _sessionEstablished=true
//      （若 active=true，network_service 会顺手把它当成一条 mic_state 推给接线 5）
//   ④ PC 上的应用打开麦克风（录 CABLE Output）→ PC 推 {"type":"mic_state","active":true}
//      → 手机此刻才开 AudioRecord，PCM 字节直接上行（无头、无压缩）
//   ⑤ PC 应用关闭 → active:false → 立刻停采集，回 standby
//   ⑥ 用户关守护 / 拨总闸禁用 / 断线 → 回 idle（禁用时发 mic_stop 注销）
// 新手常问：本文件没有 Timer、没有 Isolate、没有 SharedPreferences、
//   没有 Completer、没有 mounted 判断 —— 下面用到的地方会说明为什么，
//   以及这些概念分别由项目里哪个文件负责。
// 与 camera_provider.dart 的对照阅读建议：两个类结构几乎一样（同构），
//   差别只有三点：① 麦克风连上即自动待命，摄像头要用户点头；
//   ② 麦克风上行是裸 PCM 无包头，摄像头 JPEG 要加 4 字节魔术头；
//   ③ 麦克风静音会发 mic_mute 告知 PC，摄像头冻结只停帧不通知。
// ----------------------------------------------------------------------------

// dart:async：Dart 自带的异步库（无需 pub get）。本文件用它拿两个类型：
// Stream（流，"随时间陆续吐数据的管道"）和 StreamSubscription（订阅句柄，
// 就是"我接了这根水管"的凭据，将来 dispose 时靠它 cancel 关管）。
import 'dart:async';
// dart:convert：jsonEncode：把 Map 转成 JSON 字符串
// 本项目所有"控制帧"（mic_start / mic_stop / mic_mute）都这样发出去；
// 反过来，PC 发来的 JSON 由 network_service.dart 用 jsonDecode 解析。
import 'dart:convert'; // jsonEncode：把 Map 转成 JSON 字符串

// flutter/material：这里真正需要的只有 ChangeNotifier 这个基类（见类声明处）。
// 常规做法是 import 'package:flutter/foundation.dart'，本项目统一用 material
// 图省事（它把 foundation 全导出了）。
import 'package:flutter/material.dart'; // ChangeNotifier 所在

// 服务层：MicService 是"原生录音的 Dart 遥控器"（MethodChannel 问一句答一句、
// EventChannel 装一根水管持续放 PCM），NetworkService 是 WebSocket 收发器。
import '../services/mic_service.dart';
import '../services/network_service.dart';

// v3.7 国际化：文案表类型（由界面把实例传进 errorOf / statusTextOf）
// 为什么要界面传进来：Provider 活在没有 BuildContext 的地方，拿不到当前语言，
// 所以它只存"文案键"（如 'errMicPermission'），句子由界面去 AppLocalizations 取。
import '../l10n/app_localizations.dart';

// ── enum（枚举）是什么？新手第一课 ──
// enum = 给"只能是那几种情况"的东西列一张合法清单。
// 用字符串表示状态（'live'）时，手滑写成 'liv' 编译器不会拦，只能等运行时炸；
// 用 enum 就写错即编译失败，而且对 enum 做 switch 时 Dart 要求"穷举"
// （4 个值全得处理，少一个直接报错）—— 这是防止"新增了状态却忘了配文案"的保护网。
// 引用方式：MicState.live（类名.值），每个值都是全局唯一的单例对象。
//
// ── 状态机文字版流程图 ──
//
//   【idle 未启用】 触发：App 刚启动、断线、stop()（关守护/禁用总闸）
//        │         界面：首页开关灰、徽标"未启用"
//        │ ①连上电脑自动(_autoStandby) ②用户点按钮(toggle) ③拨总闸(setEnabled(true))
//        ▼
//   【starting 登记/开麦中】（瞬时态，通常 <0.3 秒）
//        │         界面："正在开启…"；它被借用作两个动作的过渡态：
//        │           向 PC 登记会话（enterStandby）/ 打开录音硬件（_openMic）
//        ├─ 成功 → standby 或 live；失败 → 退回 standby（不算致命，等下次唤醒）
//        ▼
//   【standby 待命】 会话在册 + 前台通知在跑，但麦克风硬件【关】：
//        │           不录音、不耗电、状态栏无录音小绿点
//        │ 界面："待命中 · 麦克风硬件已关闭"
//        │ PC 推 mic_state{active:true} → _openMic()
//        ▼
//   【live 录音中】 AudioRecord 已开，PCM 正发给 PC
//        │         界面："录音中 · 电脑此刻正在使用"，电平条在跳
//        └─ PC 推 active:false / 或用户按静音 → _closeMic() → 回 【standby】
//   任何时刻：断线 / 关守护 / 禁用总闸 → 直接回 【idle】
//
// 注意本枚举【没有】disabled 态：功能总闸是独立布尔 _enabled（见下方字段注释），
// "禁用"和"现在在干什么"是两个正交问题，界面五档由 DeviceProvider 合起来算。
/// 麦克风会话状态枚举（界面按它显示不同文字/按钮颜色）
enum MicState {
  idle,     // 未启用（未连接，或用户手动关闭守护）
  standby,  // 待命：会话已登记、前台服务在跑，但麦克风硬件【关闭】
  starting, // 正在打开麦克风（瞬时状态，通常 <0.3 秒）
  live,     // 录音上行中：电脑此刻正在使用麦克风，手机硬件已打开
}

// ── extends ChangeNotifier 是 Flutter 状态管理的起手式 ──
// ChangeNotifier 是 Flutter 提供的一个基类，作用只有一个：内部维护一份
// "监听者名单"，并暴露 notifyListeners() 这个方法 —— 一调用就把名单上的人全叫一遍。
// provider 这个包（见 pubspec.yaml 依赖）把它接到 Widget 树上：
//   ChangeNotifierProvider<MicProvider>  ← main.dart 注册，全 App 一个实例
//   Consumer<MicProvider>(builder: ...)  ← 页面用它：自动 addListener + 数据变了就重建
//   context.watch<MicProvider>()         ← 和 Consumer 等价但粒度更细，
//                                           只重建调用它的那个 widget
//   context.read<MicProvider>()          ← 只在按钮回调里用：只取实例、不建监听，
//                                           所以改了数据不会触发重建（更省）
// 用法取舍：build 里要"跟着数据重画"→ watch/Consumer；
// "点一下调个方法"→ read（参见 lib/screens/mic_screen.dart、home_screen.dart）。
//
// 为什么"改了字段必须 notifyListeners()"？
//   Dart 不会自动发现变量被改了；界面是上次 build 留下的快照，
//   不喊一声它就永远显示旧值（静音按钮不亮、电平条不动、状态词不切换）。
//   本类的规矩：状态字段全私有（_ 前缀）+ 公开 getter 只读，
//   改状态只能走下面的方法，每个方法末尾统一 notifyListeners()。
/// 手机麦克风状态管理
class MicProvider extends ChangeNotifier {
  // final = 一经赋值终身不换。_networkService 不是自己 new 的，
  // 而是构造函数注入进来的（依赖注入：本类不关心这条 WebSocket 是谁造的，
  // 测试时可以塞一个假的服务进来）。它是全 App 共用的单例（见 main.dart），
  // 所以它对外提供的都是 broadcast（广播）流，多个 Provider 能同时订阅。
  final NetworkService _networkService; // WebSocket 出口
  // 这个是自己 new 的：MicService 只是两条平台通道的"翻译壳"，很轻、无依赖，
  // 所以直接在字段上初始化（不必搬进构造函数）。
  final MicService _micService = MicService(); // 原生采集

  // ── 两条订阅句柄。类型带 ? = 可空（"还没订阅过"必须能被表示出来）──
  // Dart 的空安全会强制你使用前判空，这里用 ?. 语法：为 null 就整句跳过，不崩。
  // 铁律：凡是 listen() 出来的都要存进字段并在 dispose() 里 cancel()，
  // 否则对象销毁后回调仍被触发 → 内存泄漏 / 在已销毁对象上跑逻辑。
  StreamSubscription? _statusSubscription; // 连接状态订阅（自动待命的触发器）
  StreamSubscription? _ackSubscription;    // mic_ack 回执订阅
  // ⚠ 注意：接线 5（micStateStream，"电脑用/停"的权威信号）的 listen 返回值
  // 【没有】存进字段，所以 dispose() 无法取消它。目前 NetworkService 与本类
  // 都是 App 级单例、同生共死，实际影响很小；但如果将来 MicProvider 可被重建，
  // 这里会累积重复回调。仅登记，未改代码。

  // ── 下面这些就是这个类的"全部家当"，界面读的就是它们 ──
  MicState _state = MicState.idle;
  bool _sessionEstablished = false; // 服务器已确认登记（收到 mic_ack）
  bool _serverLive = false; // PC 是否有应用正在录 CABLE Output（服务器的权威判断）
  // 为什么叫"权威判断"：手机无法自己知道 PC 上哪个应用在用麦克风，只能听 PC 说。
  // PC 用 WASAPI 音频会话枚举算出结果，再用 mic_state 帧推过来。
  // 本类只缓存这个结论，并靠它做去重（见接线 5 的第一行）。
  bool _muted = false;      // 手动静音键：按下后即使电脑在用也不开麦

  // ── v3.4.4 上行采样率选项 ──────────────────────────────────────
  // 48000（默认）= 与 PC 声卡混音速率一致，服务器逐样本直通（零风险）；
  // 44100 = 手机按 44.1k 录音上行，服务器注入引擎自动线性插值重采样到 48k。
  // 改档即时生效：正在录音会静默重启采集，待命中只更新登记信息。
  //
  // 【魔数详解：采样率是什么】1 秒里对声音幅度采样多少次，单位 Hz。
  // 48000 = 每秒 4.8 万个样本，是人耳上限(约 20kHz)的 2 倍以上（奈奎斯特定理），
  //         也是 PC 声卡混音的常用速率 → 两端一致，服务器逐样本直通、零风险。
  // 44100 = CD 速率。手机按它录音，PC 端要重采样到 48k，会引入一次插值计算。
  // 带宽换算（单声道 16bit）：48000×2 字节 ≈ 96 KB/s ≈ 0.77 Mbps；
  //                          44100×2 字节 ≈ 86 KB/s。
  // 改大会怎样：再往上（如 96000）带宽和数据包数量都翻倍，WiFi 拥塞时
  // 会出现爆音/延迟堆积，而电话会议场景完全听不出差别；改小（如 16000）
  // 声音发闷，且 AudioRecord 未必支持所有速率（所以本类只开放两个保证值）。
  int _sampleRate = 48000;
  // getter 语法：`int get sampleRate => _sampleRate;` 是"只读属性"，
  // 界面写 provider.sampleRate 即可，不用写括号；=> 等于 { return ...; }。
  // 为什么字段私有而给 getter：外部若能手改 _sampleRate，就会绕过
  // setSampleRate 里的"重开采集/重发登记"善后，硬件和账面不一致。
  int get sampleRate => _sampleRate;

  /// 可选的采样率档位（AudioRecord 对两者都有硬性保证支持）
  // static const = 类级常量（编译期算好、全 App 只有一份、内容不可改）。
  // 没有下划线前缀 ⇒ 它是【公开】的：界面直接读 MicProvider.sampleRateChoices
  // 拼下拉框。这是"给界面看的清单"，不是状态，所以不需要 getter。
  static const List<int> sampleRateChoices = [48000, 44100];

  /// 切换上行采样率
  // 界面写法参见 lib/screens/mic_screen.dart 的采样率下拉框：
  // onChanged: (v) => provider.setSampleRate(v) —— 按钮回调里用 read 拿实例。
  Future<void> setSampleRate(int sr) async {
    // 幂等卫语句：值没变就直接退出，避免"选了同一档却把采集重启一遍"
    if (sr == _sampleRate) return;
    _sampleRate = sr;
    // 先通知一次：下拉框立刻显示新值（后面重开硬件的动作还在等）
    notifyListeners();
    if (_state == MicState.live) {
      // 正在上行：关硬件 → 用新速率重开（用户几乎无感，约 100ms 静音间隙）
      // 为什么必须 stop→start：Android AudioRecord 的采样率在构造时定死，
      // 想改只能销毁重建 —— 这不是本项目能绕过的限制。
      await _closeMic();
      // 重开前要重新确认"还有必要开吗"：_closeMic 会把状态改成 standby，
      // 若这期间电脑已经不用了（_serverLive 变 false）或用户按了静音，
      // 就安静地留在待命，不白开一次麦克风。
      if (_serverLive && !_muted) {
        await _openMic();
      }
    } else if (_state != MicState.idle && _sessionEstablished) {
      // 待命：重新登记一次，让服务器知道新速率
      // 协议：文本帧 JSON，字段含义 ——
      //   type        ：'mic_start'，PC 侧靠它分派"登记/更新手机麦克风会话"
      //   sample_rate ：采样率（48000/44100），PC 决定要不要重采样
      //   channels    ：声道数，固定 1（单声道）。改 2 的话数据量翻倍，
      //                 且 PC 的注入引擎按单声道设计，会出现左右声道错乱。
      //   format      ：'pcm_s16le' = 原始 PCM、每个样本 16 位有符号、小端序。
      //                 约定死了两端才能解读同一堆字节；不做压缩（省 CPU 与延迟）。
      // PC 收到后回 mic_ack；这里不等回执（send 是"发完就走"的同步方法）。
      _networkService.send(jsonEncode({
        'type': 'mic_start',
        'sample_rate': _sampleRate,
        'channels': 1,
        'format': 'pcm_s16le',
      }));
    }
  }
  // ⚠ 注意：idle 状态下改采样率只是改了字段+通知界面，不发消息（合理：
  // 那时没有会话可更新，下次 enterStandby 会带上最新值）。
  // 这里也没有判 _enabled（禁用态根本进不了 live/standby，所以无副作用）。

  // 下面三个字段被夹在方法之间，是代码"长出来"的痕迹（不影响运行）。
  // 读代码时把它们当普通字段看即可；新写字段建议都放到类顶部。
  bool _needsPermission = false; // 连接了但缺录音权限 → 首页显示"启用"按钮
  // v3.7 国际化：错误存【文案键】而不是中文句子（详见 connection_provider 同款注释）。
  // String? 可空：null = "现在没有错误"，界面据此决定红色提示显不显示。
  // _errorDetail 存原始细节（英文/带 errno），只用于排查、不参与翻译。
  String? _errorKey; // null = 当前无错误
  String? _errorDetail; // 原始细节（如原生错误码），不参与翻译

  // ── v3.6：本设备的功能总闸（"启用/禁用"块控制，值由 DeviceProvider 存本地）──
  // false = 用户明确禁用过手机麦克风：
  //   · 连上电脑不再自动进待命（不登记会话）；
  //   · 就算收到 mic_state:true 也不开硬件；
  //   · 关闭那一刻会主动注销已有会话（发 mic_stop），电脑那边随之再也唤不起。
  // 这是用户要的"唯一手动否决权"——麦克风页不再有静音键，禁用块就是那道闸。
  //
  // 【闸门（gate）为什么这么设计 —— 这是产品要求，不是技术限制】
  // 1. 用户只想要【一个】开关就能彻底关掉这台设备。若"禁用"只是把界面按钮藏起来，
  //    PC 仍可能靠 mic_state 把麦克风唤醒 —— 那就不叫关掉。
  // 2. 所以 _enabled=false 时连上电脑也【不登记会话】：不发 mic_start，
  //    PC 的会话表里根本没有这台手机，它再怎么"用麦克风"也找不到投递对象。
  // 3. 【两道保险】（belt-and-suspenders，故意重复）：
  //    第一道在入口 —— _autoStandby() 第一串卫语句里就查 _enabled，走不进待命；
  //    第二道在执行 —— _openMic() 再查一次 _enabled，绝不碰硬件。
  //    为什么要重复：入口以后会增加（新页面、新指令、定时任务），
  //    第二道是"最后一道墙"，比信任所有调用者安全得多。
  // 4. 持久化（记住用户的选择）不在这个类里做：见 lib/providers/device_provider.dart，
  //    它用 SharedPreferences 存键 device_enabled_mic（前缀 device_enabled_ +
  //    枚举名），重启 App 后仍然生效 —— 否则用户杀一次 App，他的否决就被"遗忘"了。
  //    本类只是"执行者"：账本只有一份，不会出现两处记得不一样。
  bool _enabled = true;

  // ── 电平条数据（界面那根跳动的条）──
  double _level = 0; // 最新一帧响度（0.0~1.0）
  // 0.0~1.0 是 MicService._rms() 算出的"均方根响度"归一化结果
  //（见 mic_service.dart：平方→平均→开方→除以 32768，i16 的最大幅度）。
  // 顺带回答"要不要开 Isolate（Dart 子线程）"：不用。这里每块只有约 1KB，
  // 算一遍 RMS 只要几微秒；而摄像头的 JPEG 压缩是重活，本项目把它放在
  // Android 原生 Camera2 线程里做（CameraEngine.kt），目的和 Isolate 一样 ——
  // 绝不让耗时计算占用画界面的那个线程（否则手机会卡成幻灯片）。
  final List<double> _bars = []; // 电平滚动历史（界面画条形图用）
  int _lastNotifyMs = 0;  // 上次 notifyListeners 的时间戳（节流用）
  // ⚠ 注意：_bars 只留最近 28 帧（见接线 2 的 removeAt(0)）。
  // 28 = 界面画 bar 的个数，"够铺满一行"就停了。改大 = 界面历史更长但每次
  // removeAt(0) 要整体前移（List 头部删除是 O(n)），一秒约 100 次，别放太大。

  /// 构造函数：注入网络服务（和 ConnectionProvider 同款依赖注入套路）
  // 语法点：参数包在 {} 里 = 命名参数（调用方要写 networkService: xxx）；
  // required = 必传，漏了编译器报错；
  // 冒号后面那段 `: _networkService = networkService` 叫【初始化列表】，
  // 它是给 final 字段赋值的唯一时机（final 一进函数体就不能再改）。
  // 谁 new 它：main.dart 里 ChangeNotifierProvider<MicProvider>(create: ...)，
  // 那里用 context.read<NetworkService>() 把服务取出来递进来。
  // 本构造函数的重活是"接线"：把 4 个来源（原生数据、原生响度、连接状态、
  // PC 回执、PC 占用状态）连到本类的逻辑上。接完线它就退休了。
  MicProvider({required NetworkService networkService})
      : _networkService = networkService {
    // 【接线 1：PCM 数据 → WebSocket】
    // 原生每采到一块就回调这里，直接塞进已连接的通道发给 PC。
    // 只有 live（电脑正在用、硬件已开）且没按静音才放行。
    // onData 是 MicService 暴露的"回调槽"（类型 void Function(Uint8List)?），
    // 这里把一个匿名函数（lambda）塞进去 —— 这就是回调/观察者套路：
    // 服务层因此完全不认识 Provider，依赖方向保持单向（服务不该反向依赖业务）。
    // 注意这里没有加头：麦克风上行是【裸 PCM】，第一个字节就是采样值；
    // 而摄像头的 JPEG 帧要加 4 字节魔术头（见 camera_provider.dart 的 _frameMagic），
    // PC 端靠"这条会话现在是 mic 还是 cam"来分流。
    _micService.onData = (bytes) {
      if (_state == MicState.live && !_muted) {
        _networkService.send(bytes); // send 内部有连接才发的保护
        // send 的参数类型是 dynamic（String 和字节数组都能传）：
        // 文本帧发 JSON 控制指令、二进制帧发音频字节，同一个方法搞定。
        // 未连接时它静默丢弃（见 network_service.dart 的 send），
        // 所以这里不必再判 isConnected；断线时 _state 早已被接线 3 清成 idle。
      }
    };
    // ⚠ 注意：这个回调里没有 try/catch，也没有失败计数。
    // 若通道正在关闭的毫秒里 send 抛异常，会被 WebSocket 的 onError 兜住上报，
    // 但这一帧数据就永久丢了（实时音频丢一帧无感，属可接受行为）。
    // 关于"每块多大"：字节块的分块尺寸由原生采集线程的 buffer 决定
    //（见 mic_service.dart，Dart 侧不参与），48kHz 单声道 16bit 约 96KB/s，
    // 一秒约 100 块 → 每块约 1KB。块太小 = WebSocket 包数暴涨、开销大于正文；
    // 块太大 = 端到端延迟增加（对方要等凑满一块才听到）。

    // 【接线 2：响度 → 电平条数据】
    // 原生在转发每块 PCM 时顺手算好 RMS 响度（0.0~1.0）回调这里。
    _micService.onLevel = (lv) {
      _level = _muted ? 0 : lv; // 静音时电平条也归零，视觉一致
      // 三元表达式：条件 ? A : B。用户看不到"硬件已关但条还在跳"的矛盾画面。
      _bars.add(_level);
      if (_bars.length > 28) _bars.removeAt(0); // 只留最近 28 帧
      // 这就是"滚动窗口"：先进新数据，超过上限就扔最旧的。
      // 28 是界面画 bar 的个数；.length 取当前元素数，removeAt(0) 删头部。
      // 节流：音频帧每秒约 100 个，界面 100ms 刷一次（10fps）足够流畅
      final now = DateTime.now().millisecondsSinceEpoch;
      // 取"从 1970-01-01 UTC 起算的毫秒数"（整数）。做减法比构造 DateTime
      // 对象便宜得多 —— 这个回调一秒可能被叫约 100 次，能省则省。
      if (now - _lastNotifyMs >= 100) {
        _lastNotifyMs = now;
        notifyListeners();
      }
    };
    // 为什么要节流（throttle）：不节流就是"一秒重建界面 100 次"，
    // 每次重建都要重新排版绘制 → 手机发烫、掉帧，电平条反而更难看；
    // 100ms(10fps) 是人眼觉得"在动"的舒适点。
    // 改成 16ms(60fps) 是纯浪费（屏幕也画不出那么多），改成 500ms 条就明显结巴。

    // 【接线 3：WebSocket 连上 → 自动进入待命（零操作的核心）】
    // listen((s) {...})：订阅状态流，NetworkService 每广播一个新状态
    // 就调用一次这个匿名函数，参数 s 是 ConnectionStatus 枚举值。
    // 返回值必须存进 _statusSubscription（否则 dispose 时关不掉 → 泄漏）。
    _statusSubscription = _networkService.connectionStatusStream.listen((s) {
      if (s == ConnectionStatus.connected) {
        _autoStandby();
        // 不 await：这是"连上就顺手登记"的后台动作，登记过程中它会自己
        // notifyListeners，界面会自动跟上；回调本身也不是 async 函数。
      } else if (s == ConnectionStatus.disconnected) {
        // 断线：清掉一切（PC 端会话也随之消失）
        // 注意 PC 侧是靠 TCP 断开自己发现会话没了的，手机不能再发 mic_stop。
        _sessionEstablished = false;
        _serverLive = false;
        _muted = false;
        // 只有"确实不在 idle"才做关闭动作：idle 时无事可关，
        // 也不该 notifyListeners（否则每次断线白白重建一次界面）。
        if (_state != MicState.idle) {
          _micService.stop();          // 硬件若开着，关掉
          _micService.stopStandbyService();
          _state = MicState.idle;
          _bars.clear();
          notifyListeners();
        }
      }
    });
    // ⚠ 注意：这里没有 else 分支处理 ConnectionStatus.error / connecting。
    // NetworkService 连接失败时先广播 error（而非 disconnected），
    // 所以"连接失败"不会走到上面的清理逻辑。当前是安全的（此时本就是 idle），
    // 但若将来在 connected 之外还挂别的资源，error 会漏清理。未改代码。
    // ⚠ 另外：_micService.stop()/stopStandbyService() 在这里没 await
    //（回调不是 async）—— 原生停采集是"发出去就返回"，
    // 所以 notifyListeners 可能先于"硬件真的关掉"完成。表现几乎不可见。

    // 【接线 4：PC 回执 → 确认会话登记完成】
    // mic_ack 若带 active=true（连上时电脑已经在用麦克风），
    // network_service 会把它当作一条 mic_state 推给接线 5，这里只管记账。
    // 协议：{"type":"mic_ack","active":true/false} —— PC 对 mic_start 的回执。
    // 参数写成 (_) 表示"这个值我用不上"（内容固定是字符串 'mic_ack'）。
    _ackSubscription = _networkService.micAckStream.listen((_) {
      _sessionEstablished = true;
      notifyListeners();
    });
    // ⚠ 注意：没有"mic_ack 超时"兜底。若这条回执丢了，_sessionEstablished
    // 会一直停在 false，导致 stop() 时不发 mic_stop（PC 那边要等 TCP 断开才清会话），
    // 且界面 hasSession 仍为 false。项目里 Dart 侧没有任何 Timer/心跳
    //（超时判定都在 PC 端 Rust 里），要不要补一个等 ack 的 Timer 由你定。

    // 【接线 5：PC 占用状态 → 驱动麦克风硬件开/关（v3.3 的核心开关）】
    // 单独抽成一个方法只为让构造函数短一点；它没有返回值，
    // 订阅句柄没有被保存（见字段区的 ⚠ 说明）。
    _micStateListener();
  }

  /// 监听服务器推来的 mic_state：这是"电脑用/停"的权威信号，
  /// 直接决定手机麦克风硬件开还是关。
  // 协议：PC 端约每 250ms 轮询一次"WASAPI 会话里有没有应用正在录 CABLE Output"，
  // 结论变化时推 {"type":"mic_state","active":true/false}（谁发的：PC 的 Rust 服务）。
  // network_service.dart 解析出 active（并 `is bool` 判类型）后往
  // micStateStream（Stream<bool>）广播，本方法订阅它。
  // 收到后走哪个分支：true → 可能 _openMic()；false → 可能 _closeMic()。
  // 这就是"电脑开始用我才录、电脑停我立马停"的落地机制，
  // 也是本文件唯一的"由外部驱动硬件"入口。
  void _micStateListener() {
    _networkService.micStateStream.listen((active) {
      if (_serverLive == active) return; // 状态没变，什么都不做
      // 这叫【去重】(dedupe)：PC 会周期性重发同一个结论，
      // 不去重就会每次都 notifyListeners（白重建界面），
      // 更糟的是可能重复调用 _openMic（虽有幂等保护，但没必要冒险）。
      // 也正因为依赖"和上次不一样"，enterStandby 时才要用 _serverLive 做兜底同步。
      _serverLive = active;

      if (active) {
        // 电脑开始用麦克风 → 若我在待命且没按静音，立刻开麦
        // 注意这里【没有】判 _enabled：闸门由 _openMic 内部第二道保险把关。
        // 禁用态下本类根本进不了 standby（_autoStandby 有第一道闸门），
        // 所以这里的条件天然不成立；真有 cam/mic_state 到来也只是刷新文案。
        if (_state == MicState.standby && !_muted) {
          // 不 await：开硬件是后台动作，_openMic 完成后自己通知界面
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
  // 这一片全是"只读属性"：`bool get isLive => ...;`
  // 界面写 provider.isLive（没有括号），内部其实就是调了一个方法。
  // 为什么字段私有、只给 getter：外部若能 `provider.state = ...` 随便写，
  // 就绕过了 notifyListeners() 和硬件善后，界面会与真实情况脱节。
  // 下面 isLive/isStandby/isBusy 是【派生状态】（从 _state 现场算出来的），
  // 不是另存一份数据 —— 好处是永远不会和 _state 不一致，
  // 界面写 provider.isLive 也比 provider.state == MicState.live 干净。
  MicState get state => _state;
  bool get isLive => _state == MicState.live;
  bool get isStandby => _state == MicState.standby;
  bool get isBusy => _state == MicState.starting;
  bool get isMuted => _muted;           // 静音键是否按下
  bool get serverLive => _serverLive;   // 电脑是否有应用正在录 CABLE Output
  bool get needsPermission => _needsPermission; // 首页据此显示"启用麦克风"
  bool get hasSession => _sessionEstablished;
  // 这几个 getter 就是 DeviceProvider 的输入：它读 isLive/isStandby
  // 去算界面五档状态词（见 lib/providers/device_provider.dart 的 statusOf）。

  /// 记录/清除一条错误。只存文案键（+ 可选细节），句子由界面翻译。
  // 语法点：参数包在 [] 里 = 【可选位置参数】，调用时可省略：
  //   _setError('errMicDenied')          → detail 为 null
  //   _setError('errMicStart', code)     → 带上原始错误码
  // 传 null 当参数就是"清除错误"（_errorKey 回到 null，界面红字消失）。
  void _setError(String? key, [String? detail]) {
    _errorKey = key;
    _errorDetail = detail;
  }
  // ⚠ 注意：_setError 只写字段、不调 notifyListeners（它定位是"内部小工具"，
  // 由调用方的方法末尾统一通知）。将来新增调用点若忘了通知，
  // 错误文字就不会显示到界面上 —— 本类里 _setError 与 notifyListeners
  // 总是一对一出现的，新代码要保持这个习惯。

  /// 当前错误的人话版本（v3.7 国际化）；null = 没有错误。
  // switch 表达式（Dart 3 语法）：`return switch (x) { 值 => 结果, ... };`
  // 与老式 switch 语句的区别：它【有返回值】，每分支一行 `=>`，
  // 不需要 break，也不会"穿透"到下一分支。
  // 最后一行 `_ => ...` 是 default（下划线 = 其余全部）：
  // 万一新加的文案键忘了登记，至少把原始细节显示出来，
  // 不会出现"界面上一片空白"那种更难查的情况。
  // ?? 是空合并：左边为 null 就用右边兜底 —— _errorDetail 是 String?，
  // 而 l10n.errMicStart 要求非空 String，必须 ?? '' 才过编译（新手常见坑）。
  String? errorOf(AppLocalizations l10n) {
    final key = _errorKey;
    if (key == null) return null;
    // 卫语句（guard clause）：先把"没错误"这种常见情况提前返回，
    // 下面的代码就不用多套一层 if，缩进更浅、读起来更直。
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
  // List.unmodifiable：包一层"只读视图"。界面拿到手改不了（改了抛异常），
  // 于是不会出现"界面自己往历史里塞数据"这种把状态搞脏的写法。
  // 注意它不是拷贝，仍会随 _bars 变化 —— 但界面每次重建都会重新读，没问题。

  /// 状态对应的人话文案（详情页大字用）。
  ///
  /// v3.7 国际化：原来是硬编码中文的 getter，现在改成收 AppLocalizations 的
  /// 方法。命名上带 `Of` 后缀 = "要传文案表才能拿到句子"。
  /// （目前界面自己拼了大字，这两个方法是留给设备页统一改造时用的，
  ///   保留而不删除，是为了不丢掉这里已经写清楚的优先级判断。）
  // 优先级顺序是刻意的：禁用压过一切 —— 闸都拉下了，别的话都不成立。
  // switch 语句 + enum：Dart 要求对枚举【穷举】（4 个 case 都得写，少一个编译报错）。
  // 每个 case 都以 return 结尾，所以不会"穿透"到下一个 case（也不用写 break）。
  // 界面五档状态词（已禁用/未连接/待授权/待命/使用中）的完整翻译在
  // lib/providers/device_provider.dart 的 statusLabelOf，两处措辞要对齐。
  String statusTextOf(AppLocalizations l10n) {
    // v3.6：禁用优先于一切状态 —— 功能闸关着时，别的话都不成立
    if (!_enabled) return l10n.micStatusDisabled;
    switch (_state) {
      case MicState.idle:
        // 跨行三元表达式：条件写在第一行，? A : B 换行继续 ——
        // Dart 允许表达式跨行，只要每行末尾不是分号。
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
  // 同一个状态在两个位置有两套话术：详情页说长句（解释原理），
  // 开关下面说短句（一眼扫过）。两处都跟着 _muted 变，别漏。
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
  // 这一段是麦克风与摄像头的最大差别：麦克风连上就自己登记（用户不用点），
  // 摄像头必须用户点头（见 camera_provider.dart 的双入口设计）。

  /// 连接成功后的自动进入待命。
  /// 静默检查权限：没有权限不弹扰窗，只置 needsPermission，
  /// 由首页"启用麦克风"按钮让用户主动点一次（符合 Android 权限规范）。
  // 为什么"静默查"很重要：Android 的权限规范是"用到之前不要突然弹窗"。
  // 连接成功的时刻用户并没打算录音，这时弹"允许录音吗"很吓人；
  // 而且被拒绝过一次后再弹，系统会直接静默拒绝（永久变黑名单），更难挽回。
  // 所以这里用 hasPermission()（只问不弹），缺权限就只点亮界面上的"启用"按钮，
  // 等用户主动点按钮时才用 ensurePermission() 弹系统窗。
  Future<void> _autoStandby() async {
    // 三条卫语句 = 本方法的【闸门一】，顺序有讲究：
    if (_state != MicState.idle) return; // 已在待命/工作中，幂等
    //   ① 幂等：断线重连、setEnabled、别处再触发一次都不会重复登记；
    if (!_networkService.isConnected) return;
    //   ② 没连上就发登记帧没人收，白做一次；
    if (!_enabled) return; // v3.6：设备被禁用 → 连上也不登记、不待命
    //   ③ 闸门：禁用时连上电脑也【不进会话登记】—— PC 的表里没这台手机，
    //      于是它永远唤不起麦克风。这正是"用户只能用一个总开关关掉设备"的产品要求。
    //      第二道保险在 _openMic() 里（同样判 _enabled），两处是故意的重复。

    if (!await _micService.hasPermission()) {
      // await：这一步要等平台通道（原生）回答"有没有权限"，
      // 函数在这里暂停，但不阻塞界面 —— Dart 事件循环会去处理别的事。
      _needsPermission = true;
      notifyListeners();
      return;
    }
    _needsPermission = false;
    await enterStandby();
  }

  /// 进入待命：挂前台守护服务 + 向服务器登记会话。
  /// 注意：这里【不】打开麦克风硬件 —— 那是 mic_state 信号的事。
  // "登记"就是让 PC 知道"这台手机可以做麦克风，需要时叫我一声"。
  // 硬件关着 = 状态栏没有录音小绿点、不耗电，这正是本项目的核心卖点。
  Future<void> enterStandby() async {
    if (_state != MicState.idle) return;
    // 没连接就失败退出：这条路径是【用户主动点的】（toggle/setEnabled），
    // 所以必须给反馈 —— 记错误键 + 通知界面，和 _autoStandby 的静默 return 不同。
    if (!_networkService.isConnected) {
      _setError('errConnectFirst');
      notifyListeners();
      return;
    }

    _state = MicState.starting; // 借"启动中"闪一下，表示正在登记
    _setError(null);
    _needsPermission = false;
    notifyListeners();
    // 上面四行是"开始做一件要等一会儿的事"的标准三部曲：
    // 置瞬时态 → 清旧错误 → 立即通知界面。少了第三步，按钮会像"点了没反应"。

    // 守护前台服务：息屏后进程不被杀，服务器的唤醒指令才能随时送达
    // Android 为省电会杀后台进程；前台服务 = 挂一条常驻通知声明"我在干正事"。
    // 它本身【不开麦克风】，省电靠的仍是"电脑用到才开采集"。
    // 内部已 try/catch 住"通知权限被拒"（见 mic_service.dart），
    // 所以这里的 await 不会抛异常，最坏结果只是息屏后唤醒不稳。
    await _micService.startStandbyService();

    // 登记会话：告诉 AudioServer "我上线了，需要我时推 mic_state 唤醒"
    // 协议：文本帧 JSON，字段含义 ——
    //   type='mic_start'（PC 据此分派"登记手机麦克风会话"）
    //   sample_rate（当前采样率，决定 PC 是否要重采样）
    //   channels=1（单声道：语音够用、带宽减半；改 2 数据翻倍且 PC 注入引擎按单声道设计）
    //   format='pcm_s16le'（裸 PCM、样本 16 位有符号、小端序；不压缩以省 CPU 和延迟）
    // PC 收到会回 {"type":"mic_ack",...}，由接线 4 记账。
    // send 是同步的"发完就走"，不 await 回执。
    _networkService.send(jsonEncode({
      'type': 'mic_start',
      'sample_rate': _sampleRate, // v3.4.4：跟随用户选择（默认 48000）
      'channels': 1,
      'format': 'pcm_s16le',
    }));

    _state = MicState.standby;
    // 若登记瞬间电脑已经在用（mic_ack 会带 active=true，随后由接线 5 处理），
    // 这里做一次兜底同步：_serverLive 已被置 true 就直接开麦
    // 为什么需要兜底：ack 可能在这次 await 期间就已经到达并更新了 _serverLive，
    // 那时接线 5 因为 _state 还是 starting 而没开麦（见它的条件判断），
    // 所以这里补一次检查，避免"电脑在用、手机却待命"的卡死。
    if (_serverLive && !_muted) {
      await _openMic();
    } else {
      notifyListeners();
    }
  }
  // ⚠ 注意：enterStandby() 没有判 _enabled（闸门一只写在 _autoStandby 里）。
  // 公开方法 toggle() 的启用分支会【直接】调它，所以若界面在"已禁用"状态下
  // 仍调到 toggle()，就会绕过闸门登记会话（_openMic 的第二道保险仍能阻止开硬件，
  // 但会白挂一次前台通知、白登记一次会话）。
  // CameraProvider 的对应方法 _enterStandbyInternal() 是有这道判断的 ——
  // 两边不对称。要不要给 enterStandby 补一条 `if (!_enabled) return;` 由你定，
  // 代码未改。

  /// 打开麦克风硬件并开始上行（只在电脑正在用 & 未静音时被调用）
  // 这是"按需录音"落地的唯一开硬件入口，也是【闸门第二道保险】所在：
  // 上面三个调用点（接线 5、enterStandby、setSampleRate、toggleMute）
  // 都没有判 _enabled，全靠这里这一行守住"禁用=绝不录音"的最后底线。
  // 两层检查不是冗余：入口拦的是"不该开始的事"，
  // 执行拦的是"万一将来有人新增了调用点"。安全相关的分支宁可重复。
  Future<void> _openMic() async {
    // 幂等卫语句：已经在录音 / 正在开的过程中就直接退出。
    // 少了它会怎样：mic_state 连着来两次 true 时开两次 AudioRecord，
    // 第二次必然失败（设备被占用），还会白白重启一次采集线程。
    if (_state == MicState.live || _state == MicState.starting) return;
    if (!_enabled) return; // v3.6：双保险 —— 禁用状态下绝不开硬件
    _state = MicState.starting;
    notifyListeners();

    // 权限兜底（正常流程 _autoStandby 已确认；这里防系统撤销权限的极端情况）
    // 用户确实能在"设置"里事后关掉权限，Android 也可能在长期不用后回收。
    // ensurePermission 是会【弹系统窗】的版本 —— 此刻是"电脑正在用"的场景，
    // 弹一次窗是合理的（用户已知自己在开麦克风）。
    if (!await _micService.ensurePermission()) {
      _state = MicState.standby;
      _needsPermission = true;
      _setError('errMicPermission');
      notifyListeners();
      return;
    }

    // 开原生采集（采样率跟随用户选择，单声道；44.1k 时服务器自动重采样）
    // 命名参数写法：sampleRate: / channels: 让调用点自解释（比 start(48000, 1) 清楚）。
    // 返回值约定（原生侧同规则）：Future<String?> —— null = 成功，
    // 非 null = 错误码字符串。这是"用返回值而不是抛异常"表达失败，
    // 好处是调用方必须去看结果（异常容易被忘记接住）。
    // 所以整个方法没有 try/catch；也不需要 finally（没有"无论成败都要收尾"的资源）。
    final error = await _micService.start(
        sampleRate: _sampleRate, channels: 1);
    if (error != null) {
      // 失败退回 standby 而不是 idle：会话还在册，电脑下次说"我要用"还能再试，
      // 用户不必重新点一遍开关；错误只作为提示显示，不摧毁整个功能。
      _state = MicState.standby; // 开麦失败退回待命，等下一次唤醒再试
      _reportNativeError(error);
      notifyListeners();
      return;
    }

    _state = MicState.live;
    _setError(null);
    // 到这里才算真的"电脑开始用麦克风"（电脑在用时手机才有录音小绿点）。
    // 状态栏绿点由 Android 系统自己显示，App 关不掉 —— 这也是本设计的透明性：
    // 只有在真的录音时才可能亮。
    notifyListeners();
  }
  // ⚠ 注意：这里没有"打开失败自动重试"。一次失败就安静退回待命，
  // 下一次唤醒（电脑再次开始用）才会重试；期间如果电脑一直开着麦克风，
  // 就不会再推新的 mic_state，于是手机会停在待命直到别的信号到来。

  /// 关闭麦克风硬件，回到待命（电脑停用 / 用户按静音 都会走到这里）
  // 为什么不清 _sessionEstablished：登记仍然有效（PC 那边还认这台手机），
  // 下次 mic_state:true 可以直接开麦，不必重新发一遍 mic_start。
  Future<void> _closeMic() async {
    await _micService.stop();
    _bars.clear();
    _level = 0;
    // 这行的写法值得学：idle 是"彻底关闭"，不该被降级成 standby，
    // 所以要加条件；其它态（live/starting）都回 standby。
    if (_state != MicState.idle) _state = MicState.standby;
    notifyListeners();
  }

  /// 手动静音键：通话软件式闭麦 ——
  /// v3.3 语义升级：按下 = 【真的关掉麦克风硬件】（隐私最彻底），
  /// 会话保持登记；再按一次：若电脑正在用则立刻重新开麦，否则安静待命。
  // 界面写法参见 lib/screens/mic_screen.dart：provider.isMuted 决定图标，
  // onPressed 一律调这个方法（按钮自己不知道现在是开还是关，判断在这里）。
  // 和"禁用总闸"的区别：静音是临时闭嘴、会话还在，电脑那边仍看得见这台手机；
  // 禁用是把这台设备从电脑的会话表里彻底摘掉。
  Future<void> toggleMute() async {
    // ! 是逻辑非：true 变 false、false 变 true —— 一行翻转开关
    _muted = !_muted;
    if (_networkService.isConnected && _sessionEstablished) {
      // 协议：告诉 PC 一声，让它同步"丢弃/恢复注入"并清掉缓冲区残留尾音。
      // 不发这条会怎样：手机已经闭麦，但 PC 的注入引擎里还留着上一刻的音频，
      // 对方会听到一小段"尾巴音"；type='mic_mute' + muted 布尔。
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
        // 本来就在待命：硬件关着，只需刷新文案（"已静音"）
        notifyListeners();
      }
    } else {
      // 解除静音：电脑正在用则马上恢复采集，否则等下一次 mic_state
      // 只有【两个条件同时成立】才开麦，否则安静等着，别为省电白开一次。
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
  // 谁调它：只有 DeviceProvider.setEnabled(PcDevice.mic, on)
  //（见 lib/providers/device_provider.dart）。它的顺序是
  // 【先写 SharedPreferences 再调这里】—— 反过来会留一个窗口期：
  // 动作触发的一连串回调读到还没更新的旧开关值，界面闪一下错误状态。
  // 存的键名是 device_enabled_mic（前缀 device_enabled_ + 枚举名），
  // 为什么要记住：只存内存的话，用户杀一次 App 再打开，
  // 他明确禁用的麦克风又悄悄回到待命态 —— 等于他的否决被系统遗忘了。
  Future<void> setEnabled(bool on) async {
    // 幂等卫语句：值没变就别白折腾一圈（否则会重复注销/重复登记）
    if (_enabled == on) return;
    _enabled = on;
    if (!on) {
      await stop(); // 注销 + 关硬件 + 撤守护通知
    } else if (_networkService.isConnected) {
      // 重新启用：只有在"已经连着电脑"时才马上回待命；
      // 没连着就只把闸门打开，等接线 3 收到 connected 时自然登记。
      await _autoStandby();
    }
    notifyListeners();
  }

  bool get enabled => _enabled;

  /// 首页主按钮 / 详情页大按钮统一入口：启用待命 or 彻底关闭
  // 界面只写 onPressed: () => provider.toggle()（参见 home_screen.dart），
  // "现在该启用还是该关闭"由这里看 _state 判断 —— 界面不自己记状态，
  // 就不会出现"按钮显示的和实际不一致"的经典 bug。
  Future<void> toggle() async {
    if (_state != MicState.idle) {
      // 分支 A：已在跑（standby/starting/live）→ 这次点击是"彻底关闭"
      await stop();
    } else {
      // 手动启用（含权限申请）：先拿权限，再进待命
      // 下面两处是标准的"闸门式失败处理"三件套：
      // 记错误键 → notifyListeners（让红字显示出来）→ return（绝不往下走）。
      // 这里的顺序是"卫语句"风格：先排除不能做的情况，剩下的才是主干。
      if (!_networkService.isConnected) {
        _setError('errConnectFirst');
        notifyListeners();
        return;
      }
      // 这条路径是【用户主动点按钮】，所以可以弹系统授权窗
      //（对比 _autoStandby 的静默 hasPermission）。
      // await 在这里暂停，直到用户在系统弹窗上点了"允许/不允许"。
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
  // ⚠ 注意：toggle() 同样没有判 _enabled，而被它调用的 enterStandby() 也没判
  //（见上面 enterStandby 处的 ⚠）。目前界面在禁用态会把入口灰掉，
  // 但入口一旦增加，禁用就可能被绕过登记会话。要不要加判断由你定，代码未改。

  /// 彻底关闭：注销会话 + 停采集 + 撤守护通知
  // 三个动作合起来才是"彻底"：只关硬件不注销，PC 下次还会推 mic_state
  // 把硬件再开起来；只注销不撤通知，状态栏会留着一条没有意义的常驻通知。
  Future<void> stop() async {
    // 发 mic_stop 的两个前提同时成立才有意义：
    // 还连着（否则没人收）+ 真的登记过（否则 PC 表里没这条会话）。
    if (_networkService.isConnected && _sessionEstablished) {
      // 协议：{"type":"mic_stop"} = "我不再提供麦克风了"，PC 注销该会话，
      // 此后不会再对它推 mic_state。手机→PC 方向没有 forced 之类的字段
      //（摄像头才有 PC→手机的"强制关闭"，见 camera_provider.dart 的接线 6）。
      _networkService.send(jsonEncode({'type': 'mic_stop'}));
    }
    await _micService.stop();
    await _micService.stopStandbyService();
    // 下面这段是"回到出厂账面"：逐个清回初始值。
    // 为什么连 _muted 也要清：用户下次重新启用时应当是全新一次开始，
    // 不能带着上次的静音状态（他会以为还开着，其实被静默静音了）。
    _sessionEstablished = false;
    _serverLive = false;
    _muted = false;
    _state = MicState.idle;
    _bars.clear();
    _level = 0;
    notifyListeners();
  }
  // ⚠ 注意：stop() 不清 _needsPermission，也不清 _errorKey
  //（关闭后仍保留上次的提示）。是否符合预期由你定，代码未改。

  /// 原生错误码 → 记录对应错误。
  ///
  /// v3.7 国际化：以前这里直接返回拼好的中文句子（"麦克风启动失败: $code"），
  /// 现在只登记【文案键】，原始错误码留在 _errorDetail 里给界面填进占位符。
  /// 这样同一段原生逻辑在中/英界面下都能给出正确的人话。
  // 这是一张"原生协议 → 界面文案键"的翻译表，集中一处才好维护。
  // 错误码字符串来自 Android 的 MicEngine（约定见 mic_service.dart 的 start：
  // 成功 success(null)，失败 success("错误码")）。
  // switch 语句 + enum/字符串：Dart 3 的 case 不会穿透，所以不用写 break。
  // default 分支把原始码留在细节里，保证"没见过的新错误码"也能被看见。
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
  // 为什么必须 cancel 订阅：订阅是构造函数里挂的，而 NetworkService 是全局长命
  // 对象 —— 本类销毁后流仍会把事件投递给这个已经没用的对象，
  // 轻则内存泄漏（整个 Provider 连同 MicService 都被引用住），
  // 重则在已销毁对象上继续跑逻辑。?. 是空安全调用：没订阅过就整句跳过。
  // 顺序也是固定套路：先断外部事件源（订阅）→ 再释放内部资源 →
  // 最后 super.dispose()：父类 ChangeNotifier 要清自己的监听者名单，
  // 并且它会标记"本对象已销毁"，之后再 notifyListeners 会直接断言失败。
  @override
  void dispose() {
    _statusSubscription?.cancel();
    _ackSubscription?.cancel();
    // MicService.dispose() 内部就是 stop() + stopStandbyService()
    _micService.dispose();
    super.dispose();
  }
  // ⚠ 注意：本类实际有 3 条订阅（接线 3、4、5），这里只取消了 2 条 ——
  // 接线 5（micStateStream）没存句柄所以取消不了（见字段区的 ⚠）。
  // 另外 dispose 里没调 stop()，所以不会给 PC 发 mic_stop：
  // 靠 _micService.dispose() 关硬件、靠 TCP 断开让 PC 自己清会话。
  // 现状未改，是否要补由你定。
}
