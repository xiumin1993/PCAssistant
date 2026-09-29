// ============================================================================
// mic_screen.dart —— 手机麦克风详情页（v3.3 按需录音版）
// ----------------------------------------------------------------------------
// 界面结构（自上而下）：
//   AppBar 标题
//   └─ 大圆形状态按钮（idle 蓝=启用 / standby 灰蓝=待命中 / starting 转圈 /
//      live 红=正在录音，点我停）
//   └─ 状态文案（+ 缺权限时的"启用麦克风"按钮）
//   └─ 静音键（会话存在时出现；v3.3 按下 = 真关麦克风硬件）
//   └─ 电平条（CustomPaint 自绘，数据来自 MicProvider.bars）
//   └─ 参数信息行（采样率 / 回声消除 / 上行状态 / 电脑使用）
//
// v3.3 行为：连上电脑 = 自动待命（麦克风【关】，不录音不耗电）；
// 电脑上的应用一打开麦克风 → 服务器推送信号 → 手机才开录；
// 电脑一关 → 手机立马停回待命。本页是"详情 + 手动控制"——
// 什么都不点也能用；想强制闭麦按静音，想彻底注销按大按钮。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mic_provider.dart';

/// 麦克风模式页。
/// StatelessWidget 即可：会动的数据都住在 MicProvider 里，
/// Consumer 一变就重建整页，对这个简单页面完全够用。
class MicScreen extends StatelessWidget {
  const MicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('麦克风模式'),
        centerTitle: true,
      ),
      body: Consumer<MicProvider>(
        builder: (context, provider, child) {
          // 四态映射：按钮颜色 / 图标 / 提示都随 state 变
          final state = provider.state;
          final isLive = state == MicState.live;
          final isStandby = state == MicState.standby;
          final isStarting = state == MicState.starting;
          final buttonColor = isLive
              ? Colors.red.shade600 // 录音中：红色 = "正在录，点我停"
              : (isStarting
                  ? Colors.blueGrey.shade200 // 开麦瞬间：灰 = 别急
                  : (isStandby
                      ? Colors.blueGrey.shade400 // 待命：沉稳灰蓝 = 硬件关着，随时待唤醒
                      : Colors.blue.shade600)); // 未启用：蓝 = 点我启用

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ============ ① 大圆形状态按钮 ============
                  // 用 InkWell + 圆形 Container 拼一个"自定义形状按钮"：
                  //   Material —— 提供点击水波纹效果（墨渍扩散动画）
                  //   Ink     —— 让波纹能画到 Container 背景之下
                  //   Container —— 圆形（shape: BoxShape.circle）
                  // v3.1 它主要起"状态灯"作用，点击 = 手动开/关总开关。
                  Material(
                    color: Colors.transparent,
                    child: Ink(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        color: buttonColor,
                        shape: BoxShape.circle, // 圆形装饰
                        // 阴影：营造"悬浮按钮"立体感（Material 语言经典元素）
                        boxShadow: [
                          BoxShadow(
                            color: buttonColor.withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: InkWell(
                        // borderRadius 与外圆一致，水波纹才被裁成圆形
                        customBorder: const CircleBorder(),
                        // starting（正在启动）禁用点击，null = 自动置灰
                        onTap: provider.isBusy ? null : () => provider.toggle(),
                        child: Center(
                          // 四态内容：转圈 / 停止方块 / 待命双竖线 / 麦克风
                          child: isStarting
                              ? const SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                )
                              : Icon(
                                  isLive
                                      ? Icons.stop
                                      : (isStandby ? Icons.pause : Icons.mic),
                                  size: 56,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // ============ ② 状态文案 ============
                  Text(
                    provider.statusText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),

                  // ============ ②' 静音键（v3.1，像通话软件里的闭麦）============
                  // 只要会话存在（启动中/上行中）就出现：idle 下没有可静音的会话。
                  // 按下 = 会话保持但不再上传声音；再按恢复。
                  // 与首页"麦克风守护"开关的分工：
                  //   守护开关 = 装/拆这颗麦克风；静音键 = 临时闭嘴。
                  if (provider.state != MicState.idle) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 200,
                      height: 48,
                      child: provider.isMuted
                          // 静音中：实心红底白字，醒目提示"现在是闭麦状态"
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red.shade600,
                              ),
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.mic_off),
                              label: const Text('已静音 · 点按开麦'),
                            )
                          // 未静音：描边按钮，不打扰主视觉
                          : OutlinedButton.icon(
                              onPressed: () => provider.toggleMute(),
                              icon: const Icon(Icons.mic),
                              label: const Text('静音'),
                            ),
                    ),
                  ],

                  // ============ ③ 错误提示（有才显示）============
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

                  const SizedBox(height: 32),

                  // ============ ④ 电平条（自绘组件）============
                  // SizedBox 给 CustomPaint 一个明确的宽高——
                  // 画布类组件自己"不占空间"，必须外层限定尺寸。
                  SizedBox(
                    width: 280,
                    height: 44,
                    child: CustomPaint(
                      painter: _LevelBarsPainter(bars: provider.bars),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // ============ ⑤ 参数信息行 ============
                  // Card 包一组 ListTile：Material 标准的"信息列表"样式
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        children: [
                          // v3.4.4：采样率从"死文案"升级为可点下拉框。
                          // 48k = 与电脑声卡一致、服务器逐样本直通（默认推荐）；
                          // 44.1k = 部分录音 App/声卡的常见档，服务器自动重采样。
                          // 切换即时生效（正在录音会有约 100ms 的静默重启间隙）。
                          Row(
                            children: [
                              const Expanded(
                                child: Text('采样率',
                                    style: TextStyle(color: Colors.black54)),
                              ),
                              DropdownButton<int>(
                                value: provider.sampleRate,
                                items: const [
                                  DropdownMenuItem(
                                    value: 48000,
                                    child: Text('48 kHz · 直通'),
                                  ),
                                  DropdownMenuItem(
                                    value: 44100,
                                    child: Text('44.1 kHz · PC 重采样'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null) provider.setSampleRate(v);
                                },
                              ),
                            ],
                          ),
                          _InfoRow(
                            label: '声道',
                            value: '单声道',
                          ),
                          _InfoRow(
                            label: '回声消除',
                            value: isLive ? '开（通话链路）' : '待机',
                          ),
                          _InfoRow(
                            label: '上行状态',
                            value: isLive
                                ? '录音上行中'
                                : (isStarting
                                    ? '正在开麦…'
                                    : (isStandby
                                        ? '待命 · 麦克风硬件已关闭'
                                        : '未启用')),
                            highlight: isLive,
                          ),
                          // v3.3：电脑端占用状态（服务器音频会话枚举推送）。
                          // "正在使用" = 手机麦克风此刻真的开着在收音；
                          // "空闲"     = 没人在用，手机硬件关闭待命。
                          _InfoRow(
                            label: '电脑使用',
                            value: !provider.hasSession
                                ? '—'
                                : (provider.serverLive
                                    ? (provider.isMuted
                                        ? '正在使用（已静音）'
                                        : '正在使用')
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
                    '电脑上的会议 / 语音输入软件，把输入设备选为\n"CABLE Output (VB-Audio Virtual Cable)" 即可\n（连上电脑后手机自动待命；电脑一用麦克风手机才开录，\n电脑停用后手机立刻停止录音）',
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

/// 信息行小组件：左灰色标签、右蓝色值。
/// 抽成私有 Widget 而不是复制粘贴三遍 —— DRY 原则
/// （Don't Repeat Yourself）。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight; // 值是否用主色强调

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
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: highlight
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
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
      final h = level < 0.02 ? 3.0 : (level * (size.height - 4)).clamp(4.0, size.height);
      final x = size.width - (i + 1) * step; // 右起第 i 根的位置
      if (x < 0) break; // 画到左边缘就停（历史比画布长）

      // 有声音用主题蓝，静音用浅灰 —— 一眼区分"在听"和"没声"
      paint.color = level < 0.02
          ? const Color(0xFFD0DFFF)
          : const Color(0xFF2563EB);

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
