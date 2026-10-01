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
//                     └─ _DeviceCard ×3    音响 / 麦克风 / 摄像头 详情页入口
//                     （v3.8 起不再有 _ConsentBanner：摄像头请求免确认直开）
//
// 阅读嵌套结构的技巧：从最外层往里剥，一层只做一件事。
// ----------------------------------------------------------------------------
// 新手课前速成：Widget 是什么、build 什么时候被重新调用（先读这段再看代码）
// ----------------------------------------------------------------------------
// Widget 其实不是"画界面的东西"，而是一份【不可变的描述对象】：
//   它只描述"界面此刻应该长什么样"，真正画像素的是 Flutter 引擎。
//   所以"重建"整棵 Widget 树非常廉价（不过是新写了一份描述），
//   这也是 Flutter 的写法永远是"从当前数据生成界面"，
//   而不是像老式 UI 框架那样"找到控件、手动改它的内容"。
// 两种 Widget（本文件正好各有一个例子）：
//   StatelessWidget —— 自身没有可变字段，界面完全由"入参 + Provider 状态"决定。
//                     本文件的 HomeScreen 及以下所有 _开头的小组件都是。
//   StatefulWidget  —— 有随时间变化的内部状态，住在配套的 State 对象里，
//                     改完状态调 setState() 才重画自己。文件末尾的 PulsingDot 就是。
// build() 何时被重新调用：首帧一次；此后只要祖先 Widget 重建、订阅的 Provider
//   调了 notifyListeners()、或自己 setState()，引擎就可能再跑一遍 build。
//   重跑的【时机和次数由引擎决定】，你自己控制不了。
// 因此铁律：build / builder 里只能【读数据、拼 Widget】，不许有副作用——
//   不发网络请求、不起 Timer、不写存储、不改 Provider。否则重建一次
//   等于把这些动作又执行一遍，会出现"没点按钮却发了一次请求"这种怪事。
//   副作用放进事件回调（onTap 之类）或 StatefulWidget 的生命周期方法里。
// ============================================================================

import 'dart:io' show Platform; // Platform.isAndroid/isIOS —— 平台差异显隐用
import 'dart:math' as math; // sin —— 脉冲圆点的呼吸透明度用

import 'package:flutter/material.dart';   // UI 组件库
import 'package:provider/provider.dart';  // Consumer / read 数据订阅

// 连接状态管理器：三个 Tab 的颜色、连接按钮的文案都读它
import '../providers/connection_provider.dart';

// 网络状态枚举（ConnectionStatus）定义在这里，Tab 上色要用它做 switch
import '../services/network_service.dart';

// v3.8：CameraProvider 的 import 随 _ConsentBanner 一起移除 —— 首页现在
// 只经 DeviceProvider 读摄像头的状态词，不再直接订 CameraProvider。
// （改动原则：删掉一个组件，就把它独有的依赖也带走，别留无用 import。）

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
///
/// 顺便对比 setState(() {...}) —— StatefulWidget 的刷新开关：
///   把"改字段的动作"包进回调里交给 setState，框架改完值后就知道
///   "这个组件脏了，要重跑它的 build"，界面随数据更新。
///   本页一个自己的字段都没有，刷新职责全部交给 Consumer（见下面 body）：
///   Provider 的 notifyListeners() 就相当于"在订阅者群里挨个喊 setState"。
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
          // 这里用 context.read 的时机值得记：onPopInvoked 是【事件回调】不是 build，
          // 回调里"拿对象用一下、不订阅"就该用 read；
          // 反过来 watch 只能在 build 期间调用（provider 包会检查这一点）。
          // 约定：回调里只 read，build 里要刷新用 Consumer/watch。
          context.read<AudioService>().goHome();
        }
      },
      // Scaffold：页面"脚手架"，提供 Material 页面的标准结构——
      // 顶部栏(appBar)、主体(body)、底部栏、浮动按钮等插槽。
      // 布局链从这里开始：appBar 钉在顶部（高度自管、自动避开状态栏），
      // body 拿走剩下整块 —— 下面所有东西都塞在 body 这一块里。
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
          // actions 是 AppBar 的"右侧按钮槽"（Widget 列表，从右往左排）。
          actions: [
            IconButton(
              // tooltip 是长按/悬停提示，也是读屏软件念出来的名字（无障碍必给）
              tooltip: AppLocalizations.of(context).languageTitle,
              icon: const Icon(Icons.language),
              // showLanguageSheet（widgets/language_sheet.dart）内部就是
              // showModalBottomSheet：从屏幕底部滑出的模态弹层，盖住页面、
              // 点外部收起。它返回 Future<void>，"弹层关闭时"才完成；
              // 这里不 await（知道了关闭时间也没事做），所以拿到就丢。
              // 若将来要"等用户选完再做事"，就 await 它、或看它带出的返回值。
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
        //   为什么这里"凭空"就能取到 ConnectionProvider：main.dart 把
        //   MultiProvider 包在 MaterialApp【外层】，注册过的对象是所有页面
        //   context 的祖先，沿树往上找一定找得到；若注册在 home: 里面，
        //   AppBar 那层就够不着它了——这就是"provider 必须放最外"的原因。
        //   Consumer 的等价写法是 build 里 context.watch<ConnectionProvider>()：
        //   同样订阅、同样触发重建，只是不用把 UI 包进 builder 闭眼；
        //   而 context.read 取到的值变化后【不会】让本 Widget 重建（不订阅），
        //   拿它画界面就会出现"数据变了界面不动"的经典坑。
        body: Consumer<ConnectionProvider>(
          // builder 是构建回调：
          //   context —— 当前构建上下文（Widget 在树中的位置）
          //   provider —— 取到的 ConnectionProvider 实例（下称 conn）
          //   child     —— 可选的"缓存子树"，这里没用到（不传即为 null）
          builder: (context, conn, child) {
            // v3.7：界面层取文案表。下面所有给用户看的句子都从 l10n 走，
            // 需要 Provider 帮忙成句时，就把 l10n 当参数传进去。
            // context 是什么：每个 Widget 构建时都会拿到一个 BuildContext，
            //   它代表"我在组件树里的位置"。主题、语言表、Provider 全都是
            //   从 context 出发沿树向上"找祖先"拿到的——所以取 l10n 的时机
            //   必须在 build 期间（那时 context 正在被使用），不能存成字段复用。
            // 文案从哪来：AppLocalizations.of(context) 按当前 locale 返回文案表，
            //   l10n.heroConnected、l10n.appTitle 这些 xxx 全部定义在
            //   lib/l10n/app_zh.arb / app_en.arb（JSON 键值对，一个 key 一句话）。
            //   lib/l10n/ 下的 app_localizations*.dart 三个文件是构建期由 arb
            //   自动生成的——⚠ 绝对不要手改，下次构建就被覆盖；加文案改 arb。
            //   有的教程写 AppLocalizations.of(context)!.xxx：老版本生成码返回
            //   可空值要自己加 !（"我保证它不是 null"），本项目这版生成码
            //   已在 of() 内部加好 !，所以调用处直接 .xxx。
            final l10n = AppLocalizations.of(context);
            // 错误先取成局部变量：判空和显示要用两次，
            // 避免调用两次 errorOf 时中间状态变了（理论上不会，但写法更稳）。
            final errorText = conn.errorOf(l10n);
            // Center：把唯一子节点在主轴/交叉轴上都居中
            return Center(
              // SingleChildScrollView：内容变高后小屏不会溢出（黄黑条纹），
              // 放不下就能滑动。
              // 什么时候会溢出报错（RenderFlex overflow）：Column/Row 是按
              //   "给定的剩余空间"排孩子的，内容总高超过屏幕、外面又没套
              //   滚动容器时，Flutter 塞不下就画黄黑斜条 + 控制台报错。
              //   套上滚动容器后主轴变成"要多长给多长"，条纹消失。
              // 为什么用 SingleChildScrollView 而不是 ListView：
              //   本页是一小串【不同类型】的组件，一次全建出来就行；
              //   ListView 适合"很多条同结构数据"，它只build看得见的行（懒加载）。
              child: SingleChildScrollView(
                // padding 放在滚动容器内部：滚到顶/底时内容不会贴死边缘
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                // Column：把孩子沿竖直方向排队。
                //   主轴=竖直、交叉轴=水平（Row 正好反过来）。
                //   mainAxisAlignment 管"沿主轴怎么分空间"，
                //   crossAxisAlignment 管"沿交叉轴怎么对齐"（默认 center）。
                //   center = 剩余空间上下各分一半。注意：滚动容器里主轴
                //   "要多长给多长"，压根没有剩余空间，center 实际不生效；
                //   真正把内容垂直居中靠的是外层 Center（它把比自己矮的
                //   孩子摆正中，比屏幕高时交回滚动容器处理）。
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
                    // 再补一遍产品硬规则（写代码的人容易手滑破坏它）：
                    //   切 Tab 只改"在看哪个模式"这一个字段，
                    //   既不断开现有连接、也绝不自动发起新连接；
                    //   连接/断开永远只能由用户点 _ConnectButton 触发。
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
                            // Theme.of(context)：从当前位置沿树向上取主题配置。
                            // colorScheme.error = 主题里"出错色"槽位，
                            // 想全局改配色去 lib/app.dart 的 ThemeData /
                            // ColorScheme.fromSeed 的 seedColor 字段，
                            // 这里跟着主题走、不用逐处手改。
                            color: Theme.of(context).colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],

                    const SizedBox(height: 28),

                    // ==========================================================
                    // ⑥ 三台设备的入口卡：音响 / 麦克风 / 摄像头
                    // ==========================================================
                    // 蓝牙模式暂时无摄像头通路（原型里明确要求隐藏该卡）。
                    // v3.8：这里原本还夹着一块"电脑请求使用摄像头"的确认横幅
                    // （_ConsentBanner）。按产品要求取消二次确认后，PC 发来
                    // cam_request 时 CameraProvider 直接登记进待命，不再需要
                    // 用户点"同意"。想彻底不给用，去摄像头详情页把总闸拨到
                    // "禁用"—— 那才是唯一、且能跨会话生效的否决权。
                    Consumer<DeviceProvider>(
                      builder: (context, dev, _) {
                        return Column(
                          children: [
                            // 集合字面量里直接写 for（Dart 的 collection-for）：
                            // 把 PcDevice 枚举的三个成员逐个展开成三张卡，
                            // 再配合下面的 if 过滤——比手抄三遍 _DeviceCard 更省。
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
  // 想改配色去哪儿（本页颜色值的三个来源，先记住再翻代码）：
  //   ① 连接状态色（绿 0xFF0F8A43 / 蓝 0xFF1565C0 / 红 0xFFC62828）——
  //     直接写在本文件各处的 Color(0xFF......) 里，改哪里的色就搜那个数；
  //   ② 设备五档状态色——唯一出处是 DeviceProvider.statusColor（providers 层）；
  //   ③ 主题色（primary/error/outline）——定义在 lib/app.dart 的
  //     ThemeData.colorScheme（种子色 seedColor 推导），改一处全局跟着变。
  // 字号(fontSize)/圆角(BorderRadius.circular)/阴影(elevation) 没有集中表，
  // 全是各组件就地写的字面量，想调样式就搜对应参数名。
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
// 为什么连 Flutter 自带的 TabBar 也不用？
//   TabBar 是为"整页切换"设计的：要配 TabController、通常还搭 TabBarView，
//   切 Tab 会真的换掉一屏内容。而这里的 Tab 只改 ConnectionProvider 里
//   "在看哪个模式"这一个字段，下方地址区/按钮靠 Consumer 重新 build 换脸，
//   用不上 TabBar 那套机制，手绘反而更直白、三色并存的上色完全自由。
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
    // 这里有个 Dart 小语法可学：先只声明 final Color color; 不赋值，
    // 再由下面 switch 的每个分支必赋一次——"明确赋值"规则允许 final 这样写，
    // 漏了任何一个分支编译器会报错，比到处各写一份更安全。
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
      // 原理（"剩余空间"概念）：Row 先给不带 Expanded 的孩子排掉它们
      // 要占的宽度，把剩下的宽度按 flex 比例（默认都=1）分给各 Expanded，
      // 三个 Tab 因此严格等宽。孩子合计宽度超过可用空间 → 报 flex overflow
      // （黄黑条纹）；该包 Expanded 不包、又放进无宽度约束的地方 → 直接断言崩溃。
      child: InkWell(
        // onTap 只做一件事：切换"在看哪个 Tab"。
        // conn.setMode 内部绝不含 connect/disconnect —— 这是硬要求。
        // （产品规则再记一遍：Tab 是"视图过滤器"不是"开关"，
        //  切 Tab 时物理连接原封不动，连/断只能由下面的连接按钮发起。）
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
            // SizedBox 的唯一职责是给孩子的宽度钉死成 320 逻辑像素
            // （输入区统一宽度、视觉不散到屏幕两边）；它不画任何东西。
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
        // FilledButton.icon：Material 3 的实心大按钮（图标+文字两个槽）。
        // 底色取主题 colorScheme.primary，想换按钮配色改 lib/app.dart 的种子色。
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

// v3.8：这里原本是 _ConsentBanner（电脑请求用摄像头的"同意/忽略"横幅）。
// 二次确认取消后整块删除：CameraProvider 收 cam_request 即直接进待命，
// 首页不再需要"等用户表态"的界面；唯一否决权回到设备详情页的总闸。
// 顺带把三条只服务于它的文案键（consentTitle / consentIgnore / consentAgree）
// 从 .arb 与生成文件里一起清掉 —— 死文案比死代码更难被发现。

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
          // Card：带圆角和阴影的"纸片"容器。
          // elevation:1 = 阴影厚度（离桌面多高），数字越大影子越重；
          // margin: EdgeInsets.zero 是关掉 Card 默认外边距（外间距由
          // 外层 Padding/SizedBox 统一控制，样式不散装）。
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              // 描边用状态色的浅版：整张卡跟着状态走，扫一眼就知道哪台在干活
              side: BorderSide(color: color.withValues(alpha: 0.35)),
            ),
            // ListTile：Material 标准"列表行"骨架，四个槽位各管一段：
            // leading 左图标 / title 主行 / subtitle 副行 / trailing 右箭头。
            // 自己用 Row 拼也能拼出来，但字号、间距、点按反馈都要手动调，
            // 用它就全符合 Material 规范。
            child: ListTile(
              onTap: () {
                // Navigator.push：把详情页"压"进路由栈，返回键可退回首页。
                // 详情页不传任何数据——它内部用 Consumer 自己去全局仓库取。
                // push 的返回值是 Future<T?>：详情页被"弹出"时才完成，
                // T 是详情页带着返回的结果（想等就用 await
                // Navigator.push<bool>(...)）。这里不需要知道结果，直接丢弃。
                // MaterialPageRoute：声明这页的转场样式（默认自底向上滑入）；
                // 它的 builder 在真正入场时才执行，参数 (_) 是新页面的 context。
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
        // withValues(alpha: 0.12)：按"新不透明度 12%"重新计算这个颜色 →
        // 得到同色系的浅色打底，状态色文字压在上面不刺眼。
        // 徽标只借设备状态色的"色相"，深浅由这个 alpha 数控制。
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

// StatefulWidget 是"_pair 结构"，这里把两个角色说清：
//   PulsingDot（Widget 配置单）—— 依旧不可变，只存 color/size 入参；
//   _PulsingDotState（State 仓库）—— 真正住可变数据的地方（动画控制器）。
//   父级重建 PulsingDot 一百次，createState 也只跑一次，State 跟着组件
//   一生的起落；字段前的下划线 = 私有命名约定（只在库内可见）。
// 一个反直觉点：这个 StatefulWidget 全程没调过 setState——
//   setState(() {改字段}) 是"离散变化"型 State 的通用刷新开关：
//   它只登记"我脏了"，下一帧 Flutter 重跑本 State 的 build；
//   而动画每帧都要变，用 AnimationController 驱动 AnimatedBuilder
//   精确重建那一小块，比 setState 掀翻整个子树划算得多。
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
        // widget.size / widget.color：State 里通过 widget 字段读父级传入的
        // 配置。父级随时可能换参数重建本组件，所以每次现取、不要缓存成
        // State 字段，否则参数改了界面还画旧的。
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
