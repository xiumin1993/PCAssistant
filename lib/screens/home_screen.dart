// ============================================================================
// home_screen.dart —— 首页界面（用户看到的唯一页面）
// ----------------------------------------------------------------------------
// 本文件只负责"画界面"：把 ConnectionProvider 里的状态显示出来，
// 把用户的点击交还给 Provider 处理。界面本身不含任何业务逻辑，
// 这是 Flutter 开发的基本分工：Widget 管显示，Provider 管思考。
//
// Flutter 画界面的基本思路：一切皆 Widget，界面 = 层层嵌套的 Widget 树。
// 阅读嵌套结构的技巧：从最外层往里剥 ——
//   Scaffold（页面骨架）
//     ├─ AppBar（顶部标题栏）
//     └─ body（页面主体）
//         └─ Consumer（数据订阅器：Provider 一变就重建里面的内容）
//             └─ Center（把内容居中）
//                 └─ Padding（四周留白）
//                     └─ Column（垂直排列一组组件：图标/文字/输入框/按钮）
// ============================================================================

import 'dart:math' as math; // sin —— 脉冲红点的呼吸透明度用

import 'package:flutter/material.dart';   // UI 组件库
import 'package:provider/provider.dart';  // Consumer / watch 数据订阅

// 导入状态管理器（界面与逻辑之间的桥梁）
import '../providers/connection_provider.dart';

// 导入麦克风状态管理器：首页的"麦克风守护"开关直接读写它的状态
import '../providers/mic_provider.dart';

// 导入摄像头状态管理器（v3.4）：首页的"摄像头守护"区块与请求横幅
import '../providers/camera_provider.dart';

// 导入麦克风页面。首页只做"入口"，点卡片时通过 Navigator 推入新页面。
import 'mic_screen.dart';

// 导入摄像头页面（v3.4 入口）
import 'camera_screen.dart';

// 导入音频服务：v3.4.2 起首页返回键调用它的 goHome()，
// 让 App"回到桌面后台运行"而不是直接退出。
import '../services/audio_service.dart';

/// 首页。
/// 用 StatelessWidget 就够：所有会变的都住在 Provider 里，
/// 本 Widget 只负责"根据 Provider 当前状态生成界面"。
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // PopScope（v3.4.2）：拦截 Android 系统返回键。
    // canPop: false 表示"别按默认方式退出页面"——首页是路由栈最底层，
    // 默认行为就是直接杀掉整个 App。我们在 onPopInvokedWithResult 里
    // 改成调原生 goHome()：相当于帮你按了一下手机的 Home 键，
    // App 退到桌面后台继续运行（守护前台服务保活，连接不断、推流不停）。
    // 子页面（麦克风/摄像头页）的返回键不受影响，仍是正常的"返回首页"。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // didPop=false 说明系统真的没退出，这里接管按键
          context.read<AudioService>().goHome();
        }
      },
      // Scaffold：页面"脚手架"，提供 Material 页面的标准结构——
      // 顶部栏(appBar)、主体(body)、底部栏、浮动按钮等插槽。
      child: Scaffold(
      // ---------------- 顶部标题栏 ----------------
      appBar: AppBar(
        title: const Text('PC Speaker'), // App 名称
        centerTitle: true,               // 标题居中（默认靠左，iOS 风格差异）
      ),

      // ---------------- 页面主体 ----------------
      // Consumer<ConnectionProvider>：核心！
      // 它做两件事：
      //   1. 从 Provider 仓库中取出 ConnectionProvider 实例；
      //   2. 订阅它的变化 —— 每当逻辑层调用 notifyListeners()，
      //      Consumer 就重新执行下面的 builder，界面自动刷新。
      // 也就是说：这个 builder 会被反复调用很多次（每次状态变化一次），
      // 每次都用"当时最新的数据"重新生成界面。
      //
      // v3.1：下方的"麦克风守护"区块自带 Consumer<MicProvider>，
      // 待命/上行/静音状态变化由那一层单独刷新，互不牵连。
      body: Consumer<ConnectionProvider>(
        // builder 是构建回调：
        //   context —— 当前构建上下文（Widget 在树中的位置）
        //   provider —— 取到的 ConnectionProvider 实例（后面直接用
        //                provider.xxx 读状态，见下方）
        //   child —— 可选的"缓存子树"，这里没用到（不传即为 null）
        builder: (context, provider, child) {
          // Center：把唯一子节点在主轴/交叉轴上都居中
          return Center(
            // SingleChildScrollView：v3.1 新增 ——
            // 首页加了麦克风区块后内容变高，小屏上 Column 会超出屏幕
            // （出现黄黑溢出条纹）。包一层滚动容器，放不下就能滑动。
            child: SingleChildScrollView(
              // padding 放在滚动容器内部：滚到顶/底时内容不会贴死边缘
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ==========================================================
                  // ① 连接状态大图标（喇叭）
                  // ==========================================================
                  // 三元表达式做"状态 → 资源"的映射：
                  //   已连接：实心喇叭 + 主题主色（蓝）
                  //   未连接：空心喇叭 + 灰色描边色
                  // Icons.xxx 是 Flutter 内置的 Material 图标常量库。
                  Icon(
                    provider.isConnected
                        ? Icons.speaker_phone
                        : Icons.speaker_phone_outlined,
                    size: 120, // 字号/尺寸单位是逻辑像素（自动适配屏幕密度）
                    // Theme.of(context)：沿 Widget 树向上找到
                    // MaterialApp 配置的主题对象。
                    // colorScheme：主题配色方案，primary=主色，
                    // outline=次要描边灰。用主题色而非写死颜色，
                    // 亮/暗模式自动切换才不用改这里。
                    color: provider.isConnected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),

                  // SizedBox：占位/间隔组件，制造垂直方向 32 像素的空隙。
                  // Flutter 布局靠组件本身撑开，没有 CSS 的 margin 概念
                  const SizedBox(height: 32),

                  // ==========================================================
                  // ② 主状态文字（大字："已连接" / "未连接"）
                  // ==========================================================
                  Text(
                    provider.isConnected ? '已连接' : '未连接',
                    // textTheme 是主题的"文字样式表"：headlineMedium =
                    // 页面级大标题样式（字号、字重、行高都成套）。
                    // ?. 是因为样式字段可空；copyWith 只覆盖颜色，
                    // 其余字号等属性保持主题原样 —— 局部定制的规范做法。
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: provider.isConnected
                              ? Theme.of(context).colorScheme.primary
                              : null, // null = 不改，用主题默认色
                        ),
                  ),
                  const SizedBox(height: 8),

                  // 副标题：显示更细的状态文案，
                  // 比如"正在连接..." / "正在接收音频流"。
                  // provider.connectionStatus 是 Provider 里的
                  // switch 枚举翻译好的中文，界面拿现成的用。
                  Text(
                    provider.connectionStatus,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline, // 弱化次要信息
                        ),
                    textAlign: TextAlign.center, // 文字过长换行时保持居中
                  ),
                  const SizedBox(height: 48),

                  // ==========================================================
                  // ③ 服务器地址输入框
                  // ==========================================================
                  // SizedBox 固定宽度 300：大屏上 TextField 会被拉到
                  // 全宽，限宽后视觉更聚焦。
                  SizedBox(
                    width: 300,
                    child: TextField(
                      // controller 连接 Provider 持有的文本控制器：
                      //   用户每敲一个字 → 自动存进 controller.text；
                      //   Provider 启动时回填的历史地址 → 立刻显示。
                      // 界面不需要自己管理"输入了什么"。
                      controller: provider.serverAddressController,
                      // InputDecoration：输入框的外观配置（Material 规范）
                      decoration: const InputDecoration(
                        labelText: '电脑服务器地址',       // 悬浮标签
                        hintText: '例如: 192.168.1.100:8080', // 占位提示
                        prefixIcon: Icon(Icons.computer),   // 左侧图标
                        // 带圆角边框的样式（默认是下划线样式）
                        border: OutlineInputBorder(),
                      ),
                      // 已连接时禁止编辑地址（防止改了一半误导）。
                      // enabled=false 会让输入框自动变灰，无需额外样式。
                      enabled: !provider.isConnected,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ==========================================================
                  // ③.5 USB 有线直连快捷键（v3.4.4）
                  // ==========================================================
                  // 点一下把地址填成 127.0.0.1:8080（手机本机回环）。
                  // 前提：USB 线插好 + 电脑执行过 adb reverse（详见 README）。
                  // 走 USB 不占 WiFi、延迟更稳，是对实时性要求高时的首选。
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            provider.isConnected ? null : provider.fillUsbAddress,
                        icon: const Icon(Icons.usb, size: 18),
                        label: const Text('USB 有线直连'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: provider.isConnected
                            ? null
                            : () {
                                // 回到 WiFi 模式：清空地址，让用户填电脑局域网 IP
                                provider.serverAddressController.clear();
                              },
                        icon: const Icon(Icons.wifi, size: 18),
                        label: const Text('清空重填(WiFi)'),
                      ),
                    ],
                  ),
                  const Text(
                    'USB 需先在电脑执行: adb reverse tcp:8080 tcp:8080',
                    style: TextStyle(fontSize: 11, color: Colors.black45),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // ==========================================================
                  // ④ 连接 / 断开 按钮
                  // ==========================================================
                  // SizedBox 固定按钮尺寸 200x50，让点击区域够大、
                  // 视觉稳定（文字变化不会把按钮撑大缩小）。
                  SizedBox(
                    width: 200,
                    height: 50,
                    // FilledButton.icon：Material 3 的实心按钮 + 图标+文字。
                    child: FilledButton.icon(
                      // onPressed 是点击回调。
                      // 传 null 是 Flutter 的"禁用按钮"协议：
                      // 只要 onPressed == null，按钮自动置灰且不可点。
                      // 连接过程中（isLoading）就该禁用，防重复提交。
                      onPressed: provider.isLoading
                          ? null
                          : () => provider.toggleConnection(),
                      // 箭头函数 () => xxx 等价于 () { return xxx; }
                      // 这里点击后调用 Provider 的切换方法，
                      // 界面不做任何判断，逻辑全部在 Provider。

                      // 按钮图标：三态
                      //   加载中 → 转圈进度条（小尺寸 CircularProgressIndicator）
                      //   已连接 → "断链"图标
                      //   未连接 → "链接"图标
                      icon: provider.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,     // 圆环线宽
                                color: Colors.white, // 在蓝色按钮上保持白色
                              ),
                            )
                          : Icon(
                              provider.isConnected
                                  ? Icons.link_off
                                  : Icons.link,
                            ),
                      // 按钮文字同样跟随状态
                      label: Text(
                        provider.isConnected ? '断开连接' : '连接',
                      ),
                    ),
                  ),

                  // ==========================================================
                  // ④' 手机麦克风：状态横幅 + 快速静音 + 总开关 + 详情页入口
                  // ==========================================================
                  // v3.3 按需录音版（零操作）：
                  //   连接成功后 Provider 自动进入【待命】—— 麦克风硬件是关的；
                  //   电脑上的应用一打开麦克风，服务器立刻唤醒手机开始录音，
                  //   电脑一关手机马上停止。本区块只提供三件事：
                  //     1. 状态横幅 —— 蓝灰=待命（没在录）/ 红色=正在录音；
                  //     2. 横幅右侧麦克风图标 —— 通话软件式快速闭麦；
                  //     3. 守护开关 —— 想彻底不让手机录音时关掉它。
                  //   首次连接若缺录音权限，会出现"启用麦克风"按钮（点一次，
                  //   系统弹窗授权，以后不再问）。
                  // Consumer<MicProvider>：再订阅一个 Provider。
                  // 嵌套 Consumer 合法，各订阅各的状态源。
                  const SizedBox(height: 16),
                  Consumer<MicProvider>(
                    builder: (context, mic, _) {
                      // 开关状态：只要不是 idle（即启动中/上行中）就是开
                      final guarded = mic.state != MicState.idle;
                      return Column(
                        children: [
                          // ── 缺权限提示：连接了但还没授权录音 ──
                          // 不自动弹系统权限窗（突兀），而是给一个明确的按钮，
                          // 用户主动点击后才弹一次 —— 授权过后永远不再出现。
                          if (mic.needsPermission) ...[
                            SizedBox(
                              width: 300,
                              height: 48,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade600,
                                ),
                                onPressed: () => mic.toggle(),
                                icon: const Icon(Icons.mic),
                                label: const Text('启用麦克风'),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],

                          // ── v3.3 状态横幅：待命=蓝灰（硬件关），录音=红（硬件开）──
                          // 只要会话存在（待命/启动中/录音中）就显示；
                          // 红色 + 脉冲圆点只在 live（真的在录音）时出现，
                          // 待命时是安静的蓝灰色 —— 颜色和硬件状态严格一致，
                          // 用户扫一眼就知道麦克风开没开。
                          if (mic.state != MicState.idle) ...[
                            Builder(builder: (context) {
                              final recording = mic.state == MicState.live;
                              final muted = mic.isMuted;
                              // 三档配色：录音红 / 静音琥珀 / 待命蓝灰
                              final color = recording
                                  ? Colors.red
                                  : (muted ? Colors.amber : Colors.blueGrey);
                              return Container(
                                width: 300,
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: color.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: color.shade200),
                                ),
                                child: ListTile(
                                  dense: true,
                                  // 录音中才用脉冲动画圆点，待命是静止圆点
                                  leading: recording
                                      ? _PulsingDot(color: color.shade600)
                                      : Icon(
                                          muted
                                              ? Icons.mic_off
                                              : Icons.pause_circle_outline,
                                          color: color.shade600,
                                          size: 22,
                                        ),
                                  title: Text(
                                    recording
                                        ? '电脑正在使用你的麦克风！'
                                        : (muted
                                            ? '已静音 · 电脑听不见你'
                                            : '待命中 · 麦克风已关闭，电脑用到时自动开启'),
                                    style: TextStyle(
                                      color: color.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  // 快速静音按钮：任何会话状态下都可点
                                  trailing: IconButton(
                                    icon: Icon(
                                      muted ? Icons.mic_off : Icons.mic_none,
                                      color: color.shade700,
                                    ),
                                    tooltip: muted ? '取消静音' : '静音',
                                    onPressed: () => mic.toggleMute(),
                                  ),
                                ),
                              );
                            }),
                          ],
                          SizedBox(
                            width: 300,
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: SwitchListTile(
                                // 麦克风硬件图标：开=实心 / 关=带斜杠
                                secondary: Icon(
                                  guarded
                                      ? (mic.state == MicState.live
                                          ? Icons.graphic_eq // 上行中：跳动的波形感
                                          : Icons.mic)
                                      : Icons.mic_off,
                                  color: guarded
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.outline,
                                ),
                                title: const Text('麦克风守护'),
                                // 副标题实时反映细分状态，一眼知道手机在干嘛
                                subtitle: Text(mic.guardianSubtitle),
                                value: guarded,
                                onChanged: (on) {
                                  if (on) {
                                    mic.toggle(); // 手动启用待命（含权限申请）
                                  } else {
                                    mic.stop(); // 彻底注销：关采集 + 撤服务
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 300,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: provider.isConnected
                          // Navigator.push：把新页面"压"进路由栈，
                          // 新页面全屏盖住当前页，返回键/返回按钮可退回。
                          // MaterialPageRoute 是标准的 Material 转场动画。
                          // 注意 MicScreen 不用传任何数据——它内部通过
                          // Consumer<MicProvider> 自己去全局仓库取状态。
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const MicScreen(),
                                ),
                              )
                          : null, // null = 自动置灰禁用
                      icon: const Icon(Icons.tune),
                      label: const Text('麦克风详情 / 电平'),
                    ),
                  ),

                  // ==========================================================
                  // ④'' 手机摄像头（v3.4 双入口 + 按需取景）
                  // ==========================================================
                  // 与麦克风的分工：麦克风连上就自动待命；摄像头更敏感，
                  // 必须用户点过头才登记会话 —— 两个入口都通向"待命"：
                  //   A. 下方"摄像头守护"开关（手机主动）；
                  //   B. PC 点"请求手机开启"→ 这里弹出红色确认横幅。
                  // 待命 = 相机硬件【关】；PC 应用真的打开观看 → cam_state
                  // 唤醒 → 红色 REC 横幅 + 硬件开；观看关 → 立刻熄灭。
                  const SizedBox(height: 24),
                  Consumer<CameraProvider>(
                    builder: (context, cam, _) {
                      final guarded = cam.state != CamState.idle;
                      return Column(
                        children: [
                          // ── PC 请求横幅：等用户"同意 / 忽略" ──
                          if (cam.requestPending)
                            Container(
                              width: 300,
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: Colors.red.shade200),
                              ),
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.videocam,
                                          color: Colors.red.shade600,
                                          size: 22),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '电脑请求使用你的摄像头',
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: () => cam.declineRequest(),
                                        child: const Text('忽略'),
                                      ),
                                      const SizedBox(width: 4),
                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              Colors.red.shade600,
                                        ),
                                        onPressed: () => cam.acceptRequest(),
                                        child: const Text('同意'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                          // ── 缺权限提示 ──
                          if (cam.needsPermission) ...[
                            SizedBox(
                              width: 300,
                              height: 48,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade600,
                                ),
                                onPressed: () => cam.toggle(),
                                icon: const Icon(Icons.videocam),
                                label: const Text('启用摄像头'),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],

                          // ── 状态横幅：待命=蓝灰（硬件关）/ 取景=红（硬件开）──
                          if (cam.state != CamState.idle) ...[
                            Builder(builder: (context) {
                              final live = cam.state == CamState.live;
                              final frozen = cam.isMuted;
                              final color = live
                                  ? Colors.red
                                  : (frozen ? Colors.amber : Colors.blueGrey);
                              return Container(
                                width: 300,
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: color.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: color.shade200),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: live
                                      ? _PulsingDot(color: color.shade600)
                                      : Icon(
                                          frozen
                                              ? Icons.videocam_off
                                              : Icons.pause_circle_outline,
                                          color: color.shade600,
                                          size: 22,
                                        ),
                                  title: Text(
                                    live
                                        ? '电脑正在使用你的摄像头！'
                                        : (frozen
                                            ? '已冻结 · 电脑看到的是静止画面'
                                            : '待命中 · 相机已关闭，电脑观看时自动开启'),
                                    style: TextStyle(
                                      color: color.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  // 快速冻结按钮（通话式闭麦的摄像头版）
                                  trailing: IconButton(
                                    icon: Icon(
                                      frozen
                                          ? Icons.videocam_off
                                          : Icons.videocam,
                                      color: color.shade700,
                                    ),
                                    tooltip: frozen ? '解除冻结' : '冻结画面',
                                    onPressed: () => cam.toggleMute(),
                                  ),
                                ),
                              );
                            }),
                          ],
                          SizedBox(
                            width: 300,
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: SwitchListTile(
                                secondary: Icon(
                                  guarded
                                      ? (cam.state == CamState.live
                                          ? Icons.videocam // 取景中
                                          : Icons.videocam_outlined)
                                      : Icons.videocam_off,
                                  color: guarded
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.outline,
                                ),
                                title: const Text('摄像头守护'),
                                subtitle: Text(cam.guardianSubtitle),
                                value: guarded,
                                onChanged: (on) {
                                  if (on) {
                                    cam.toggle(); // 手动启用待命（含权限申请）
                                  } else {
                                    cam.stop(); // 彻底注销：关相机 + 撤服务
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 300,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: provider.isConnected
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const CameraScreen(),
                                ),
                              )
                          : null,
                      icon: const Icon(Icons.videocam),
                      label: const Text('摄像头详情 / 取景'),
                    ),
                  ),

                  // ==========================================================
                  // ⑤ 错误提示（仅出错时出现）
                  // ==========================================================
                  // if (...) ...[ ... ] 是 Flutter 列表里的标准写法：
                  //   if 条件成立 → 把 ...[ ] 里的组件们展开塞进 children；
                  //   不成立 → 什么都不加。
                  // 替代了"隐藏组件"的思路：不显示就根本不存在，
                  // 不会占位，也不需要 Visibility。
                  if (provider.errorMessage != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      // errorMessage! 的 !：上面已判过非空，
                      // 这里"断言不可能为 null"，让编译器闭嘴
                      provider.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error, // 主题错误色（红）
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
      // child: 的 Scaffold 在这里收尾，外面再闭合 PopScope
      ),
    );
  }
}

// ============================================================================
// _PulsingDot —— 呼吸闪烁的圆点（v3.1 上行状态指示灯）
// ----------------------------------------------------------------------------
// "录制中"的通用视觉语言：像录音棚的红灯一样一明一暗。
// 实现要点（新手三件套）：
//   StatefulWidget —— 组件自己有内部状态（动画进度），需要刷新自己
//   TickerProviderStateMixin —— 给 State 装一个"逐帧闹钟"，
//     AnimationController 靠它每一帧推进数值
//   AnimatedBuilder —— 只重建动画影响这一小块，不牵动整页
// ============================================================================
class _PulsingDot extends StatefulWidget {
  final Color color;

  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900), // 一次呼吸的时长
  )..repeat(reverse: true); // 无限循环：0→1→0→1…（往返播放）

  @override
  void dispose() {
    // 逐帧闹钟必须手动释放，否则离开页面后仍在后台烧 CPU（内存泄漏经典案例）
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // sin 曲线让"明暗变化"比线性更柔和（0.35~1.0 之间呼吸）
        final t = _controller.value * math.pi; // 0..π 正好走半个正弦波
        final opacity = 0.35 + 0.65 * math.sin(t).abs();
        const dotSize = 14.0; // 直径（逻辑像素）
        return Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: opacity),
            shape: BoxShape.circle,
            // 外发光圈：同色半透明放大一圈，模拟"亮灯的光晕"
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: opacity * 0.35),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        );
      },
    );
  }
}
