// ============================================================================
// language_provider.dart —— App 界面语言的"选择 + 记住"逻辑中心（v3.7 国际化）
// ----------------------------------------------------------------------------
// 它只管一件事：界面上该用哪种语言，以及把这个选择存到手机本地，
// 下次杀了 App 再打开还认。
//
// 三档语义（和电脑端 AudioServer 完全一致，两端行为好记）：
//   auto  跟随系统 —— 默认值。手机系统语言是中文就显示中文，其余一律英文。
//   en    用户手动指定英文
//   zh    用户手动指定简体中文
//
// 为什么"其余一律英文"？
//   本版只有中英两套文案。德语/日语系统若强行显示中文，用户一个字都看不懂；
//   落到英文至少大概率能读。将来加 locales/ja.arb，只要在 _resolve() 里补分支。
//
// 为什么用 ChangeNotifier 而不是普通类？
//   语言一换，整棵 Widget 树都要重建（MaterialApp 的 locale 变了），
//   Provider 订阅它的变化，界面才会真的刷新。
// ============================================================================
// ── 文件说明书（速览，初学者可先背这一段）──────────────────────────────
// 【管什么】用户选的语言档位（auto/en/zh 三档 enum）、算出传给 MaterialApp
//   的 locale、把选择持久化（SharedPreferences 键 app_language）。
// 【谁调用它】lib/app.dart 用 Consumer<LanguageProvider> 读 .locale 喂给
//   MaterialApp（订阅式，变了就重建）；设置弹层
//   lib/widgets/language_sheet.dart 用 context.watch 读 choice/systemCode
//   显示打勾和"系统语言：xx"，用 context.read().setChoice() 改档位。
// 【它调用谁】SharedPreferences（读/存档位）、MethodChannel
//   'com.pcspeaker/audio'（把档位告诉安卓原生层，同步通知栏文案语言）。
// 【状态怎么流转】setChoice → 改内存 → 存盘 → _syncNative → notifyListeners
//   → app.dart 的 Consumer 重建 MaterialApp（locale 变了）→ 全部文案换语言。
// 【关于 restartApp / 为什么切语言要"重建界面"】有的 App 切语言靠杀掉进程
//   再拉起（伪重启）来强制所有页面重新取文案；本项目不需要——文案都是
//   build 时现从 AppLocalizations 取的，MaterialApp 整树重建这一发就够了，
//   用户零闪断。"重建界面"指的就是这次 rebuild，不是真的重启 App。
// ============================================================================

import 'dart:io' show Platform; // Platform.isAndroid —— 只有安卓原生层需要同步

import 'package:flutter/material.dart'; // ChangeNotifier + Locale（material 已转出了 dart:ui 的 Locale）
import 'package:flutter/services.dart'; // MethodChannel：把语言选择告诉安卓原生层
import 'package:shared_preferences/shared_preferences.dart';

/// 用户可选的语言档位。
/// 用 enum 而不是裸字符串：写错 'auti' 编译期就报错。
enum LanguageChoice { auto, en, zh }

class LanguageProvider extends ChangeNotifier {
  /// SharedPreferences 里的键名。集中成常量，将来改键名只改一处。
  static const String _prefsKey = 'app_language';

  /// 与安卓原生层共用的通道（就是播放/录音用的那条，不新开通道）。
  /// 原生层用它来决定【通知栏文案】的语言 —— Flutter 的 l10n 管不到
  /// 系统渲染的那几行字（前台服务常驻通知、桌面应用名）。
  // MethodChannel 是什么：Dart 世界和原生世界（Kotlin/Swift）之间的"电话线"。
  // invokeMethod('方法名', 参数Map) 发一条指令过去，原生端注册的 handler 执行。
  // 通道名是两端约定的字符串暗号，改任何一端都必须同步改另一端，否则调用
  // 会静默失败或抛 MissingPluginException。
  static const MethodChannel _native = MethodChannel('com.pcspeaker/audio');

  LanguageChoice _choice = LanguageChoice.auto;

  /// 系统语言（从 MediaQuery/PlatformDispatcher 读一次即可，运行期不会变）。
  /// 为什么不让本类去读 platform dispatcher？
  /// 因为 Widget 层随时能拿到 `WidgetsBinding.instance.platformDispatcher.locale`，
  /// 但为了"界面不依赖 context 也能算出该用哪种语言"，这里在构造时抓一份快照。
  // 补充：这就是"读设备真实语言"的官方入口 ——
  // WidgetsBinding.instance.platformDispatcher 是 Dart 通往操作系统的大门，
  // .locale 给手机当前第一语言（.locales 复数版是整个偏好列表，取首志愿即可）。
  // 它反映【手机系统】的语言，与 App 内手动选择无关，所以放进 systemCode 恰如其分。
  // 存成 final 快照后运行期不再变：用户改手机语言一般会重启 App，天然覆盖。
  final Locale _systemLocale;

  // 构造函数的可空参数 {Locale? systemLocale}：正式启动不传（=null），
  // ?? 右边就顶上、去读真实系统语言；单元测试可以塞一个假 Locale 进来
  // 模拟"中文手机/英文手机"，这叫依赖注入的可测试性设计。
  // 冒号后的初始化列表：final 字段进函数体前必须赋完值（同 connection_provider 讲过）。
  LanguageProvider({Locale? systemLocale})
      : _systemLocale =
            systemLocale ??
            WidgetsBinding.instance.platformDispatcher.locale {
    _load();
  }

  // --------------------------------------------------------------------------
  // 对外只读接口
  // --------------------------------------------------------------------------

  /// 用户当前选的是哪一档（设置页要打勾的就是它）
  LanguageChoice get choice => _choice;

  /// 传给 MaterialApp 的 locale。
  ///
  /// 关键：auto 时返回 **null**，意思是"我不指定，Flutter 自己去系统里挑"。
  /// 这比自己算 Locale 更省事，也是官方推荐做法 ——
  /// MaterialApp 会拿系统语言去 supportedLocales 里做匹配。
  // 三元表达式速记：条件 ? A : B。auto → null（不干预）；
  // 否则 Locale(_choice.name) —— _choice.name 把枚举转成 'en'/'zh' 字符串，
  // Locale 就是"语言代码(+可选国家代码)"的小对象，本项目只用语言主码。
  Locale? get locale => _choice == LanguageChoice.auto ? null : Locale(_choice.name);

  /// 实际生效的语言代码（'en' / 'zh'），设置页"当前：简体中文"这类提示用。
  String get effectiveCode {
    if (_choice != LanguageChoice.auto) return _choice.name;
    return _resolveFromSystem();
  }

  /// 手机【系统】语言被识别成我们的哪一档（'en' / 'zh'）—— 与用户的手动选择无关。
  ///
  /// 为什么不复用 effectiveCode？
  ///   effectiveCode 是"界面现在用什么语言"，用户手动指定英文后它就是 'en'。
  ///   而这一行的语义是"跟随系统会跟到哪儿"，必须只看系统本身。
  ///   两者混用会导致英文界面上写着 "System language detected: English"，
  ///   而手机其实是中文系统 —— 把用户的选择谎报成系统的选择。
  ///
  /// 为什么 _systemLocale 可信：
  ///   安卓原生层只在【构造通知】时用了 localized() 包装过的 Context，
  ///   并没有重写 Activity 的 attachBaseContext，
  ///   所以 Flutter 拿到的 platformDispatcher.locale 始终是设备真实语言。
  // 举一个"如果偷懒复用 effectiveCode"的翻车现场，帮你彻底理解为什么分开：
  // 手机是中文系统、用户在设置里手动选了 English。"跟随系统"那一行本该说
  // "系统语言：简体中文"；若误用 effectiveCode（此时='en'）就会显示
  // "System language detected: English" —— 把【用户的手动选择】谎报成
  // 【系统的检测结果】，而且这行字从此永远不随系统变化，纯属僵尸文案。
  String get systemCode => _resolveFromSystem();

  /// 语言的显示名 —— 注意这里【故意不翻译】。
  /// 语言列表里"简体中文"永远写作"简体中文"、"English"永远写作"English"，
  /// 这是全球软件的通行做法：用户用自己的母语才认得出自己的语言，
  /// 把它翻译成"Chinese Simplified"反而可能看不懂。
  ///
  /// 返回 String?（可空）：auto 这一档的名字是"跟随系统"，属于普通文案、
  /// 必须翻译，所以交回给调用方用 AppLocalizations 取，这里返回 null 表示
  /// "这一档没有母语名，你自己按当前语言说"。
  // 顺带讲清本项目的国际化机制（新手最容易踩的坑）：
  //   文案的唯一【源】是 lib/l10n/app_en.arb 和 app_zh.arb 两个人写文件；
  //   lib/l10n/app_localizations*.dart 全部由 flutter gen-l10n 在构建时
  //   【自动生成】—— 去改生成文件，下次构建会被无声覆盖，白改甚至背锅。
  //   加新句子的正确姿势：往两个 .arb 各加一个同名键 → 代码里 l10n.键名 引用
  //   （带占位符的会生成【方法】，要传参调用，见 connection_provider 的
  //   btnConnectWithSwitch 注释）。
  // 可空返回 String?：调用方（语言列表页）判 null 后自己去拿"跟随系统"的译文。
  String? displayNameOf(LanguageChoice c) {
    switch (c) {
      case LanguageChoice.auto:
        return null;
      case LanguageChoice.en:
        return 'English';
      case LanguageChoice.zh:
        return '简体中文';
    }
  }

  // --------------------------------------------------------------------------
  // 切换 + 持久化
  // --------------------------------------------------------------------------

  /// 用户在设置页点了某一档
  // async 方法返回 Future<void>："做一件要等一会儿、但没有回传值的事"。
  // 调用方 await 它就等整条链（存盘+同步原生）走完，不 await 也行、不会崩。
  // notifyListeners 刻意放在最后一步：保证界面重建那一刻，
  // SharedPreferences 和安卓原生层都已经一致，不会出现
  // "界面换了语言、通知栏还是旧语言"的半程状态。
  Future<void> setChoice(LanguageChoice c) async {
    if (_choice == c) return;
    _choice = c;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, c.name);

    // 同步给安卓：通知栏文案由原生资源表决定，得告诉它现在用哪种语言
    await _syncNative();

    // 通知所有订阅者 → MaterialApp 的 locale 变了 → 全树用新语言重建
    notifyListeners();
  }

  /// 把当前选择推给安卓原生层（iOS 不需要：系统权限弹窗的文案
  /// 由 ios/Runner/<语言>.lproj/InfoPlist.strings 决定，见该文件）。
  ///
  /// 为什么要 catch：通道调用可能在原生层还没就绪、或跑在非安卓平台时抛异常。
  /// 语言同步失败只意味着"通知栏还是上次的语言"，不影响任何功能，
  /// 所以这里刻意不往上冒错误、也不弹提示。
  Future<void> _syncNative() async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod('setLocale', {'code': _choice.name});
    } catch (_) {}
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null) {
      // firstWhere + orElse：把字符串安全地变回 enum，
      // 存进来个不认识的值（老版本残留）也不会崩。
      _choice = LanguageChoice.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => LanguageChoice.auto,
      );
      // 冷启动也要同步一次：原生服务可能在 App 没打开时被系统拉起，
      // 它自己从 SharedPreferences(android) 里读，这里补一发保证一致。
      // notifyListeners 只在 saved != null（真的恢复到了存档档位）时调用：
      // 没存过 = 保持默认 auto，内存里的 _choice 压根没变，
      // 状态没变就不 notify —— 每次 notify 都引发一轮界面重建，别白折腾。
      await _syncNative();
      notifyListeners();
    }
  }

  // --------------------------------------------------------------------------
  // 系统语言 → 我们支持的语言
  // ---------------------------------------------------------------------------------------------------------------------------------

  /// 只看语言主码（zh / en / ja / de…），不看地区（CN / TW / US）。
  /// 这样 zh-TW、zh-HK 也归到简体文案（本版先不做繁体，语义上够用）。
  String _resolveFromSystem() {
    switch (_systemLocale.languageCode) {
      case 'zh':
        return 'zh';
      default:
        return 'en';
    }
  }
}
