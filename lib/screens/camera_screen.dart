// ============================================================================
// camera_screen.dart —— 手机摄像头详情页（v3.6 改版）
// ----------------------------------------------------------------------------
// 页面顺序（v3.8 起： DeviceGate 提到最前，与音响/麦克风两页完全一致）：
//   AppBar：设备名 + 状态胶囊
//   └─ ① DeviceGate 状态明说块（启用/禁用总闸）—— 三页统一，页首第一块
//   └─ ② 取景预览卡（未开相机时是灰色占位 = 硬件真没开的证据）
//   └─ ③ 参数：清晰度 / 镜头 / 旋转 ——【任何状态都能改】，只有已禁用才锁
//   └─ ④ 冻结画面（会话保留，画面停住）
//   └─ ⑤ 使用说明 + iOS 平台限制提示
//
// 注：① / ② 在 v3.8 之前是反过来的（预览卡压着总闸），本轮按用户要求调换。
//
// 本轮按用户要求删掉的东西（不要再加回来）：
//   · "通道：Unity Video Capture / OBS"状态块 —— 顶栏徽标就是唯一占用指示；
//   · "后台守护"开关 —— 禁用滑块是唯一的闸；
//   · 大圆形"启用/停止"按钮、红色"启用摄像头"按钮。
// 同样地，删的是开关入口，前台保活服务改为常驻（否则息屏后进程被回收，
// 电脑再也唤不起手机相机）。
//
// 【给初学者的阅读指引】
// · 本文件一共 3 类组件：StatelessWidget（CameraScreen、_PreviewCard）和
//   一个 StatefulWidget（_FullscreenPreviewScreen）。
//   Stateless = 组件自己不存可变数据，"数据变 → 整件被换新的重画"；
//   Stateful = 组件有生命周期（initState 进场跑一次、dispose 退场跑一次），
//   只在组件自己必须"记住点什么 / 进场做收尾做什么"时才用（全屏页要
//   进页面改横屏、退页面恢复竖屏，这就是非记不可的东西）。
// · 驱动本页的数据全住在 CameraProvider（lib/providers/camera_provider.dart，
//   那里已有逐字段注释，本文件只讲界面自己的事）。本页只做三件事：
//   用 Consumer 订阅变化、在 build 里读 provider 的 getter、在按钮回调里
//   调 provider 的方法 —— 界面从不"自己动手改画面"。
// · 启用摄像头有两条入口：入口 A = 本页/首页的开关（用户主动开守护）；
//   入口 B = PC 推 cam_request → 手机弹出"同意横幅"，用户点同意才登记会话。
//   横幅画在 home_screen.dart（不在本页），它是隐私底线：手机绝不替用户点头。
// ============================================================================

import 'dart:io' show Platform; // Platform.isIOS —— iOS 特有限制的提示显隐

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemChrome 控制全屏方向/系统栏
import 'package:provider/provider.dart';

// AppLocalizations 由 Flutter 的 gen_l10n 工具从 lib/l10n/app_zh.arb /
// app_en.arb【自动生成】lib/l10n/app_localizations*.dart 三个文件。
// 那三个 dart 文件是构建产物：绝对不要手改，改句子要改 .arb 再重新生成。
// 本项目生成的 AppLocalizations.of(context) 内部已判空写死（带了 !），
// 所以界面里取出来后可以直接点方法调用，不用再补一个 !。
import '../l10n/app_localizations.dart';
import '../providers/camera_provider.dart';
import '../services/camera_service.dart'; // CamPreviewTexture（v3.11 GPU 预览）
import '../providers/device_provider.dart';
import '../widgets/device_gate.dart';

/// 摄像头模式页
class CameraScreen extends StatelessWidget {
  // StatelessWidget：本页没有任何可变字段 —— 状态词、预览帧、档位表全部
  // 读自 CameraProvider。组件唯一的职责就是 build()：把"此刻的数据"翻译成
  // "此刻的 UI"。数据一变，框架会重新跑一遍 build 生成新界面 —— 你永远
  // 不需要（也没有 setState 可用）去"手动改某个控件的文字/颜色"。
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶栏的 DevicePageTitle 是共用组件（lib/widgets/device_gate.dart）：
      // 状态胶囊的五档词（对摄像头 = 已禁用/未连接/待电脑请求/待命/取景中）
      // 与配色由 DeviceProvider.statusOf/statusLabelOf 统一算 —— 和首页卡片
      // 同一本账本，绝不会出现两处说法不一致。本页不用为此写一行判断。
      appBar: AppBar(
        title: const DevicePageTitle(device: PcDevice.camera),
        centerTitle: true,
      ),
      // 订阅 Provider 数据的三种写法，取舍记一遍（本页用第一种）：
      //   Consumer<T>(builder:) —— 被包住的整棵子树都随 notifyListeners 重建。
      //     本页整屏内容几乎都被 CameraProvider 驱动，包一层最省事；
      //   context.watch<T>()   —— 等价能力但粒度更细：只重建调用它的那个
      //     子 widget，适合"一页里只有一小块跟数据走"的场景；
      //   context.read<T>()    —— 只取实例、【不建立监听】：专用于按钮回调
      //     这类"点一下调个方法就走"的场合，在 build 里调用是反模式。
      // builder 的第二个参数 provider 就是最新的 CameraProvider 实例，
      // 所以本页子树里读数据直接用 provider.xxx，三个写法这里都不额外出现。
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          // l10n：当前语言的文案表，整页取一次往下传
          final l10n = AppLocalizations.of(context);
          final state = provider.state;
          // isLive = "相机硬件真的开着"（CamState.live）。REC 红横幅、
          // 参数角标、冻结按钮的样式全都挂在这个布尔上 —— 界面不猜硬件状态，
          // 只如实转述 provider 说的。
          final isLive = state == CamState.live;
          // 错误提示：Provider 里只存"错误键 + 原始细节"，到这里才翻成人话
          final errorText = provider.errorOf(l10n);

          // ── 清晰度下拉框的取值（v3.4.12 修正，规则沿用）──
          // 下拉框每个选项要一个"内部标识"(value)，选中后 Flutter 用它回填显示。
          // 以前把 "640×480 @ 30fps" 这种给人看的文字当标识，再用正则把数字
          // 抠回来 —— 正则只删非数字字符，fps 的 "30" 会粘在高度后面
          // （变成 48030），永远匹配不到档位，于是"选了却没反应"。
          // 现在标识 = 档位清单里的【下标】("0"/"1"/…)：显示文字随便改，
          // 选中即 lensSizes[i]，不需要任何反解，也不会重名。
          final sizes = provider.lensSizes;
          final selIdx = provider.autoProfile
              ? -1
              : sizes.indexWhere((s) =>
                  s.width == provider.selWidth &&
                  s.height == provider.selHeight);
          // 手动档但清单里找不到（换镜头的瞬间）→ 回落到显示"自动"，
          // 保证 value 一定在 items 里，否则 DropdownButton 会断言崩溃。
          final qualityValue = selIdx >= 0 ? '$selIdx' : 'auto';

          // 参数能不能改：只有【已禁用】才锁死。
          // 待命/未连接都放开 —— 用户原话："我理解任何时候都可以修改摄像头清晰度"。
          final paramsLocked = !provider.enabled;

          // 布局最外三层（先看清骨架，后面所有块都塞在 Column 里往上叠）：
          //   Center              —— 内容不满一屏时把整列居中（平板/横屏好看）；
          //   SingleChildScrollView —— Column 自己不会滚动！内容总高度一旦超过
          //     屏幕，Column 会直接甩 RenderFlex overflow 报错（黄黑条纹）。
          //     套上滚动视图后"超出"变成"可滑动"，永远不会溢出报错；
          //   Column(stretch)     —— 竖着排子项，stretch = 每个子项横向撑满，
          //     卡片才不会缩成内容那么宽。
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ============ ① 状态明说块（启用 / 禁用总闸）============
                  // v3.8：与音响页（speaker_screen）、麦克风页（mic_screen）对齐 ——
                  // 三台设备的"唯一开关"统一占住页首第一块，用户从上往下一眼先看到
                  // "这台设备启用了吗"。摄像头页原先被一张取景预览卡压在下面，
                  // 现在预览卡退到第 ② 位。
                  const DeviceGate(device: PcDevice.camera),
                  const SizedBox(height: 16),

                  // ============ ② 取景预览卡 ============
                  // previewJpeg 就是"最新一帧的完整 JPEG 字节"（Uint8List?），
                  // 由 CameraService 采集、CameraProvider 缓存后递下来给
                  // Image.memory 显示 —— 解码与逐帧刷新节奏见 _PreviewCard 头注。
                  // 【v3.8.4】整页里**只有这一块**订阅"帧刷新通道" previewFrame。
                  // 以前帧刷新走 notifyListeners()，外层 Consumer 把整个页面
                  // （开关、下拉框、权限提示、按钮…）每秒重建十几次 —— 实测
                  // Dart 主线程独吃 1.66 核。现在帧只推到这个小通道，
                  // 重建范围收敛到预览卡本身，其余控件纹丝不动。
                  ValueListenableBuilder<Uint8List?>(
                    valueListenable: provider.previewFrame,
                    builder: (context, jpeg, _) => _PreviewCard(
                      previewJpeg: jpeg,
                      // 【v3.11】GPU 预览纹理：取到了就走零解码直通，
                      // 取不到（老设备）自动退回解码 JPEG 的老路径。
                      texture: provider.previewTexture,
                      isLive: isLive,
                      // 角标：真实读数（不是写死的样例数据）
                      stamp: isLive
                          ? l10n.camStamp(provider.qualityText,
                              provider.facingTextOf(l10n))
                          : null,
                      // 整卡点按 = 全屏（原型上写的是"点按全屏"）
                      onFullscreen: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const _FullscreenPreviewScreen(),
                            ),
                          ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ============ ①' 缺权限提示（系统授权，不是功能开关）========
                  // 运行时权限的真实链路（本项目【没有】用 permission_handler 之类的
                  // 包，是自己经平台通道向 Android 要权限）：
                  //   按"授予权限" → provider.toggle() → CameraService.ensurePermission()
                  //   → MethodChannel requestCamPermission → Android 弹系统授权窗，
                  //   Dart 端的 await 会一直挂到用户点"允许/拒绝"才有返回值。
                  // 用户拒绝后界面上留下什么：这条琥珀色横幅一直在
                  //   （needsPermission 保持 true），外加下方一行红色错误字（①''）。
                  // 为什么"刚授权完必须把开硬件的流程整个重走一遍"：之前那次因缺权限
                  //   失败的打开请求早就以 PERMISSION_DENIED 返回了，系统事后放行并不
                  //   会让它自动重试 —— 只能重新调一次"查权限→登记会话→等唤醒开相机"
                  //   的完整流程。所以这个按钮调的是 toggle()，而不是把横幅藏掉了事。
                  if (provider.needsPermission && provider.enabled) ...[
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
                            child: Text(l10n.camNoPermission,
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

                  // ============ ①'' 错误提示（有才显示）============
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

                  // ============ ③ 参数区 ============
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
                          const SizedBox(height: 12),

                          // ── 清晰度 ──
                          // 未连接/待命时也要显示这一行：还没探到档位就写
                          // "探测中…"，而不是整行消失（整行消失会让用户以为
                          // 这个功能只在工作时存在）。
                          Text(l10n.camQuality,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54)),
                          const SizedBox(height: 4),
                          if (sizes.isEmpty)
                            Text(
                              provider.capsReady
                                  ? l10n.camNoModes
                                  : l10n.camProbing,
                              style: const TextStyle(
                                  fontSize: 13, color: Colors.black38),
                            )
                          else
                            // DropdownButton 新手解剖：items = 选项清单，每项带
                            // 一个内部标识 value 和显示用的 child widget；
                            // value = 当前选中项，它【必须能在 items 里找到】，
                            // 找不到框架直接抛断言错误（所以上面 qualityValue 才有
                            // "找不到就回落 'auto'"的保护）；
                            // onChanged = 选中后的回调。传 null 就是整只控件置灰
                            // 不可点 —— Flutter 控件的通用禁用手法（下面
                            // 镜头/旋转按钮、麦克风页 SegmentedButton 同一套路）。
                            DropdownButton<String>(
                              isExpanded: true,
                              // 选中项标识（'auto' 或档位下标）
                              value: qualityValue,
                              items: [
                                DropdownMenuItem(
                                  value: 'auto',
                                  child: Text(l10n.camAutoHighest,
                                      style: const TextStyle(fontSize: 14)),
                                ),
                                for (int i = 0; i < sizes.length; i++)
                                  DropdownMenuItem(
                                    value: '$i',
                                    child: Text(
                                      // v3.8：以前这里把 maxFps 先 clamp(1, 30) 再显示，
                                      // 于是支持 60fps 的档被显示成 "…@ 30fps" —— 界面在说谎，
                                      // 用户明明有更快的镜头却永远看不到。现在如实显示
                                      // 这颗镜头报出来的真实上限。
                                      // 注意没有单独的"帧率"控件：每一档自带 maxFps，
                                      // 选中后由 provider 直接用该档上限当当前 fps
                                      // （见 CameraProvider.selectProfile），
                                      // 界面只展示这一对绑定的结果。
                                      '${sizes[i].width}×${sizes[i].height} @ ${sizes[i].maxFps.clamp(1, 240)}fps',
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                              ],
                              onChanged: paramsLocked
                                  ? null
                                  : (v) {
                                      if (v == null) return;
                                      if (v == 'auto') {
                                        provider.setAutoProfile();
                                        return;
                                      }
                                      // 下标 → 直接取出档位对象，不做字符串解析
                                      final i = int.tryParse(v) ?? -1;
                                      if (i >= 0 && i < sizes.length) {
                                        provider.selectProfile(sizes[i]);
                                      }
                                    },
                            ),

                          const SizedBox(height: 12),

                          // ── 镜头 + 旋转 ──
                          // 以前相机没开就置灰，理由是"切镜头只对正在取景有意义"。
                          // 这是错的：待命时预设好镜头，等电脑一唤醒就直接用对的镜头，
                          // 用户不该为了一次预设去手动开相机。
                          // 按钮只是把意图递进去：onPressed 调 provider.switchLens()/
                          // rotateManual90()，差异全由 provider 消化 —— 取景中会让原生
                          // stop→start 立刻换镜头；待命/未连接只翻转"想要哪颗"的意图位
                          // 并重发登记（硬件本来关着，没东西可切）。界面不分状态写代码，
                          // 这正是"任何状态都能改参数"能成立的底气。
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: paramsLocked
                                      ? null
                                      : () => provider.switchLens(),
                                  icon: const Icon(Icons.cameraswitch, size: 18),
                                  label: Text(provider.switchButtonTextOf(l10n),
                                      style: const TextStyle(fontSize: 12.5)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      paramsLocked ? null : () => provider.rotateManual90(),
                                  icon: const Icon(Icons.rotate_90_degrees_cw,
                                      size: 18),
                                  // 文案带当前角度，点一下就能看到 0→90→180→270
                                  label: Text(l10n.camRotate(provider.manualRotation),
                                      style: const TextStyle(fontSize: 12.5)),
                                ),
                              ),
                            ],
                          ),

                          ParamHint(text: l10n.camParamHint),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ============ ④ 冻结画面（临时，会话保留）============
                  // 和禁用滑块的分工：禁用 = 拆掉这条链路；冻结 = 画面停住不动，
                  // 电脑那边的虚拟摄像头还存在。只有会话在（非 idle）时才有意义。
                  // provider.isMuted 决定画哪只按钮：红色填充"已冻结"（再按解冻）/
                  // 描边"冻结画面"；两只按钮的 onPressed 都调同一个 toggleMute() ——
                  // 按钮自己不判断"这次是冻还是解"，状态只存 provider 一处，界面就不会骗人。
                  // 外层 SizedBox(height: 48) 是定高约束：按钮组件倾向于尽量撑满
                  // 给到的空间，在按内容定高的 Column 里裸奔可能触顶或溢出，
                  // 钉死 48 让它老实待着。
                  if (state != CamState.idle)
                    SizedBox(
                      height: 48,
                      child: provider.isMuted
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade600),
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.videocam_off),
                              label: Text(l10n.camFrozenLabel),
                            )
                          : OutlinedButton.icon(
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.pause_circle_outline),
                              label: Text(l10n.camFreezeLabel),
                            ),
                    ),

                  const SizedBox(height: 16),

                  // ============ ⑤ 使用说明 ============
                  Text(
                    l10n.camHowToUse,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                          height: 1.6,
                        ),
                  ),

                  // iOS 平台差异提示（安卓不显示这块）。
                  // 原因：苹果系统硬性规定，App 退到后台或锁屏后
                  // 【不允许继续采集相机】（麦克风可以，相机不行）。
                  // 所以 iPhone 上必须亮屏停在本页 —— 与其让用户以为守护失灵，
                  // 不如明说。
                  if (Platform.isIOS)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        l10n.camIosNote,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.error,
                              height: 1.6,
                            ),
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

// ============================================================================
// _PreviewCard —— 取景预览卡（REC 横幅 + 点按全屏 + 真实参数角标）
// ----------------------------------------------------------------------------
// AspectRatio(4:3)：预留一块固定比例的取景窗。
// Image.memory：把 JPEG 字节直接解码显示（Flutter 内置解码器）。
//   gaplessPlayback: true —— 新帧到达前继续显示旧帧，预览不闪黑。
// previewJpeg 为 null（未开相机）→ 显示灰色占位：相机硬件真的没开。
//
// Image.memory 再讲透一点（初学者）：它在内部把 Uint8List 包成 MemoryImage
// 这个 ImageProvider，交给 Flutter 自带的编解码器解码成一张 GPU 纹理再上屏
// —— 不需要临时文件、不走网络。每次 Consumer 重建时传进来的是"最新一帧"，
// Image 发现字节换了就换图，gaplessPlayback 保证换的瞬间仍显示旧图。
// 每帧刷新的节奏由 Provider 端决定：CameraProvider 有时间戳闸门
// （_lastNotifyMs），间隔 = 1000/帧率（30fps→33ms），上限夹在 ~24fps ——
// 为什么不能每帧都 notifyListeners：相机一秒可出 30+ 帧，一帧刷一次 =
// 一秒重建整页 N 次，CPU 全烧在重画界面上，手机发热耗电、预览反而卡。
// ⚠ 注意节流只影响【手机自己的预览】——发给 PC 虚拟摄像头的帧是
// 逐帧走的，不受这里拖累。
// 黑底取景框的层级（从外到内念一遍就知道为什么这么排）：
//   ClipRRect（把圆角裁出来，子组件溢出圆角的部分被剪掉）
//   → ColoredBox 黑底（图片按 contain 显示时上下/左右的留白也是黑的，像取景器）
//   → GestureDetector（整卡点按进全屏）
//   → Column [REC 红横幅（仅 live 时出现）, Stack 取景窗]
//   Stack 里：AspectRatio(4:3) 铺底定出取景窗，Positioned 把角标钉在角落。
//   本卡片没有用 FittedBox——缩放是交给 Image 自己的 fit: BoxFit.contain
//   （完整显示不裁切，留黑边）；全屏页则换成 cover（铺满屏，超出部分裁掉）。
// ============================================================================
/// 预览解码宽度（物理像素）＝ 取景窗逻辑宽 × 设备像素比，夹在 [160, 1920]。
/// 宽度拿不到（布局异常）返回 null，让解码器按原始尺寸兜底 —— 宁可多花一点，
/// 也不要解码出一张 0 宽的废图。
///
/// 【v3.10】quarter 为奇数（转 90°/270°）时，图的"宽"这一轴在旋转后落在屏幕上
/// 的【高】这一轴上，所以要按 box.maxHeight 算，否则会按错轴解出偏大的图。
int? _previewDecodeWidth(
    BuildContext context, BoxConstraints box, int quarter) {
  final w = (quarter % 2 == 1) ? box.maxHeight : box.maxWidth;
  if (!w.isFinite || w <= 0) return null;
  final dpr = MediaQuery.of(context).devicePixelRatio;
  return (w * dpr).round().clamp(160, 1920).toInt();
}

// ============================================================================
// 【v3.10】帧载荷的方向标记 —— 旋转从手机搬走了，但"怎么摆正"还得告诉两端
// ----------------------------------------------------------------------------
// 原生（CameraEngine.withOrientTag）在 JPEG 前面加了 1 个字节：
//   bit0~1 = 需要【顺时针】转几个 90°（0~3）
//   bit2   = 1 表示还要水平镜像（前置镜头自拍视角）
// 手机这边不再做像素重排（那一步实测 27~28ms/帧），改用 RotatedBox + Transform
// 交给 GPU 合成 —— 在渲染树里转一张纹理是免费的，比在 CPU 上搬 69 万像素便宜
// 几个数量级。PC 端则在解码成 RGBA 后自己转（见 AudioServer src/vcam.rs）。
// ============================================================================
int _orientFlags(Uint8List frame) => frame.isEmpty ? 0 : frame[0];
int _quarterTurns(Uint8List frame) => _orientFlags(frame) & 0x3;
bool _needsMirror(Uint8List frame) => (_orientFlags(frame) & 0x4) != 0;

/// 跳过方向标记字节，取真正的 JPEG。
/// sublistView 返回的是【视图】而不是副本 —— 每帧几十 KB 不产生额外拷贝。
Uint8List _jpegView(Uint8List frame) => Uint8List.sublistView(frame, 1);

/// 一帧画面（带方向标记）→ 摆正后的图片。预览卡与全屏页共用。
class _OrientedFrame extends StatelessWidget {
  final Uint8List frame;
  final BoxFit fit;
  final int? cacheWidth;

  const _OrientedFrame({
    required this.frame,
    required this.fit,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    // 防御：帧里至少得有"标记字节 + 一点 JPEG"。空包（原生编码失败的占位帧）
    // 直接不画 —— 免得 sublistView 越界把整页打成红屏。
    if (frame.length <= 1) return const SizedBox.shrink();
    final quarter = _quarterTurns(frame);
    // 旋转后的图（RotatedBox 已经把它转正），再水平镜像。
    // ⚠ 顺序不能反：镜像必须作用在【转正之后】的画面上（和原生原先的
    // orientInto 语义一致）。若把 Transform 放在里面，90° 时会变成垂直翻转，
    // 画面上下颠倒 —— 因为 H∘R ≠ R∘H（旋转 90° 后再横翻 == 先竖翻再旋转）。
    final rotated = RotatedBox(
      quarterTurns: quarter,
      child: Image.memory(
        _jpegView(frame),
        fit: fit,
        gaplessPlayback: true,
        // 低质量采样：预览缩放用双线性就够了，
        // 默认的中/高质量在低端机上光栅成本明显更高。
        filterQuality: FilterQuality.low,
        // 【按显示尺寸解码】（v3.8.3）：整张 JPEG 每帧全尺寸解码再缩小
        // 显示，是"帧率提上去后预览变卡"的大头。
        cacheWidth: cacheWidth,
      ),
    );
    if (!_needsMirror(frame)) return rotated;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
      child: rotated,
    );
  }
}

/// 【v3.11】预览纹理（GPU 直通版）：相机画面直接采样，不解码 JPEG。
///
/// 与 _OrientedFrame 摆正的规矩完全一致（同一套 orient 编码：
/// 先旋转、后镜像），只是把"解码出来的图片"换成"一块 GPU 纹理"。
///
/// 为什么 Texture 外面要套 FittedBox + SizedBox：
///   Texture 没有 fit 概念 —— 它会把纹理【拉伸填满】父容器，父容器比例
///   和传感器比例不一致时画面就变形了。所以先给它一个"传感器原始比例"
///   的固定盒子，再交给 FittedBox 按 contain/cover 缩放（多出来的部分
///   留黑边或裁掉），这样任何屏幕比例下都不会变形。
class _PreviewSurface extends StatelessWidget {
  final CamPreviewTexture tex;
  final BoxFit fit;

  const _PreviewSurface({required this.tex, this.fit = BoxFit.contain});

  @override
  Widget build(BuildContext context) {
    final surface = FittedBox(
      fit: fit,
      child: SizedBox(
        width: tex.width.toDouble(),
        height: tex.height.toDouble(),
        child: Texture(textureId: tex.id),
      ),
    );
    // 先转正：RotatedBox 在 GPU 合成阶段旋转一张纹理，几乎零成本
    //（对比：在 CPU 上搬 69 万像素要 27ms/帧，这就是 v3.10 搬走的那一步）。
    final rotated = RotatedBox(quarterTurns: tex.quarterTurns, child: surface);
    // 再镜像 —— ⚠ 顺序不能反：镜像必须作用在【转正之后】的画面上。
    return tex.mirror
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
            child: rotated,
          )
        : rotated;
  }
}

class _PreviewCard extends StatelessWidget {
  final Uint8List? previewJpeg;
  /// 【v3.11】GPU 预览纹理。非 null 时优先用它（不解码 JPEG）；
  /// null 表示这台机没走纹理通道，退回 previewJpeg 的解码预览。
  final CamPreviewTexture? texture;
  final bool isLive;
  final String? stamp; // 角标文字（仅取景中显示）
  final VoidCallback onFullscreen;

  const _PreviewCard({
    required this.previewJpeg,
    this.texture,
    required this.isLive,
    required this.stamp,
    required this.onFullscreen,
  });

  /// 取景窗里到底画什么，按优先级三选一：
  ///   ① 有 GPU 纹理 → 直接采样相机画面（v3.11，最省：不解码、不分配位图）
  ///   ② 有 JPEG 帧 → 解码后显示（没有纹理通道时的老路径）
  ///   ③ 都没有 → "未取景"占位（相机还没开/被冻结）
  Widget _buildView(AppLocalizations l10n) {
    final tex = texture;
    if (tex != null) {
      return _PreviewSurface(tex: tex, fit: BoxFit.contain);
    }
    if (previewJpeg == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, color: Colors.white24, size: 56),
              const SizedBox(height: 8),
              Text(
                l10n.camPreviewOff,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    // LayoutBuilder：量出取景窗的【实际逻辑宽】，交给下面的
    // cacheWidth 换算成物理像素 —— 解码尺寸跟着显示尺寸走。
    return LayoutBuilder(
      // 【v3.10】画面交给 _OrientedFrame：跳过方向标记字节，
      // 用 RotatedBox/Transform 在 GPU 上摆正（手机不再做逐像素旋转）。
      // cacheWidth 按"旋转后落在哪条轴"来算。
      builder: (context, box) => _OrientedFrame(
        frame: previewJpeg!,
        fit: BoxFit.contain,
        cacheWidth:
            _previewDecodeWidth(context, box, _quarterTurns(previewJpeg!)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 卡片自己也取一次 l10n：它是独立 StatelessWidget，
    // 拿不到父页 builder 里的局部变量，但文案表是全局的，取一次很便宜。
    final l10n = AppLocalizations.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        // 黑色底：图片按 contain 显示时左右/上下的留白也是黑的，像正经取景器。
        // 点击整块取景窗也能进全屏（原型标注"点按全屏"）
        color: Colors.black,
        child: GestureDetector(
          onTap: onFullscreen,
          child: Column(
            children: [
              // ── 红色横幅：只有相机硬件真的开着才出现（隐私可见性承诺）──
              if (isLive)
                Container(
                  width: double.infinity,
                  color: Colors.red.shade600,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.fiber_manual_record,
                          color: Colors.white, size: 12),
                      const SizedBox(width: 6),
                      Text(
                        l10n.camRecOverlay,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              // ── 取景窗 ──
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: _buildView(l10n),
                  ),
                  // 参数角标（左下角真实读数）
                  if (stamp != null)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(stamp!,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                  // 全屏提示（右下角）
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.fullscreen,
                              color: Colors.white, size: 14),
                          const SizedBox(width: 4),
                          Text(l10n.camTapFullscreen,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// _FullscreenPreviewScreen —— 全屏取景页（真·全屏 + 自动横屏）
// ----------------------------------------------------------------------------
//   ① 画面铺满：Image 的 fit 用 cover（铺满整屏→超出边缘裁掉），
//      不用 contain（完整显示→留大黑边）。
//   ② 强制横屏：像视频播放器一样 —— 一进全屏立刻转成横向
//      （setPreferredOrientations 只给两个横屏方向，系统"自动旋转"
//      锁着也会转），左右横躺都能拿；退出恢复竖屏。
//   ③ 沉浸式：隐藏状态栏 + 导航栏（immersiveSticky：从顶部/底部
//      划一下可临时唤出，松手自动收回，不打扰取景）。
// 因此它是 StatefulWidget —— 只有组件有"进场设置、退场恢复"这种
// 生命周期需求（在 build 里做副作用是 Flutter 大忌）。
// 生命周期时间轴（新手必背）：
//   createState() → initState()（恰好一次：进页改横屏/藏系统栏就在这里做）
//   → build()（【很多次】：父级重建、Consumer 刷新都会再跑 —— 一次性副作用
//     写在 build 里会被反复执行，这就是"大忌"的原因）
//   → dispose()（恰好一次：把 initState 做的事原样撤销，不然退出全屏后
//     整个 App 都被卡在横屏+隐藏系统栏的状态）。
// 本文件其余组件都是 StatelessWidget —— 它们没有"自己要记的东西"。
// ============================================================================
class _FullscreenPreviewScreen extends StatefulWidget {
  const _FullscreenPreviewScreen();

  @override
  State<_FullscreenPreviewScreen> createState() =>
      _FullscreenPreviewScreenState();
}

class _FullscreenPreviewScreenState extends State<_FullscreenPreviewScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    // 退出全屏：恢复"只允许竖屏"+ 系统栏。
    // dispose 里不能碰 setState，但 SystemChrome 是通道调用，安全。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values, // 全部恢复显示
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 全屏页：外层 Consumer 只负责"状态类"重建（横幅文案等低频变化），
      // 逐帧画面交给下面的 ValueListenableBuilder 单独订阅 previewFrame ——
      // 与主页面同一套做法（理由见主页面预览卡处的 v3.8.4 注释）。
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          final l10n = AppLocalizations.of(context);
          // Stack = 叠放：非 Positioned 的子组件从底铺起，Positioned 的钉角落。
          // fit: StackFit.expand 让打底的那张图（Image/占位）自动撑满整屏，
          // 不用自己算屏幕宽高。
          return Stack(
            fit: StackFit.expand,
            children: [
              // 【v3.8.4】同理：只让"这一张图"订阅帧通道 previewFrame，
              // 帧刷新不再连累全屏页里的横幅、按钮一起重建。
              ValueListenableBuilder<Uint8List?>(
                valueListenable: provider.previewFrame,
                builder: (context, frame, _) {
                  // 【v3.11】有 GPU 纹理 → 直通采样，cover 铺满整屏。
                  // 纹理自己会刷新，这里只是借帧通道顺带触发重建，无额外成本。
                  final tex = provider.previewTexture;
                  if (tex != null) {
                    return _PreviewSurface(tex: tex, fit: BoxFit.cover);
                  }
                  // 没纹理通道：退回老路径（跳过方向标记字节并在 GPU 上摆正）。
                  // 全屏页故意【不】传 cacheWidth —— cover 铺满是放大，
                  // 按屏幕宽度解码反而会先把图缩小、放大后发虚。
                  return frame == null
                      ? const Center(
                          child: Icon(Icons.videocam_off,
                              color: Colors.white24, size: 72),
                        )
                      : _OrientedFrame(frame: frame, fit: BoxFit.cover);
                },
              ),
              // 顶部红色横幅（硬件开着才见）——避开刘海/圆角安全区。
              // 注意：Positioned 必须是 Stack 的【直接】子组件，
              // 不能包 SafeArea/Padding（那会让它找不到 Stack 父级，
              // release 模式整页渲染成灰块 —— v3.4.1 首版踩过的坑）。
              // 那怎么避刘海？自己量：MediaQuery.of(context).padding 就是
              // 四边安全区 inset（刘海/圆角/状态栏/小白条各占多少），
              // top 往下让出 padding.top、bottom 往上让出 padding.bottom。
              if (provider.isLive)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red.shade600,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        // 全屏页同样显示真实档位，方便横屏时确认画质
                        l10n.camRecStamp(
                            provider.qualityText, provider.facingTextOf(l10n)),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 24,
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 26),
                    tooltip: l10n.camExitFullscreen,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
