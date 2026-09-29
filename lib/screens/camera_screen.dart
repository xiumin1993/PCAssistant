// ============================================================================
// camera_screen.dart —— 手机摄像头详情页（v3.4 按需取景版）
// ----------------------------------------------------------------------------
// 界面结构（按已确认的 v2 设计稿）：
//   AppBar 标题
//   └─ 取景预览卡（实时画面 + 右上角全屏按钮；未开相机时显示占位图标）
//   └─ 镜头切换按钮 ——【只有一个】，文案随当前镜头变：
//        现在用后置 → 按钮写"切换前置"；现在用前置 → 写"切换后置"；
//        未开启摄像头时按钮【置灰】（onPressed=null 的 Flutter 禁用协议）
//   └─ 大圆形状态按钮（idle 蓝=启用 / standby 灰蓝=待命 / starting 转圈 /
//      live 红=取景中，点我停）
//   └─ 状态文案 + 冻结键（会话存在时出现）
//   └─ 参数信息行（画质 / 镜头 / 上行状态 / 电脑使用）
//
// 红色横幅：live（相机硬件真的开着）时预览上方出现红条 ——
// 颜色和硬件状态严格一致，是"硬件即开即见"的隐私承诺。
// ============================================================================

import 'dart:io' show Platform; // Platform.isIOS —— iOS 特有限制的提示显隐
import 'dart:typed_data'; // Uint8List：预览 JPEG 字节的类型

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // v3.4.1：SystemChrome 控制全屏方向/系统栏
import 'package:provider/provider.dart';

import '../providers/camera_provider.dart';

/// 摄像头模式页
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('摄像头模式'),
        centerTitle: true,
      ),
      body: Consumer<CameraProvider>(
        builder: (context, provider, child) {
          final state = provider.state;
          final isLive = state == CamState.live;
          final isStandby = state == CamState.standby;
          final isStarting = state == CamState.starting;
          final buttonColor = isLive
              ? Colors.red.shade600 // 取景中：红 = "硬件开着，点我全关"
              : (isStarting
                  ? Colors.blueGrey.shade200
                  : (isStandby
                      ? Colors.blueGrey.shade400 // 待命：灰蓝 = 相机关着
                      : Colors.blue.shade600)); // 未启用：蓝 = 点我启用

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ============ ① 取景预览卡 ============
                  _PreviewCard(
                    previewJpeg: provider.previewJpeg,
                    isLive: isLive,
                    // 全屏按钮：push 一个无边界的预览页（同数据源，自动同步）
                    onFullscreen: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const _FullscreenPreviewScreen(),
                          ),
                        ),
                  ),

                  const SizedBox(height: 16),

                  // ============ ② 镜头切换 + 手动旋转 按钮行 ============
                  // 切换按钮：文案 = provider.switchButtonText（当前后置→"切换前置"）
                  //   未开启摄像头时置灰禁用 —— 切镜头只对"正在取景"有意义。
                  // 旋转按钮（v3.4.1）：每点一次画面再顺时针转 90°（循环），
                  //   实时生效不重启相机；待命时也能预设，开相机后自动套用。
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            isLive ? () => provider.switchLens() : null,
                        icon: const Icon(Icons.cameraswitch),
                        label: Text(provider.switchButtonText),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: state == CamState.idle
                            ? null
                            : () => provider.rotateManual90(),
                        icon: const Icon(Icons.rotate_90_degrees_cw),
                        // 文案带上当前角度，点一下就能看到 0→90→180→270 变化
                        label: Text('旋转90° ${provider.manualRotation}°'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ============ ②.5 清晰度选择行（v3.4.4）============
                  // 下拉框内容 = 手机能力探测出来的真实档位（不是拍脑袋列举）。
                  // "自动"= 取该镜头最高档（原有行为）；手动档立即重启相机套用。
                  // 未启用（idle）或还没探测到能力时整个选择器禁用/隐藏。
                  if (state != CamState.idle && provider.lensSizes.isNotEmpty)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('清晰度',
                            style: TextStyle(color: Colors.black54)),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: provider.autoProfile
                              ? 'auto'
                              : '${provider.qualityText}',
                          // 当前档位文字（qualityText 由 provider 拼接）
                          items: [
                            // 第一项固定是"自动"，括注自动现在挑的档
                            const DropdownMenuItem(
                              value: 'auto',
                              child: Text('自动（最高档）'),
                            ),
                            // 后面每一项来自能力探测清单
                            for (final s in provider.lensSizes)
                              DropdownMenuItem(
                                value: '${s.width}×${s.height} @ ${s.maxFps.clamp(1, 30)}fps',
                                child: Text(
                                  '${s.width}×${s.height} @ ${s.maxFps.clamp(1, 30)}fps',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            if (v == 'auto') {
                              provider.setAutoProfile();
                            } else {
                              // 从 "宽×高 @ Nfps" 反解出宽高，再找回档位对象
                              final parts =
                                  v.replaceAll(RegExp(r'[^0-9×]'), '').split('×');
                              final w = int.tryParse(parts[0]) ?? 0;
                              final h = int.tryParse(parts[1]) ?? 0;
                              final match = provider.lensSizes
                                  .where((s) => s.width == w && s.height == h)
                                  .toList();
                              if (match.isNotEmpty) {
                                provider.selectProfile(match.first);
                              }
                            }
                          },
                        ),
                      ],
                    ),

                  const SizedBox(height: 16),

                  // ============ ③ 大圆形状态按钮 ============
                  Material(
                    color: Colors.transparent,
                    child: Ink(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        color: buttonColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: buttonColor.withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: provider.isBusy ? null : () => provider.toggle(),
                        child: Center(
                          child: isStarting
                              ? const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                )
                              : Icon(
                                  isLive
                                      ? Icons.stop
                                      : (isStandby
                                          ? Icons.pause
                                          : Icons.videocam),
                                  size: 48,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ============ ④ 状态文案 ============
                  Text(
                    provider.statusText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),

                  // 缺权限时给一个明确的授权按钮（不自动弹系统窗）
                  if (provider.needsPermission && state == CamState.idle) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 220,
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                        ),
                        onPressed: () => provider.toggle(),
                        icon: const Icon(Icons.videocam),
                        label: const Text('启用摄像头'),
                      ),
                    ),
                  ],

                  // ============ ⑤ 冻结键（会话存在时出现）============
                  if (state != CamState.idle) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 200,
                      height: 48,
                      child: provider.isMuted
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red.shade600,
                              ),
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.videocam_off),
                              label: const Text('已冻结 · 点按恢复'),
                            )
                          : OutlinedButton.icon(
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.videocam_off),
                              label: const Text('冻结画面'),
                            ),
                    ),
                  ],

                  // ============ ⑥ 错误提示（有才显示）============
                  if (provider.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      provider.errorMessage!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],

                  const SizedBox(height: 28),

                  // ============ ⑦ 参数信息行 ============
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        children: [
                          _InfoRow(
                            label: '当前画质',
                            value: provider.qualityText,
                          ),
                          _InfoRow(
                            label: '镜头',
                            value: provider.facingText,
                          ),
                          _InfoRow(
                            label: '上行状态',
                            value: isLive
                                ? '取景上行中'
                                : (isStarting
                                    ? '正在开启相机…'
                                    : (isStandby
                                        ? '待命 · 相机硬件已关闭'
                                        : '未启用')),
                            highlight: isLive,
                          ),
                          _InfoRow(
                            label: '电脑观看',
                            value: !provider.hasSession
                                ? '—'
                                : (provider.serverLive
                                    ? (provider.isMuted
                                        ? '正在观看（已冻结）'
                                        : '正在观看')
                                    : '空闲'),
                            highlight:
                                provider.hasSession && provider.serverLive,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 使用提示：告诉用户 PC 那头怎么选设备
                  Text(
                    '电脑上的会议 / 相机 / 直播软件，把摄像头选为\n'
                    '"Unity Video Capture" 即可\n'
                    '（启用守护后手机待命；电脑一打开观看手机才开相机，\n'
                    '电脑关闭观看后手机立即熄灭相机）',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                          height: 1.6,
                        ),
                  ),

                  // iOS 平台差异提示（安卓不显示这块）。
                  // 原因：苹果系统硬性规定，App 退到后台或锁屏后
                  // 【不允许继续采集相机】（麦克风可以，相机不行）。
                  // 所以 iPhone 上"守护/后台待命"对摄像头无效，必须亮屏
                  // 停在本页 —— 与其让用户以为守护失灵，不如明说。
                  if (Platform.isIOS)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'iPhone 注意：受 iOS 系统限制，摄像头必须在\n'
                        '本页面亮屏待命才能推流（退后台/锁屏会断），\n'
                        '麦克风与喇叭不受此限制',
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
// _PreviewCard —— 取景预览卡（带红色"硬件开着"横幅 + 全屏按钮）
// ----------------------------------------------------------------------------
// AspectRatio(4:3)：预留一块固定比例的取景窗。
// Image.memory：把 JPEG 字节直接解码显示（Flutter 内置解码器）。
//   gaplessPlayback: true —— 新帧到达前继续显示旧帧，预览不闪黑。
// previewJpeg 为 null（未开相机）→ 显示灰色占位：相机硬件真的没开。
// ============================================================================
class _PreviewCard extends StatelessWidget {
  final Uint8List? previewJpeg;
  final bool isLive;
  final VoidCallback onFullscreen;

  const _PreviewCard({
    required this.previewJpeg,
    required this.isLive,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity, // 撑满父级宽度（Padding 之内）
        decoration: BoxDecoration(
          color: Colors.black, // 取景窗外圈：黑
        ),
        child: Column(
          children: [
            // ── 红色横幅：只有相机硬件真的开着才出现（隐私可见性承诺）──
            if (isLive)
              Container(
                width: double.infinity,
                color: Colors.red.shade600,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.fiber_manual_record,
                        color: Colors.white, size: 12),
                    SizedBox(width: 6),
                    Text(
                      'REC · 电脑正在使用你的摄像头',
                      style: TextStyle(
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
                      ? const Center(
                          child: Icon(
                            Icons.videocam_off,
                            color: Colors.white24,
                            size: 56,
                          ),
                        )
                      : Image.memory(
                          previewJpeg!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                ),
                // 全屏按钮（设计稿：取景预览支持全屏）
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.fullscreen,
                          color: Colors.white, size: 22),
                      tooltip: '全屏预览',
                      onPressed: onFullscreen,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// _FullscreenPreviewScreen —— 全屏取景页（v3.4.1：真·全屏）
// ----------------------------------------------------------------------------
// v3.4.1 改动（用户反馈："全屏没有真正做到全屏…要自动旋转…
// 就像播放视频时一样的效果"）：
//   ① 画面铺满：Image 的 fit 从 contain（完整显示→留黑边）改成
//      cover（铺满整屏→超出边缘裁掉）。
//   ② 强制横屏：像视频播放器一样 —— 一进全屏屏幕立刻自动转成横向
//      （setPreferredOrientations 只给两个横屏方向，系统"自动旋转"
//      锁着也会转），左右横躺都能拿；退出恢复竖屏。
//   ③ 沉浸式：隐藏状态栏 + 导航栏（immersiveSticky：从顶部/底部
//      划一下可临时唤出，松手自动收回，不打扰取景）。
// 因此从 StatelessWidget 升级为 StatefulWidget —— 只有它有"进场设置、
// 退场恢复"这种带生命周期的需求（build 里做副作用是 Flutter 大忌）。
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
    // 进入全屏：只允许两个横屏方向 → 屏幕像视频播放器一样立刻自动
    // 横过来（即使系统"自动旋转"是关的也生效）；左右横躺均可。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // 沉浸式全屏：藏起状态栏/导航栏，整块屏幕都留给画面
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
          final jpeg = provider.previewJpeg;
          return Stack(
            fit: StackFit.expand,
            children: [
              jpeg == null
                  ? const Center(
                      child: Icon(Icons.videocam_off,
                          color: Colors.white24, size: 72),
                    )
                  : Image.memory(
                      jpeg,
                      // v3.4.1：cover = 画面撑满整块屏幕（多余边缘裁掉）；
                      // 之前的 contain 会完整显示 → 上下/左右留大黑边
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
              // 顶部红色横幅（硬件开着才见）——避开刘海/圆角安全区。
              // 注意：Positioned 必须是 Stack 的【直接】子组件，
              // 不能包 SafeArea/Padding（那会让它找不到 Stack 父级，
              // release 模式整页渲染成灰块 —— v3.4.1 首版踩过的坑）。
              // 安全区留白改用 MediaQuery.padding 手动加进 top 偏移。
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
                      child: const Text(
                        'REC · 电脑正在使用你的摄像头',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              // 退出按钮：同样用 MediaQuery.padding 避开安全区，保持 Positioned 直挂 Stack
              Positioned(
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 24,
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white, size: 26),
                    tooltip: '退出全屏',
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

/// 信息行小组件：左灰色标签、右蓝色值（与 mic_screen 同款套路）
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _InfoRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: highlight
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
