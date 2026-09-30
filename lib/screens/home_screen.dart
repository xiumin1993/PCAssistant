// ============================================================================
// home_screen.dart —— 首页（v3.6 改版：连接区 + 三设备入口）
// ----------------------------------------------------------------------------
// 本文件只负责"画界面"：把各个 Provider 里的状态显示出来，
// 把用户的点击交还给 Provider 处理。界面本身不含业务逻辑，
// 这是 Flutter 开发的基本分工：Widget 管显示，Provider 管思考。
//
// v3.6 的结构（对应 design/device-pages-v3.6.html 里批准的原型）：
//   Scaffold
//     ├─ AppBar('PC Assistant')
//     └─ body
//         └─ Consumer<ConnectionProvider>
//             └─ SingleChildScrollView
//                 └─ Column
//                     ├─ _ConnectionHero   连接大图标 + 大字状态（连接器图标）
//                     ├─ _ModeTabs         WiFi / USB / 蓝牙 三个 Tab（各自上色）
//                     ├─ _AddressArea      当前 Tab 对应的输入区
//                     ├─ _ConnectButton    唯一的连接动作入口
//                     ├─ _ConsentBanner    电脑请求用摄像头时的"同意/忽略"横幅
//                     └─ _DeviceCard ×3    音响 / 麦克风 / 摄像头 详情页入口
//
// 阅读嵌套结构的技巧：从最外层往里剥，一层只做一件事。
// ============================================================================

import 'dart:io' show Platform; // Platform.isAndroid/isIOS —— 平台差异显隐用
import 'dart:math' as math; // sin —— 脉冲圆点的呼吸透明度用

import 'package:flutter/material.dart';   // UI 组件库
import 'package:provider/provider.dart';  // Consumer / read 数据订阅

// 连接状态管理器：三个 Tab 的颜色、连接按钮的文案都读它
import '../providers/connection_provider.dart';

// 网络状态枚举（ConnectionStatus）定义在这里，Tab 上色要用它做 switch
import '../services/network_service.dart';

// 摄像头状态管理器：首页只保留"电脑请求使用摄像头"的确认横幅
import '../providers/camera_provider.dart';

// 三设备总闸 + 状态账本（首页入口卡的状态词全部读它）
import '../providers/device_provider.dart';

// 三个设备详情页。首页只做"入口"，点卡片时通过 Navigator 推入新页面。
import 'camera_screen.dart';
import 'mic_screen.dart';
import 'speaker_screen.dart';

// 音频服务：v3.4.2 起首页返回键调用它的 goHome()，
// 让 App"回到桌面后台运行"而不是直接退出。
import '../services/audio_service.dart';

// v3.7 国际化：文案表 + 语言选择弹层（AppBar 右上角那个按钮打开它）
import '../l10n/app_localizations.dart';
import '../widgets/language_sheet.dart';

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
    // 子页面（三台设备的详情页）的返回键不受影响，仍是正常的"返回首页"。
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
          // 标题走文案表：appTitle 在两套语言里都写作 "PC Assistant"（品牌名不译），
          // 但保留成 key 是为了将来真要本地化时只改 arb。
          title: Text(AppLocalizations.of(context).appTitle),
          centerTitle: true, // 标题居中（默认靠左，iOS 风格差异）
          // 右上角"语言"入口：点开底部弹层选 跟随系统 / English / 简体中文。
          // 放 AppBar 而不是塞进某个设备页，是因为它是【全局】设置，
          // 和具体哪台设备无关。
          actions: [
            IconButton(
              // tooltip 是长按/悬停提示，也是读屏软件念出来的名字（无障碍必给）
              tooltip: AppLocalizations.of(context).languageTitle,
              icon: const Icon(Icons.language),
              onPressed: () => showLanguageSheet(context),
            ),
          ],
        ),

        // ---------------- 页面主体 ----------------
        // Consumer<ConnectionProvider>：核心！
        // 它做两件事：
        //   1. 从 Provider 仓库中取出 ConnectionProvider 实例；
        //   2. 订阅它的变化 —— 每当逻辑层调用 notifyListeners()，
        //      Consumer 就重新执行下面的 builder，界面自动刷新。
        body: Consumer<ConnectionProvider>(
          // builder 是构建回调：
          //   context —— 当前构建上下文（Widget 在树中的位置）
          //   provider —— 取到的 ConnectionProvider 实例（下称 conn）
          //   child     —— 可选的"缓存子树"，这里没用到（不传即为 null）
          builder: (context, conn, child) {
            // v3.7：界面层取文案表。下面所有给用户看的句子都从 l10n 走，
            // 需要 Provider 帮忙成句时，就把 l10n 当参数传进去。
            final l10n = AppLocalizations.of(context);
            // 错误先取成局部变量：判空和显示要用两次，
            // 避免调用两次 errorOf 时中间状态变了（理论上不会，但写法更稳）。
            final errorText = conn.errorOf(l10n);
            // Center：把唯一子节点在主轴/交叉轴上都居中
            return Center(
              // SingleChildScrollView：内容变高后小屏不会溢出（黄黑条纹），
              // 放不下就能滑动。
              child: SingleChildScrollView(
                // padding 放在滚动容器内部：滚到顶/底时内容不会贴死边缘
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ==========================================================
                    // ① 连接状态区（大图标 + 大字 + 副标题）
                    // ==========================================================
                    _ConnectionHero(conn: conn),
                    const SizedBox(height: 24),

                    // ==========================================================
                    // ② 连接方式三 Tab：WiFi / USB / 蓝牙
                    // ==========================================================
                    // 用户明确要求的语义：切 Tab 只是"换一栏来看"，
                    // 绝不断开、也绝不发起连接。上色规则：
                    //   该模式正连着 → 绿色 + 对勾
                    //   该模式上次连失败 → 红色 + 感叹号
                    //   其余 → 灰色
                    // 这套规则的数据来源是 conn.statusOf(mode)。
                    _ModeTabs(conn: conn),
                    const SizedBox(height: 16),

                    // ==========================================================
                    // ③ 当前 Tab 的地址输入区
                    // ==========================================================
                    // WiFi：完整 IP:端口
                    // USB ：固定 127.0.0.1 + 只填端口
                    // 蓝牙：占位说明（本版不做实现）
                    _AddressArea(conn: conn),
                    const SizedBox(height: 16),

                    // ==========================================================
                    // ④ 连接 / 断开 按钮（唯一会改变连接状态的地方）
                    // ==========================================================
                    _ConnectButton(conn: conn),

                    // ==========================================================
                    // ⑤ 错误提示（仅出错时出现）
                    // ==========================================================
                    // if (...) ...[ ... ] 是 Dart 列表里的"条件展开"写法：
                    //   条件成立 → 把 ...[ ] 里的组件们塞进 children；
                    //   不成立 → 什么都不加（不占位，也不需要 Visibility）。
                    if (errorText != null) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          // errorText 已经是当前语言的人话句子，
                          // 不再是 Provider 里存的原始中文串（v3.7 改造点）。
                          errorText,
                          // 原始异常可能很长（带 errno、随机端口等），
                          // 限两行 + 省略号：看得见、又不把首页撑变形。
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],

                    const SizedBox(height: 28),

                    // ==========================================================
                    // ⑥ 摄像头授权横幅（电脑主动请求时才出现）
                    // ==========================================================
                    // 长期否决权在设备详情页的总闸（拨到禁用连横幅都不弹）；
                    // 这里的"忽略/同意"是一次会话的否决权，两者分工不同。
                    const _ConsentBanner(),

                    // ==========================================================
                    // ⑦ 三台设备的入口卡：音响 / 麦克风 / 摄像头
                    // ==========================================================
                    // 蓝牙模式暂时无摄像头通路（原型里明确要求隐藏该卡）。
                    Consumer<DeviceProvider>(
                      builder: (context, dev, _) {
                        return Column(
                          children: [
                            for (final d in PcDevice.values)
                              // 蓝牙 Tab 下跳过摄像头卡片
                              if (!(conn.connectionMode ==
                                      ConnectionMode.bluetooth &&
                                  d == PcDevice.camera))
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: _DeviceCard(device: d),
                                ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// _ConnectionHero —— 顶部大图标 + 主状态文字
// ----------------------------------------------------------------------------
// v3.6 的两点改动：
//   1. 图标从"喇叭"换成"连接器（cable）"——首页管的是连接，不是某一台设备；
//   2. 删掉"当前模式：WiFi"这类重复文案，模式信息已经由下面的 Tab 表达了。
// ============================================================================
class _ConnectionHero extends StatelessWidget {
  final ConnectionProvider conn;

  const _ConnectionHero({required this.conn});

  /// 状态 → 颜色。注意读的是 currentModeStatus（当前 Tab 自己的状态），
  /// 不是全局 isConnected，这样"WiFi 连着、人在 USB 页"时大字说的是 USB，
  /// 和 Tab 颜色严格一致，不会自相矛盾。
  Color _colorFor(BuildContext context, ConnectionStatus s) {
    switch (s) {
      case ConnectionStatus.connected:
        return const Color(0xFF0F8A43); // 绿：已连接
      case ConnectionStatus.connecting:
        return const Color(0xFF1565C0); // 蓝：正在连
      case ConnectionStatus.error:
        return const Color(0xFFC62828); // 红：连接失败
      case ConnectionStatus.disconnected:
        return Theme.of(context).colorScheme.outline; // 灰：没连
    }
  }

  /// 状态 → 大字文案。
  /// v3.7：改成收 l10n 的实例方法（原来是返回硬编码中文的普通方法）。
  String _textFor(AppLocalizations l10n, ConnectionStatus s) {
    switch (s) {
      case ConnectionStatus.connected:
        return l10n.heroConnected;
      case ConnectionStatus.connecting:
        return l10n.heroConnecting;
      case ConnectionStatus.error:
        return l10n.heroConnectFailed;
      case ConnectionStatus.disconnected:
        return l10n.heroNotConnected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = conn.currentModeStatus;
    final color = _colorFor(context, s);

    return Column(
      children: [
        // Icons.cable：网线/连接器图标，正好表达"手机↔电脑之间的链路"。
        // Icons.xxx 是 Flutter 内置的 Material 图标常量库。
        Icon(Icons.cable, size: 96, color: color),
        const SizedBox(height: 12),

        // 大字状态。textTheme.headlineMedium = 页面级大标题样式；
        // copyWith 只覆盖颜色，字号字重保持主题原样 —— 局部定制的规范做法。
        Text(
          _textFor(l10n, s),
          style: Theme.of(context)
              .textTheme
              .headlineMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),

        // 副标题：更细的状态说明，由 Provider 翻译成人话
        // （v3.7：句子在 Provider 里是文案键，传 l10n 进去才成句）
        Text(
          conn.connectionStatusOf(l10n),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ============================================================================
// _ModeTabs —— 手画的三个 Tab（不是 SegmentedButton）
// ----------------------------------------------------------------------------
// 为什么不用 Material 自带的 SegmentedButton？
//   因为它只能给"整条"上一个选中色，做不到"每个段各自按自己的连接状态
//   上色"（WiFi 绿、USB 灰、蓝牙灰 这种组合）。所以这里用
//   Container + InkWell 手绘：完全掌控每个 Tab 的颜色、图标和下划线。
// ============================================================================
class _ModeTabs extends StatelessWidget {
  final ConnectionProvider conn;

  const _ModeTabs({required this.conn});

  @override
  Widget build(BuildContext context) {
    return Container(
      // 三个 Tab 包在圆角浅灰容器里，视觉上成为一个"控件"
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        // children 里用展开语法把三个 Tab 平铺，每个等宽（Expanded）
        children: [
          _ModeTab(
            conn: conn,
            mode: ConnectionMode.wifi,
            icon: Icons.wifi,
          ),
          _ModeTab(
            conn: conn,
            mode: ConnectionMode.usb,
            icon: Icons.usb,
          ),
          _ModeTab(
            conn: conn,
            mode: ConnectionMode.bluetooth,
            icon: Icons.bluetooth,
          ),
        ],
      ),
    );
  }
}

/// 单个 Tab：状态色 + 成功对勾 / 失败感叹号 + 选中下划线
class _ModeTab extends StatelessWidget {
  final ConnectionProvider conn;
  final ConnectionMode mode;
  final IconData icon;

  const _ModeTab({
    required this.conn,
    required this.mode,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final status = conn.statusOf(mode); // 这个模式自己的连接状态
    final selected = conn.connectionMode == mode; // 是不是正在看的这栏
    final l10n = AppLocalizations.of(context); // 模式名要翻（只有"蓝牙"有差异）

    // 状态 → 颜色（没连过/从没失败的兜底成中性深灰，避免三个 Tab 全是一片浅灰）
    final Color color;
    switch (status) {
      case ConnectionStatus.connected:
        color = const Color(0xFF0F8A43); // 绿
        break;
      case ConnectionStatus.connecting:
        color = const Color(0xFF1565C0); // 蓝
        break;
      case ConnectionStatus.error:
        color = const Color(0xFFC62828); // 红
        break;
      case ConnectionStatus.disconnected:
        color = selected
            ? const Color(0xFF37474F)
            : const Color(0xFF90A4AE); // 深灰 / 浅灰
    }

    // 状态 → 右上角的小标记：绿=✓，红=！，其余不显示
    final IconData? badge;
    switch (status) {
      case ConnectionStatus.connected:
        badge = Icons.check_circle;
        break;
      case ConnectionStatus.error:
        badge = Icons.error;
        break;
      case ConnectionStatus.connecting:
      case ConnectionStatus.disconnected:
        badge = null;
    }

    return Expanded(
      // Expanded：让每个 Tab 平分 Row 的宽度
      child: InkWell(
        // onTap 只做一件事：切换"在看哪个 Tab"。
        // conn.setMode 内部绝不含 connect/disconnect —— 这是硬要求。
        onTap: () => conn.setMode(mode),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          // AnimatedContainer：属性变化时平滑过渡，而不是"啪"地跳色
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          color: selected ? Colors.white : Colors.transparent,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 5),
                  Text(
                    conn.modeLabel(l10n, mode),
                    style: TextStyle(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  // 有标记才占位：! 断言 badge 非空（前面已判过 != null）
                  if (badge != null) ...[
                    const SizedBox(width: 3),
                    Icon(badge, size: 14, color: color),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              // 选中指示条：用透明与否表示"选没选中"，不改变整体高度
              Container(
                width: 28,
                height: 3,
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// _AddressArea —— 当前 Tab 的输入区（三种模式三套内容）
// ============================================================================
class _AddressArea extends StatelessWidget {
  final ConnectionProvider conn;

  const _AddressArea({required this.conn});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (conn.connectionMode) {
      // ── WiFi：完整 IP:端口 ──
      case ConnectionMode.wifi:
        return Column(
          children: [
            SizedBox(
              width: 320,
              child: TextField(
                controller: conn.serverAddressController,
                // 注意：decoration 不再是 const —— 里面的文字来自 l10n，
                // 是运行期才知道的值（const 只能包编译期常量）。
                decoration: InputDecoration(
                  labelText: l10n.serverAddressLabel,
                  hintText: l10n.serverAddressHint,
                  prefixIcon: const Icon(Icons.computer),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                // 已连接时锁住输入：要改地址先断开，避免"改了个没生效的地址"
                enabled: !conn.isConnected,
              ),
            ),
            const SizedBox(height: 8),
            _Hint(text: l10n.wifiSameNetworkHint),
          ],
        );

      // ── USB：IP 固定 127.0.0.1，只填端口 ──
      case ConnectionMode.usb:
        // USB 隧道依赖 Android 的 adb reverse，iPhone 没有对应机制
        // （iOS 的 USB 转发要在电脑端做 usbmuxd，不在当前范围）。
        final android = Platform.isAndroid;
        return Column(
          children: [
            SizedBox(
              width: 320,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.grey.shade100,
                      ),
                      child: const Text(
                        '127.0.0.1:',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: conn.usbPortController,
                      decoration: InputDecoration(
                        labelText: l10n.portLabel,
                        hintText: '8080',
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      enabled: !conn.isConnected,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Android：讲 adb reverse 怎么执行；iPhone：直说没有 USB 通道、请用 WiFi。
            _Hint(text: android ? l10n.usbHint : l10n.usbIphoneHint),
          ],
        );

      // ── 蓝牙：占位 ──
      case ConnectionMode.bluetooth:
        return Container(
          width: 320,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Text(
            l10n.bluetoothHint,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF616161), height: 1.5),
            textAlign: TextAlign.start,
          ),
        );
    }
  }
}

/// 输入框下面那行小字提示（灰色小字号，集中一个组件免得三处写歪）
class _Hint extends StatelessWidget {
  final String text;

  const _Hint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 11, color: Colors.black45),
          textAlign: TextAlign.center),
    );
  }
}

// ============================================================================
// _ConnectButton —— 唯一会改变连接状态的按钮
// ----------------------------------------------------------------------------
// 语义（用户明确要求）：只有在【当前 Tab】里点这个按钮，才会清除之前的
// 已连接/失败状态并建立新连接。文案由 Provider 的 connectButtonText 给出，
// 连着别的 Tab 时它会写成"连接（会先断开WiFi）"，提前把代价说清楚。
// ============================================================================
class _ConnectButton extends StatelessWidget {
  final ConnectionProvider conn;

  const _ConnectButton({required this.conn});

  @override
  Widget build(BuildContext context) {
    // 蓝牙是占位，按钮直接置灰；正在连（isLoading）时也禁用防重复提交。
    final blocked = conn.connectionMode == ConnectionMode.bluetooth;

    return SizedBox(
      width: 320,
      height: 50,
      child: FilledButton.icon(
        // onPressed 传 null 是 Flutter 的"禁用按钮"协议：
        // 只要为 null，按钮自动置灰且不可点。
        onPressed: (blocked || conn.isLoading)
            ? null
            : () => conn.toggleConnection(),
        // 图标三态：加载中转圈 / 已连接断链 / 未连接链接
        icon: conn.isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Icon(conn.isConnected ? Icons.link_off : Icons.link),
        label: Text(conn.connectButtonTextOf(AppLocalizations.of(context))),
      ),
    );
  }
}

// ============================================================================
// _ConsentBanner —— 电脑请求使用手机摄像头的确认横幅
// ----------------------------------------------------------------------------
// 只有 CameraProvider.requestPending 为 true（服务器推来 cam_request）时存在。
// "忽略"= 这一次不给用；长期不给用要去摄像头详情页把总闸拨到禁用。
// ============================================================================
class _ConsentBanner extends StatelessWidget {
  const _ConsentBanner();

  @override
  Widget build(BuildContext context) {
    return Consumer<CameraProvider>(
      builder: (context, cam, _) {
        if (!cam.requestPending) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context);
        return Container(
          width: 320,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red.shade200),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.videocam, color: Colors.red.shade600, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.consentTitle,
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
                    child: Text(l10n.consentIgnore),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
                    onPressed: () => cam.acceptRequest(),
                    child: Text(l10n.consentAgree),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================================
// _DeviceCard —— 一台设备的入口卡（图标 + 名称 + 状态徽标 + 说明行）
// ----------------------------------------------------------------------------
// 状态词/颜色全部来自 DeviceProvider，首页卡、页面顶栏、页首闸门三处
// 读同一份翻译，永远不会出现"这里说待命、那里说使用中"的矛盾。
// ============================================================================
class _DeviceCard extends StatelessWidget {
  final PcDevice device;

  const _DeviceCard({required this.device});

  /// 设备 → 详情页 Widget。用 switch 表达式（Dart 3 语法）返回一个 Widget。
  Widget _page() {
    switch (device) {
      case PcDevice.speaker:
        return const SpeakerScreen();
      case PcDevice.mic:
        return const MicScreen();
      case PcDevice.camera:
        return const CameraScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, dev, _) {
        final l10n = AppLocalizations.of(context);
        final color = dev.statusColor(device);
        return SizedBox(
          width: 320,
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              // 描边用状态色的浅版：整张卡跟着状态走，扫一眼就知道哪台在干活
              side: BorderSide(color: color.withValues(alpha: 0.35)),
            ),
            child: ListTile(
              onTap: () {
                // Navigator.push：把详情页"压"进路由栈，返回键可退回首页。
                // 详情页不传任何数据——它内部用 Consumer 自己去全局仓库取。
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => _page()),
                );
              },
              leading: Icon(dev.iconOf(device), color: color),
              title: Row(
                children: [
                  Text(dev.nameOf(l10n, device),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  // 状态徽标（胶囊）
                  _StatusChip(
                      label: dev.statusLabelOf(l10n, device), color: color),
                ],
              ),
              subtitle: Text(dev.detailLineOf(l10n, device),
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              trailing: const Icon(Icons.chevron_right, size: 22),
            ),
          ),
        );
      },
    );
  }
}

/// 状态胶囊徽标：浅色底 + 状态色文字
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ============================================================================
// _PulsingDot —— 呼吸闪烁的圆点（详情页"使用中"指示灯复用）
// ----------------------------------------------------------------------------
// "正在工作"的通用视觉语言：像录音棚的红灯一样一明一暗。
// 实现要点（新手三件套）：
//   StatefulWidget —— 组件自己有内部状态（动画进度），需要刷新自己
//   TickerProviderStateMixin —— 给 State 装一个"逐帧闹钟"，
//     AnimationController 靠它每一帧推进数值
//   AnimatedBuilder —— 只重建动画影响这一小块，不牵动整页
// 摄像头/麦克风详情页里也用得到，所以保留在本文件并对外暴露。
// ============================================================================
class PulsingDot extends StatefulWidget {
  final Color color;
  final double size;

  const PulsingDot({super.key, required this.color, this.size = 14});

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
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
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: opacity),
            shape: BoxShape.circle,
            // 外发光圈：同色半透明放大一圈，模拟"亮灯的光晕"
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: opacity * 0.35),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}
