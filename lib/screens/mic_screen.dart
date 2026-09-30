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
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/device_provider.dart';
import '../providers/mic_provider.dart';
import '../widgets/device_gate.dart';

// v3.7 国际化：文案表
import '../l10n/app_localizations.dart';

/// 麦克风模式页。
/// StatelessWidget：会动的数据都住在 MicProvider 里，Consumer 一变就重建整页。
class MicScreen extends StatelessWidget {
  const MicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const DevicePageTitle(device: PcDevice.mic),
        centerTitle: true,
      ),
      body: Consumer<MicProvider>(
        builder: (context, provider, child) {
          // v3.7：本文件所有给用户看的句子都从 l10n 取
          final l10n = AppLocalizations.of(context);
          final errorText = provider.errorOf(l10n);
          final state = provider.state;
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
                  const DeviceGate(device: PcDevice.mic),
                  const SizedBox(height: 20),

                  // ============ ①' 缺权限提示（系统授权，不是功能开关）============
                  // 连上了但从没授权过录音：给一个明确的按钮，用户主动点击
                  // 才弹系统权限窗（符合 Android 规范，不突袭式弹窗）。
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
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
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
    for (var i = 0; i < bars.length; i++) {
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
