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
//
// 【为什么切语言不需要重启 App，但界面要重建？】
//   本项目所有文案都是各页面 build 时【现取】（AppLocalizations.of(context)），
//   没有任何"启动时读一次就缓存"的字符串。所以语言档位一变 →
//   LanguageProvider.notifyListeners → app.dart 的 Consumer 重建 MaterialApp
//   （locale 参数换了）→ Flutter 把 Localizations 整棵换成新词典、界面树
//   重画一遍。用户看到的是"瞬间全体换字"，零闪断、零重启。
//   有些 App 切语言靠杀进程伪重启，那是它们缓存了文案，本项目不需要。
//   （"重建界面" = rebuild 界面树，跟"重启 App"是两码事。）
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// ⚠ 警告：app_localizations.dart 由 `flutter gen-l10n` 从 lib/l10n/*.arb
// 自动生成，改它会被下次构建无声覆盖；要改 langAuto / settingsTitle 这类
// 文案，请改 app_en.arb 和 app_zh.arb（两边键名必须成对上）。
import '../l10n/app_localizations.dart';
import '../providers/language_provider.dart';

/// 弹出语言选择层。在任意页面 `showLanguageSheet(context)` 即可。
Future<void> showLanguageSheet(BuildContext context) {
  // 返回值 Future<void> 的含义：这个 Future 在弹层"被关掉的那一刻"完成
  // （无论用户是选了一档、点了遮罩、还是下滑划走）。
  // 所以调用方可以写 `await showLanguageSheet(context);` 等弹层收场后
  // 再做事；不 await 也没关系 —— 选语言在弹层内部就闭环了。
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

/// 弹层内部本体。Dart 里下划线开头的类名 = 库（文件）私有，
/// 其他文件看不见它 —— 对外只暴露 showLanguageSheet() 这一个入口，
/// 属于"把实现细节藏起来"的最小封装。
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
            // for (final (choice, label) in items) 是两个 Dart 新语法混用：
            //   集合-for —— 在 Widget 列表字面量里直接写循环，逐项展开成 ListTile；
            //   记录(record)解构 —— (choice, label) 拆开 (档位, 显示名) 这对
            //     "匿名二元组"（Dart 3 的 (A, B) 类型，不必为俩值单独建类）。
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
                // 这是最近修过的一个 bug 的正解：以前这行误用了 effectiveCode
                // （= 界面当前生效语言）。手机是中文系统、用户手动选了 English
                // 之后，effectiveCode 变成 'en'，界面就谎称"系统语言：English"——
                // 把用户的手动选择当成了系统的检测结果，且这行字再也不跟系统对齐。
                // 两个概念必须分开读：
                //   effectiveCode = 界面现在用什么语言（受手动档位影响）；
                //   systemCode    = 设备真实语言（永远不受 App 内选择污染）。
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
                  // context.read<T>()：一次性从 Provider 仓库取出对象、
                  // 只为调它的方法，不订阅变化 —— 回调/事件处理里永远用
                  // read 而不是 watch（watch 只能在 build 期间调用，这里
                  // 用了会直接抛异常）。
                  // 上面 build 开头的 context.watch<LanguageProvider>() 则
                  // 相反：取值 + 订阅，choice 一变整层重新画、勾跟着搬家。
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
