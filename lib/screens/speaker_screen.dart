// ============================================================================
// speaker_screen.dart —— 音响详情页（v3.6 新增：电脑声音 → 手机播放）
// ----------------------------------------------------------------------------
// 界面结构（自上而下，对应已批准的原型 design/device-pages-v3.6.html 第 ② 屏）：
//   AppBar：设备名 + 状态胶囊（和首页卡片读同一份翻译）
//   └─ DeviceGate   状态明说块：大字"已启用 · 正在播放"+ 启用/禁用滑块
//   └─ 播放可视化    大喇叭图标 + 一句话，使用中给呼吸圆点
//   └─ 参数与信息    采样率 / 声道 / 链路速率 / 已接收 / 本机静音
//   └─ 使用提示      电脑那头不用选设备（服务器抓的是系统声音回环）
//
// 为什么音响页这么简单？因为"电脑推什么就播什么"，手机侧没有可协商的
// 输入参数（不像麦克风有采样率、摄像头有清晰度）。真正需要手动调的
// 音量与缓冲档位要改原生 AudioTrack，本轮暂未开放（见下方 hint）。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';
import '../providers/device_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_service.dart';
import '../widgets/device_gate.dart';
import 'home_screen.dart' show PulsingDot;

/// 音响模式页
class SpeakerScreen extends StatelessWidget {
  const SpeakerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const DevicePageTitle(device: PcDevice.speaker),
        centerTitle: true,
      ),
      body: Consumer<DeviceProvider>(
        // 整页订阅 DeviceProvider：它的通知来自三个底层 Provider，
        // 所以"电脑开始推声音了"这类变化会自动把本页（含下面的 AudioService
        // 读数）一起刷新，不需要给 AudioService 单独再做一层订阅。
        builder: (context, dev, _) {
          // l10n = 当前语言的文案表。整页只取一次，往下传给各个 Text，
          // 这样这个文件里就不会再出现任何硬编码的中文/英文句子。
          final l10n = AppLocalizations.of(context);
          final audio = context.read<AudioService>();
          final conn = context.read<ConnectionProvider>();
          final playing = dev.statusOf(PcDevice.speaker) == DeviceUiStatus.active;

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ============ ① 状态明说块（启用 / 禁用总闸）============
                  const DeviceGate(device: PcDevice.speaker),
                  const SizedBox(height: 20),

                  // ============ ② 播放可视化 ============
                  Container(
                    // 左右各留 16：英文文案比中文长一截（"连接电脑后自动进入待命"
                    // → "Goes to standby automatically once the PC is connected"），
                    // 不留内边距时整行会顶到卡片圆角上，看着像被裁掉了。
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F8FB),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          // 静音时用带斜杠的喇叭，避免"图标在响、其实没声"的误导
                          dev.speakerMuted
                              ? Icons.volume_off
                              : (playing ? Icons.volume_up : Icons.volume_down),
                          size: 48,
                          color: playing && !dev.speakerMuted
                              ? const Color(0xFF1565C0)
                              : Colors.black38,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 真的在出声才给呼吸红点（视觉与硬件状态严格一致）
                            if (playing && !dev.speakerMuted) ...[
                              const PulsingDot(
                                  color: Color(0xFF1565C0), size: 8),
                              const SizedBox(width: 8),
                            ],
                            // Flexible：让长文案在 Row 里换行，而不是撑出卡片
                            // （Row 的普通子组件不参与伸缩，必须包一层）
                            Flexible(
                              child: Text(
                                dev.detailLineOf(l10n, PcDevice.speaker),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.black54),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ============ ③ 本机静音（临时，会话保留）============
                  // 和上面的总闸分工：总闸 = 拆掉这条链路；静音 = 暂时不听。
                  Card(
                    margin: EdgeInsets.zero,
                    child: SwitchListTile(
                      secondary: Icon(
                          dev.speakerMuted ? Icons.volume_off : Icons.volume_up,
                          color: dev.speakerMuted
                              ? const Color(0xFFC62828)
                              : Theme.of(context).colorScheme.primary),
                      title: Text(l10n.spkMuteTitle),
                      subtitle: Text(l10n.spkMuteSubtitle),
                      value: dev.speakerMuted,
                      onChanged: (v) => dev.setSpeakerMuted(v),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ============ ④ 链路参数（全部来自真实读数，不写死）====
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        children: [
                          InfoRow(
                            label: l10n.spkSourceLabel,
                            value: l10n.spkSourceValue,
                          ),
                          InfoRow(
                            label: l10n.spkFormatLabel,
                            // 采样率数字 + 声道名 + 位深：整句交给文案表，
                            // 界面只负责把"读数"填进去。
                            value: l10n.spkFormatValue(
                              (audio.sampleRate / 1000).toStringAsFixed(1),
                              audio.channelCount == 1
                                  ? l10n.audioMono
                                  : l10n.audioStereo,
                            ),
                          ),
                          InfoRow(
                            label: l10n.spkBitrateLabel,
                            value: l10n.spkBitrateValue(
                                audio.nominalBitrateMbps.toStringAsFixed(2)),
                          ),
                          InfoRow(
                            label: l10n.spkReceivedLabel,
                            value: _fmtBytes(audio.bytesReceived),
                          ),
                          InfoRow(
                            label: l10n.spkPlayStatusLabel,
                            value: !conn.isConnected
                                ? l10n.spkPlayDisconnected
                                : (audio.isPlaying
                                    ? (dev.speakerMuted
                                        ? l10n.spkPlayMuted
                                        : l10n.spkPlayPlaying)
                                    : l10n.spkPlayWaiting),
                            highlight: playing,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ============ ⑤ 本版未开放的参数：明说，不留空位 ============
                  ParamHint(text: l10n.spkParamsLocked),
                  const SizedBox(height: 16),

                  // ============ ⑥ 使用提示 ============
                  Text(
                    l10n.spkHowToUse,
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

  /// 字节数转成人类可读的字符串（B / KB / MB）。
  /// 手写而不是引第三方库：只有这一个地方用，12 行解决，不值得加依赖。
  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
