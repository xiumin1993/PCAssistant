// ============================================================================
// mic_screen.dart —— 手机麦克风详情页（v3.6 改版）
// ----------------------------------------------------------------------------
// 界面结构（对应已批准的原型 design/device-pages-v3.6.html 第 ③ 屏）：
//   AppBar：设备名 + 状态胶囊
//   └─ DeviceGate   状态明说块（唯一的否决权入口）
//   └─ 电平区       状态行 + 电平条 + 码率/采样率/声道
//   └─ 参数区       采样率二选一（任何状态都可改）
//   └─ 提示         电脑那头怎么选录音设备
//
// 本轮按用户要求删掉的东西（不要再加回来）：
//   · "静音"按钮 —— 要临时不出声就去拨顶部滑块禁用，或电脑侧不选这个设备；
//   · "后台守护"开关 —— 禁用滑块就是唯一的闸；
//   · 大圆形"启用/停止"按钮 —— 同上。
// 注意：删的是【开关入口】，不是保活的前台服务本身。前台服务现在常驻，
// 否则息屏后系统回收进程，电脑的唤醒指令就再也送不到手机了。
//
// 【产品原则（v3.3 起）· 待命 = 硬件关闭】本页显示的"待命"不是"悄悄听着"：
//   AudioRecord 根本没运行 —— 状态栏无录音小绿点、不耗电、一条字节都不上行
//   （所以下面码率读数就是 0）。常驻的只有前台保活服务和 PC 那条会话登记，
//   电脑真要用麦克风的那一刻才开硬件 —— 这就是 on-demand（按需）设计。
// 【产品规则 · 本页为什么没有静音按钮】v3.6 起，"要这台手机麦克风彻底闭嘴"
//   的唯一否决权入口 = 页首 DeviceGate 那个启用/禁用滑块：拨到禁用 = 注销
//   会话（发 mic_stop），PC 的会话表里再也没有这台手机，它再怎么"用麦克风"
//   也送达不了。MicProvider 里其实仍留着 toggleMute() 方法，但本页刻意不给
//   它做按钮 —— 静音键会造成"是我没在发、还是电脑没在用"的两可状态，
//   两处开关必有一处骗人，所以只留一处说得清的闸（对照：摄像头页保留了
//   "冻结"键，因为它的效果如实可见 —— 画面确实停在最后一帧、预览角标也
//   换成"已冻结"，不会让人猜"到底是电脑没在用还是我没在发"）。
// 【界面五态的词、各由哪个字段驱动】disabled/offline/pendingConsent/
//   standby/active 由 DeviceProvider.statusOf 统一翻译（它读 MicProvider 的
//   isLive/isStandby + ConnectionProvider.isConnected + 总闸开关），出现在
//   AppBar 的 DevicePageTitle 胶囊和页首 DeviceGate 大字上；本页正文的
//   "状态行"只显示四个工作态词（录音中/待命/正在开启/未启用，来自
//   micState* 文案键），由 provider.state（MicState 枚举）驱动。
// 【mic_state 怎么牵动这一页】PC 上的应用开始录虚拟声卡 → PC 检测到并推
//   mic_state{active:true} → MicProvider 此刻才打开手机录音硬件（进 live）
//   → 本页随 notifyListeners 重建，状态行变"录音中"、电平条跳、码率显示约
//   768 kbps；PC 那边关闭 → mic_state{active:false} → 硬件立关回待命 →
//   页面变回"待命"、码率归零。本页自己不"决定"任何状态，只是那条
//   信号链的影子。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/device_provider.dart';
import '../providers/mic_provider.dart';
import '../widgets/device_gate.dart';

// v3.7 国际化：文案表
// AppLocalizations 是 Flutter 的 gen_l10n 工具从 lib/l10n/app_zh.arb /
// app_en.arb 自动生成的：lib/l10n/ 下 app_localizations*.dart 三个文件都是
// 构建产物，绝对不要手改；要改句子请改 .arb 源文件再重新生成。
// 生成的 AppLocalizations.of(context) 内部已经判空写死（带了 !），所以本
// 项目界面里取出后可直接 l10n.xxx 用，不需要在调用处再补一个 !。
import '../l10n/app_localizations.dart';

/// 麦克风模式页。
/// StatelessWidget：会动的数据都住在 MicProvider 里，Consumer 一变就重建整页。
class MicScreen extends StatelessWidget {
  // build(context) 是本页唯一的"画图函数"：读一遍 MicProvider 的此刻状态，
  // 返回此刻该有的界面。电平条跳动、状态词切换、码率归零，没有一样是
  // 谁"手动去改控件"改出来的 —— 全是 provider.notifyListeners() 触发
  // Consumer 重建的结果。StatelessWidget 连 setState 都没有（也没有 State），
  // 想刷新只能靠数据源发通知，这逼着状态必须住在 Provider 里（好纪律）。
  const MicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const DevicePageTitle(device: PcDevice.mic),
        centerTitle: true,
      ),
      // Consumer / context.watch / context.read 三选一，取舍是 Flutter 新手
      // 最容易懵的地方，这里完整讲一次（camera_screen.dart 同款）：
      //   Consumer<MicProvider> —— 本页选它：builder 被包的整棵子树随每次
      //     notifyListeners 重建。本页几乎每行都跟 mic 状态走，整包最省心；
      //   context.watch<T>()   —— 能力相同、粒度更细：只重建调用它的某个
      //     子 widget。若页里只有一小块要跟着变，用 watch 缩小重建范围；
      //   context.read<T>()    —— 只取实例、不建立监听：给按钮回调等一次性
      //     动作用的，在 build 里调用是反模式（provider 包会直接断言报错）。
      // builder 的第二个参数 provider 就是最新 MicProvider 实例，整页读数据
      // 直接 provider.xxx 即可，所以本页不会再出现 watch/read 字样。
      body: Consumer<MicProvider>(
        builder: (context, provider, child) {
          // v3.7：本文件所有给用户看的句子都从 l10n 取
          final l10n = AppLocalizations.of(context);
          final errorText = provider.errorOf(l10n);
          final state = provider.state;
          // 两个布尔 + 一个枚举值，对应状态行的四个词（下面②处嵌套三元就按它们画）：
          //   live → "录音中"（硬件开着，电脑正在用）
          //   standby → "待命"（会话在册但硬件【关】，见页头 on-demand 原则）
          //   starting → "正在开启"（登记/开麦中的瞬时态，通常一闪而过）
          //   idle（含未连接）→ "未启用"
          // 注意页面顶栏胶囊/页首大闸门的五档词是另一套（DeviceProvider 算的，
          // 见 ① 注释）—— 两级显示同读一份字段，不会打架。
          final isLive = state == MicState.live;
          final isStandby = state == MicState.standby;

          // 上行码率（bps）= 采样率 × 声道(1) × 16bit。
          // 只有真的在录音时才非零 —— 待命时硬件是关的，一条字节都不发，
          // 这里显示 0 就是"硬件真没开"的书面证据。
          final kbps = isLive ? (provider.sampleRate * 1 * 16 / 1000) : 0.0;

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ============ ① 状态明说块（启用 / 禁用总闸）============
                  // DeviceGate 是共用 widget（lib/widgets/device_gate.dart），
                  // 它读的是 DeviceProvider 而不是 MicProvider：按五档显示状态词
                  // （对麦克风 = 已禁用/未连接/待授权/待命/录音中），滑块拨动时下发
                  // setEnabled()（关 = 注销会话+关硬件，开 = 回待命）。
                  // pendingConsent 一档对麦克风的含义是"连着电脑但还没拿到
                  // 录音授权"（对摄像头才是"等电脑发请求"），文案在 DeviceProvider 里分开。
                  // 它就是本页唯一的否决权入口（为什么没有别的开关见页头产品规则）。
                  const DeviceGate(device: PcDevice.mic),
                  const SizedBox(height: 20),

                  // ============ ①' 缺权限提示（系统授权，不是功能开关）============
                  // 连上了但从没授权过录音：给一个明确的按钮，用户主动点击
                  // 才弹系统权限窗（符合 Android 规范，不突袭式弹窗）。
                  // 运行时权限的真实链路（本项目【没有】用 permission_handler
                  // 之类的包，是自己经平台通道向 Android 要权限）：
                  //   按下按钮 → provider.toggle() → MicService.ensurePermission()
                  //   → MethodChannel requestMicPermission → Android 弹系统授权窗，
                  //   Dart 侧的 await 一直挂到用户点"允许/拒绝"才返回。
                  // 用户拒绝后界面显示什么：这条琥珀横幅留在原地（needsPermission
                  //   保持 true），下方 ②' 再补一行红色错误文案；页面绝不突袭弹权限窗
                  //   （连上时 _autoStandby 只用静默的 hasPermission 问一次）。
                  // 为什么"刚授权完就要重开一遍硬件流程"：之前那次缺权限的检查
                  //   早就以 PERMISSION_DENIED 失败返回了，系统事后放行不会回头重试
                  //   它 —— 只能重新跑"查权限→登记会话→（若电脑正在用则立刻开麦）"
                  //   的完整链路。所以按钮调的是 toggle() 整个流程，而不是把横幅藏掉。
                  if (provider.needsPermission) ...[
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline,
                              color: Colors.amber.shade800, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(l10n.micNoPermission,
                                style: const TextStyle(
                                    fontSize: 12.5, color: Colors.black87)),
                          ),
                          TextButton(
                            onPressed: () => provider.toggle(),
                            child: Text(l10n.grantPermission),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ============ ② 状态行 + 电平条 ============
                  // 这块的嵌套：Card（圆角白底+阴影的容器）→ Padding（卡片内边距，
                  // Card 自己不带 padding）→ Column（竖排三行：状态行 / 电平条 /
                  // 小字参数行）。为什么不用 ListTile 省事：ListTile 是
                  // "图标+主文+副文+尾件"的单行固定模板，这里是多行多控件的
                  // 复合排版，自己拼 Column 才能完全掌控间距与对齐。
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 状态行：Row 横向排。左边的长状态词包了 Expanded ——
                          // 这是防 RenderFlex 溢出报错的关键：Row 里的子项总宽
                          // 超过可用宽度时 Row 不会滚动也不会自动换行，直接甩
                          // 黄黑条纹溢出错误；Expanded = "剩余宽度都给你"，长文案
                          // 在里面折行。右边的 kbps 是固定短文本，不用包。
                          // 颜色跟着 isLive/isStandby 走：蓝=录音中、绿=待命、灰=其余。
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  isLive
                                      ? l10n.micStateRecording
                                      : (isStandby
                                          ? l10n.micStateStandby
                                          : (state == MicState.starting
                                              ? l10n.micStateStarting
                                              : l10n.micStateOff)),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: isLive
                                        ? const Color(0xFF1565C0)
                                        : (isStandby
                                            ? const Color(0xFF0F8A43)
                                            : Colors.black45),
                                  ),
                                ),
                              ),
                              Text(
                                '${kbps.toStringAsFixed(0)} kbps',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: isLive
                                      ? const Color(0xFF1565C0)
                                      : Colors.black38,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // SizedBox 给 CustomPaint 一个明确宽高——
                          // 画布类组件自己"不占空间"，必须外层限定尺寸。
                          // provider.bars 是 List.unmodifiable 包出的只读快照
                          // （最近 28 帧响度），界面想往里改会直接抛异常 ——
                          // 账本只归 MicProvider，界面永远是读者。
                          // 重绘节奏 = Consumer 重建节奏：MicProvider 对接来的
                          // 响度做了 100ms 节流（一秒最多通知 10 次，音频块
                          // 一秒约 100 个，不节流就会白白重建界面 100 次）；
                          // shouldRepaint 是第二道闸，内容没变连 paint 都跳过。
                          SizedBox(
                            height: 44,
                            child: CustomPaint(
                              painter: _LevelBarsPainter(bars: provider.bars),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(l10n.micUplinkBitrate,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black45)),
                              // micUplinkFormat 带一个 int 占位符：
                              // "16" 这类数字全球通用，所以只把数字交给文案，
                              // "kHz · 单声道/Mono" 由文案表决定。
                              // ~/ 是整除（丢掉小数部分）：48000 ~/ 1000 = 48，
                              // 44100 ~/ 1000 = 44 —— 换算在代码做，单位措辞留给文案。
                              Text(
                                  l10n.micUplinkFormat(provider.sampleRate ~/ 1000),
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black45)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ============ ②' 错误提示（有才显示）============
                  if (errorText != null) ...[
                    Text(
                      errorText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ============ ③ 参数区：采样率（任何状态都能改）============
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l10n.paramsTitle,
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          Text(l10n.micUplinkSampleRate,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54)),
                          const SizedBox(height: 6),
                          // SegmentedButton：两档等宽、天然互斥，比下拉框更直观
                          SegmentedButton<int>(
                            // segments 不再是 const：label 里的文字来自 l10n。
                            // 48 kHz / 44.1 kHz 这些数字与单位两边同字，
                            // 只有"直通 / PC 重采样"这种描述性词要翻。
                            // SegmentedButton<int> 新手解剖：泛型 int = 档位"内部标识"
                            // 的类型（这里直接用采样率数值，不是字符串）；segments
                            // 列每档的 value+label；selected 是 Set（本页单选，故只
                            // 装一个元素）；onSelectionChanged 传 null 即整控件置灰——
                            // 和 camera_screen 的 DropdownButton.onChanged 同一个
                            // "回调为 null = 禁用"套路。48000/44100 写死在此（产品只
                            // 给这两档，AudioRecord 对两者有硬性保证；与 provider 的
                            // sampleRateChoices 常量是同两项，改动要两处对齐）。
                            segments: [
                              ButtonSegment(
                                value: 48000,
                                label: Text(l10n.micRate48,
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                              ButtonSegment(
                                value: 44100,
                                label: Text(l10n.micRate44,
                                    style: const TextStyle(fontSize: 12.5)),
                              ),
                            ],
                            selected: {provider.sampleRate},
                            // 只有"已禁用"才锁参数：禁用时改也没用，改完就是
                            // 一个不会生效的假设置（待命/未连接都允许改）。
                            // "任何状态都能改参数"是本轮改版的设计要求：改参数 = 表达
                            // 意图，待命/未连接只是"还没生效"，不是"不该先预设"——
                            // 等电脑一唤醒手机就直接用新值，用户不必为此手动开一次硬件
                            // （摄像头页的清晰度/镜头/旋转同理，见 camera_screen.dart）。
                            onSelectionChanged: provider.enabled
                                ? (s) => provider.setSampleRate(s.first)
                                : null,
                          ),
                          ParamHint(text: l10n.micParamHint),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ============ ④ 使用提示 ============
                  Text(
                    l10n.micHowToUse,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                          height: 1.6,
                        ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 电平条画刷：把 MicProvider 推来的响度历史画成一排竖条。
///
/// CustomPainter 入门：Flutter 提供的一块"自由画布"，
/// 在 paint() 里可以用 Canvas 这支笔画任何图形。
/// 每帧由 Consumer 重建触发重绘（Provider 100ms 节流刷新）。
class _LevelBarsPainter extends CustomPainter {
  final List<double> bars; // 0.0~1.0 的响度序列，最新的在末尾

  _LevelBarsPainter({required this.bars});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    const barWidth = 7.0; // 竖条宽度（逻辑像素）
    const gap = 3.0; // 条间距
    final step = barWidth + gap;

    // 从右往左画：最右边 = 最新一帧，视觉上"波形向左流动"
    // for (var i = 0; ...)：经典下标循环，bars 是 provider 递来的只读快照，
    // 界面只读不写 —— 数据的账本永远在 MicProvider 那一份。
    for (var i = 0; i < bars.length; i++) {
      // clamp(0.0, 1.0)：把越界数值拉回边界 —— 万一原生报出异常响度，
      // 条形也不会画出画布外（防御性写法，成本为零）。
      final level = bars[i].clamp(0.0, 1.0);
      // 空历史时画 3 像素矮的"基线条"，表示通道活着只是没声音
      final h = level < 0.02
          ? 3.0
          : (level * (size.height - 4)).clamp(4.0, size.height);
      final x = size.width - (i + 1) * step; // 右起第 i 根的位置
      if (x < 0) break; // 画到左边缘就停（历史比画布长）

      // 有声音用主题蓝，静音用浅灰 —— 一眼区分"在听"和"没声"
      paint.color = level < 0.02 ? const Color(0xFFD0DFFF) : const Color(0xFF2563EB);

      // RRect = 圆角矩形；drawRRect 画它
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barWidth, h),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  /// Flutter 靠这个判断"要不要重画"：bars 内容变了才重画。
  /// 这里简单用长度 + 末值近似比较（10fps 刷新，开销可忽略）。
  @override
  bool shouldRepaint(_LevelBarsPainter oldDelegate) {
    if (oldDelegate.bars.length != bars.length) return true;
    if (bars.isEmpty) return false;
    return oldDelegate.bars.last != bars.last;
  }
}
