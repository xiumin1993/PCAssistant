// ============================================================================
// language_sheet.dart —— 语言选择弹层（v3.7 国际化）
// ----------------------------------------------------------------------------
// 为什么做成"底部弹层"而不是单独一个页面？
//   它只有一个设置项，占一整页太空；BottomSheet 从下面滑出、点完即收，
//   是 Android/iOS 都熟悉的"轻量设置"手势，用户不用学。
//
// 三档语义和电脑端 AudioServer 的 LANGUAGE 卡完全一致：
//   跟随系统（默认）/ English / 简体中文
//   当前生效的那一档右侧打勾；"跟随系统"下面额外补一行小字，
//   告诉用户系统语言被识别成了什么 —— 不然他不知道"跟随"跟到了哪儿。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/language_provider.dart';

/// 弹出语言选择层。在任意页面 `showLanguageSheet(context)` 即可。
Future<void> showLanguageSheet(BuildContext context) {
  // showModalBottomSheet：从屏幕底部滑出的模态层。
  //   context   —— 从这里往上找最近的 MaterialApp，弹层挂在它下面
  //   builder   —— 弹层内容；注意这里的 context 是【弹层自己的】context，
  //                用它取 AppLocalizations 才拿得到正确语言（外层 context
  //                在 Localizations 边界之上时会取到旧值）。
  return showModalBottomSheet<void>(
    context: context,
    // 浅色背景跟随主题；圆角让它看起来是"卡片"而不是硬贴上来的一块
    showDragHandle: true,
    builder: (sheetContext) => const _LanguageSheet(),
  );
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet();

  @override
  Widget build(BuildContext context) {
    // l10n：本项目取文案的统一入口。
    // AppLocalizations.of(context) 会沿着 Widget 树往上找到 Localizations，
    // 返回当前语言对应的那个实例（en 或 zh）。
    final l10n = AppLocalizations.of(context);
    final lang = context.watch<LanguageProvider>();

    // 三个选项：(档位, 显示名)。
    // "跟随系统"的名字来自 l10n（要翻译），
    // English / 简体中文 是母语名，故意【不】翻译 —— 全世界都这么干，
    // 因为用户只有用自己的母语才认得出那是自己的语言。
    final items = <(LanguageChoice, String)>[
      (LanguageChoice.auto, l10n.langAuto),
      (LanguageChoice.en, 'English'),
      (LanguageChoice.zh, '简体中文'),
    ];

    return SafeArea(
      // SafeArea：把内容从刘海屏/底部手势条这些"危险区"里让开
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          // 弹层高度自适应内容（MainAxisSize.min），不占满半屏
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsTitle,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.languageTitle,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),

            // 每个档位一行：名字 + 右侧"当前生效"打勾。
            // 为什么用 ListTile 而不是 RadioListTile？
            //   1. Flutter 3.32 起 RadioListTile 的 groupValue/onChanged 被废弃，
            //      要改成外层套 RadioGroup —— 版本差异容易踩坑；
            //   2. 更重要的是本项目的一贯要求：状态要【写成字】，
            //      不能只靠"圆点填色"这种弱视觉暗示。这里直接给对勾 + 高亮字重，
            //      比单选圆点更好读。
            for (final (choice, label) in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    // 当前档位加粗：扫一眼就知道现在用的是哪个
                    fontWeight: lang.choice == choice
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
                // "跟随系统"下面补一行：系统语言被识别成了什么，
                // 用户才知道"跟随"到底跟到了哪儿。
                // 用 systemCode 而不是 effectiveCode：这行说的是【手机系统】，
                // 不是"我现在手动选了什么"（详见 LanguageProvider.systemCode）。
                subtitle: choice == LanguageChoice.auto
                    ? Text(
                        l10n.langAutoCurrent(_nativeName(lang.systemCode)),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black54, height: 1.4),
                      )
                    : null,
                trailing: lang.choice == choice
                    ? Icon(Icons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  context.read<LanguageProvider>().setChoice(choice);
                  // 选完立刻收起：语言已经实时生效，不需要"确定"按钮
                  Navigator.of(context).pop();
                },
              ),

            const SizedBox(height: 4),
            // 底部脚注：说明"通用缩写不翻译"这件事，
            // 免得英语用户看到界面上还有 WiFi/USB 以为是漏翻。
            Text(
              l10n.langHint,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 语言代码 → 母语名（'zh' → '简体中文'，'en' → 'English'）。
  /// 和上面列表同理：语言名一律用母语写，不随界面语言变。
  String _nativeName(String code) => switch (code) {
        'zh' => '简体中文',
        _ => 'English',
      };
}
