// ============================================================================
// camera_screen.dart —— 手机摄像头详情页（v3.6 改版）
// ----------------------------------------------------------------------------
// 页面顺序（用户逐轮确认过的最终顺序，别再调整）：
//   AppBar：设备名 + 状态胶囊
//   └─ ① 取景预览卡（最上方；未开相机时是灰色占位 = 硬件真没开的证据）
//   └─ ② DeviceGate 状态明说块（启用/禁用总闸）
//   └─ ③ 参数：清晰度 / 镜头 / 旋转 ——【任何状态都能改】，只有已禁用才锁
//   └─ ④ 冻结画面（会话保留，画面停住）
//   └─ ⑤ 使用说明 + iOS 平台限制提示
//
// 本轮按用户要求删掉的东西（不要再加回来）：
//   · "通道：Unity Video Capture / OBS"状态块 —— 顶栏徽标就是唯一占用指示；
//   · "后台守护"开关 —— 禁用滑块是唯一的闸；
//   · 大圆形"启用/停止"按钮、红色"启用摄像头"按钮。
// 同样地，删的是开关入口，前台保活服务改为常驻（否则息屏后进程被回收，
// 电脑再也唤不起手机相机）。
// ============================================================================

import 'dart:io' show Platform; // Platform.isIOS —— iOS 特有限制的提示显隐

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemChrome 控制全屏方向/系统栏
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/camera_provider.dart';
import '../providers/device_provider.dart';
import '../widgets/device_gate.dart';

/// 摄像头模式页
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const DevicePageTitle(device: PcDevice.camera),
        centerTitle: true,
      ),
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          // l10n：当前语言的文案表，整页取一次往下传
          final l10n = AppLocalizations.of(context);
          final state = provider.state;
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

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ============ ① 取景预览卡（永远在最上方）============
                  _PreviewCard(
                    previewJpeg: provider.previewJpeg,
                    isLive: isLive,
                    // 角标：真实读数（不是写死的样例数据）
                    stamp: isLive
                        ? l10n.camStamp(
                            provider.qualityText, provider.facingTextOf(l10n))
                        : null,
                    // 整卡点按 = 全屏（原型上写的是"点按全屏"）
                    onFullscreen: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const _FullscreenPreviewScreen(),
                          ),
                        ),
                  ),
                  const SizedBox(height: 16),

                  // ============ ② 状态明说块（启用 / 禁用总闸）============
                  const DeviceGate(device: PcDevice.camera),
                  const SizedBox(height: 16),

                  // ============ ②' 缺权限提示（系统授权，不是功能开关）========
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

                  // ============ ②'' 错误提示（有才显示）============
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
                                      // maxFps 上限截到 30：虚拟摄像头吃不下更高，
                                      // 且手机宣称 60fps 的档位实际跑不稳
                                      '${sizes[i].width}×${sizes[i].height} @ ${sizes[i].maxFps.clamp(1, 30)}fps',
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
// ============================================================================
class _PreviewCard extends StatelessWidget {
  final Uint8List? previewJpeg;
  final bool isLive;
  final String? stamp; // 角标文字（仅取景中显示）
  final VoidCallback onFullscreen;

  const _PreviewCard({
    required this.previewJpeg,
    required this.isLive,
    required this.stamp,
    required this.onFullscreen,
  });

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
                    child: previewJpeg == null
                        ? ColoredBox(
                            color: Colors.black,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.videocam_off,
                                      color: Colors.white24, size: 56),
                                  const SizedBox(height: 8),
                                  Text(
                                    l10n.camPreviewOff,
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Image.memory(
                            previewJpeg!,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
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
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          final l10n = AppLocalizations.of(context);
          final jpeg = provider.previewJpeg;
          return Stack(
            fit: StackFit.expand,
            children: [
              jpeg == null
                  ? const Center(
                      child: Icon(Icons.videocam_off,
                          color: Colors.white24, size: 72),
                    )
                  : Image.memory(jpeg,
                      fit: BoxFit.cover, gaplessPlayback: true),
              // 顶部红色横幅（硬件开着才见）——避开刘海/圆角安全区。
              // 注意：Positioned 必须是 Stack 的【直接】子组件，
              // 不能包 SafeArea/Padding（那会让它找不到 Stack 父级，
              // release 模式整页渲染成灰块 —— v3.4.1 首版踩过的坑）。
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
