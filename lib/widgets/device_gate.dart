// ============================================================================
// device_gate.dart —— 设备"状态明说块"（三台设备的详情页顶部共用）
// ----------------------------------------------------------------------------
// 为什么要有这个组件？（这是本轮改版最核心的一块）
//   Material 自带的 Switch 在"关"的时候是灰白色的，用户根本分不清
//   "灰 = 我关掉了"还是"灰 = 还没开始"。用户明确要求：
//     "手动禁用要更明确点显示当前是禁用还是启用状态"
//   所以这里不靠颜色说话，而是把状态【写成字】：
//     大字标题：已禁用 / 已启用 · 待命 / 已启用 · 使用中 / 已启用 · 未连接
//     开关左右两端写清楚"拨到这边是什么"，
//     下面一行说明"现在的后果"（禁用后电脑再怎么调都唤不起它）。
//
// 开关方向的统一约定（很重要，全项目照此对齐）：
//   与 Flutter Switch 的默认语义一致 —— 滑块在【右侧】= 开 = 启用（绿），
//   滑块在【左侧】= 关 = 禁用（红）。
//   所以左右标注固定是：左边"← 禁用"，右边"启用（默认）→"。
//
// 文件位置：lib/widgets/ —— widgets 目录专门放"跨页面复用的小组件"，
// 和 screens（整页）、providers（逻辑）、services（干活）并列。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/device_provider.dart';

/// 一台设备的总闸卡片。
/// 用 StatelessWidget：状态都住在 DeviceProvider，本页组件只负责画。
class DeviceGate extends StatelessWidget {
  final PcDevice device;

  const DeviceGate({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, dev, _) {
        // v3.7：在界面层取当前语言的文案表，再传给 DeviceProvider 的翻译方法。
        // 这就是本项目 i18n 的分工：逻辑层存"键"和"状态"，界面层负责"成句"。
        final l10n = AppLocalizations.of(context);
        final on = dev.isEnabled(device);
        final status = dev.statusOf(device);
        // 配色：启用绿 / 禁用红。使用中的设备额外用蓝色把"正在干活"标出来。
        final accent = status == DeviceUiStatus.active
            ? const Color(0xFF1565C0)
            : (on ? const Color(0xFF0F8A43) : const Color(0xFFC62828));

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            // 浅色底 + 同色描边：整块卡随状态变色，隔着几步路也能扫出来
            color: accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 第一行：设备名 + 大字状态 ──
              Row(
                children: [
                  Icon(dev.iconOf(device), color: accent, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    // gateHeadlineOf = "已启用 · 使用中" 这类两段式状态词，
                    // 前段回答"我开没开"，后段回答"现在在不在干活"。
                    child: Text(
                      dev.gateHeadlineOf(l10n, device),
                      style: TextStyle(
                        color: accent,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),

              // ── 第二行：开关本体 + 左右端标注 ──
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    // 左端标注：禁用
                    Text(
                      on ? l10n.gateOff : l10n.gateOffCurrent,
                      style: TextStyle(
                        fontSize: 12,
                        color: on ? Colors.black38 : const Color(0xFFC62828),
                        fontWeight: on ? FontWeight.w500 : FontWeight.w800,
                      ),
                    ),
                    const Spacer(), // 把开关推到中间偏右
                    // activeColor/activeTrackColor：开关"打开"时的圆点/轨道颜色
                    Switch(
                      value: on,
                      // activeThumbColor：滑块"圆点"的颜色；
                      // activeTrackColor：滑轨的颜色（绿 = 启用）
                      activeThumbColor: Colors.white,
                      activeTrackColor: const Color(0xFF0F8A43),
                      inactiveThumbColor: Colors.white,
                      inactiveTrackColor: const Color(0xFFC62828),
                      // 只调用 setEnabled：拨闸 → 注销/登记会话由 Provider 执行
                      onChanged: (v) => dev.setEnabled(device, v),
                    ),
                    const Spacer(),
                    // 右端标注：启用
                    Text(
                      on ? l10n.gateOnCurrent : l10n.gateOn,
                      style: TextStyle(
                        fontSize: 12,
                        color: on ? const Color(0xFF0F8A43) : Colors.black38,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              // ── 第三行：后果说明（一句话说清现在这个状态意味着什么）──
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  dev.gateSubtextOf(l10n, device),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 参数区里"这一行在某个状态下能不能改"的说明小字（原型里的 .hint）。
/// 摄像头页待命时参数全开，需要一句话解释"改了会怎样"，
/// 否则用户会以为点了没反应。
class ParamHint extends StatelessWidget {
  final String text;

  const ParamHint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.black54, height: 1.5),
      ),
    );
  }
}

/// 详情页的通用信息行：左灰色标签、右深色值（三台设备页共用一份，
/// 避免同一个样式在三个文件里各写一遍还写歪）。
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const InfoRow({
    super.key,
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

/// 详情页顶栏标题：设备名 + 状态胶囊，保证和首页卡片说的是同一句话。
class DevicePageTitle extends StatelessWidget {
  final PcDevice device;

  const DevicePageTitle({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, dev, _) {
        final l10n = AppLocalizations.of(context);
        final color = dev.statusColor(device);
        return Row(
          mainAxisSize: MainAxisSize.min, // 只占内容宽度，不拉伸
          children: [
            Text(dev.nameOf(l10n, device)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                dev.statusLabelOf(l10n, device),
                style: TextStyle(
                    fontSize: 11, color: color, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      },
    );
  }
}
