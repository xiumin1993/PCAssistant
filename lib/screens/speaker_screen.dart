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
// ----------------------------------------------------------------------------
// 新手导读：这一页的数据从哪条路来（本页不碰一个音频字节）
// ----------------------------------------------------------------------------
// PCM 字节流的真实路线：
//   电脑抓系统声音 → WebSocket(NetworkService 的 audioDataStream) →
//   ConnectionProvider 里那个"音频数据监听"把字节喂给
//   AudioService.receiveAudioData() → 原生 AudioTrack 实时播放。
//   本页只是那台播放机的【仪表盘】：读 AudioService 的几个 getter
//   （采样率/声道/标称码率/已收字节/是否在播）画出来，一个控制都不下。
// "只有一个开关"的产品规则（为什么整页找不到"启用/停止"按钮）：
//   全 App 每台设备唯一的开关就是页首那个 DeviceGate 大闸门；
//   页面里旧的启用/停止按钮已全部删除——两处开关必然有一处骗人。
//   音响页保留的"本机静音"不算第二个否决权：它只是播放参数
//   （类似音箱上的 MUTE），会话照留、电脑侧毫不知情。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';
import '../providers/device_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_service.dart';
import '../widgets/device_gate.dart';
// show PulsingDot：从 home_screen.dart 只导入【这一个】符号，
// 不是把整个文件的公开成员都拖进来——两个文件有同名东西时不会打架。
import 'home_screen.dart' show PulsingDot;

/// 音响模式页
class SpeakerScreen extends StatelessWidget {
  const SpeakerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶栏标题不放 Text 而放 DevicePageTitle（widgets/device_gate.dart）：
      // "设备名 + 状态胶囊"和首页入口卡读同一份 statusLabelOf，
      // 两处永远不会一个说"待命"一个说"使用中"。
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
          // 这三行取数据的方式值得对比着记（provider 包的三件套）：
          //   dev   —— 外层 Consumer<DeviceProvider> 送进来的，订阅式：
          //            设备账本一变，整页 builder 重跑；
          //   audio —— context.read：只拿对象、不订阅。AudioService 本来
          //            就不是 ChangeNotifier，订了也不会被通知，read 是唯一
          //            合理姿势；页面上的数字靠"本页因别的原因重建时顺手
          //            重读"保持新鲜。
          //   conn  —— 同样 read：ConnectionProvider 的变化会经 DeviceProvider
          //            的转发监听再通知到本页，所以无需在这里重复订阅。
          // 若把 audio/conn 画的东西错用 read 且没有任何订阅链，就会得到
          // "数据变了界面不动"的经典坑——这里能安全用 read 全靠上面那条转发。
          final audio = context.read<AudioService>();
          final conn = context.read<ConnectionProvider>();
          // active（使用中）的判定只认 statusOf 一个出口：= 在播且没被本机静音
          // （判断式就住在 DeviceProvider.statusOf 里）。下面的图标、呼吸点、
          // 高亮全读这一个布尔，保证"图标在响 ↔ 徽标写着播放中"严格同步。
          final playing = dev.statusOf(PcDevice.speaker) == DeviceUiStatus.active;

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              // Column 的 crossAxisAlignment 改成了 stretch（首页那列用默认 center）：
              // stretch = 交叉轴（水平）方向把孩子【拉满整幅可用宽度】，
              // 于是闸门、卡片都是通栏矩形，而不是缩成内容那么宽。
              // 外层仍是 Center + 滚动容器：比屏幕矮就居中、高就能滑，不会溢出。
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
                    // SwitchListTile = 自带滑动开关的 ListTile：
                    //   secondary → 行首图标槽（相当于 ListTile 的 leading），
                    //   title / subtitle → 主副两行文字，
                    //   value → 开关此刻的状态（数据驱动，开关自己不管账），
                    //   onChanged → 用户拨完后把【新的布尔值】递进来。
                    // value 读 dev.speakerMuted、改动写回 Provider，
                    // 这一来一回就是"受控组件"：界面永远跟着账本走，
                    // 不会出现"图上开着、其实静音了"的错位。
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
                  // 四行读数的来源，一行一个对应关系：
                  //   来源   —— 电脑抓的是系统声音回环（所以不需要你在电脑上选播放设备）；
                  //   格式   —— audio.sampleRate/1000 变 kHz 再 toStringAsFixed(1)
                  //              保留一位小数，声道名按 channelCount==1 挑 mono/stereo；
                  //   码率   —— nominalBitrateMbps 是"采样率×声道×16bit"算出的理论值，非实测；
                  //   已接收 —— audio.bytesReceived 的累计字节数，交给 _fmtBytes 换单位。
                  // 最后那行"播放状态"是嵌套三元表达式：
                  //   没连接→断开文案；在播且静音→已静音；在播→播放中；其余→等待数据。
                  // InfoRow / ParamHint 都来自 widgets/device_gate.dart，
                  // 三台设备页共用同一套行样式，不会各写各的写歪。
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
                  // 音量条/缓冲档位为什么在这页改不了（也压根没摆出来）：
                  //   这两个参数作用在原生 AudioTrack（Android 侧播放机）上，
                  //   要开放得先扩 MethodChannel 桥，本轮没有实现；
                  //   设计取舍：宁可放一行说明解释"这里为什么没有"，
                  //   也不留一个只能看不能用的假控件骗人。
                  //   将来开放时，写操作照旧从 Provider 层走一个明确出口
                  //   （参照静音的 dev.setSpeakerMuted），界面不直碰底层。
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
