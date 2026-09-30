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
  static const MethodChannel _native = MethodChannel('com.pcspeaker/audio');

  LanguageChoice _choice = LanguageChoice.auto;

  /// 系统语言（从 MediaQuery/PlatformDispatcher 读一次即可，运行期不会变）。
  /// 为什么不让本类去读 platform dispatcher？
  /// 因为 Widget 层随时能拿到 `WidgetsBinding.instance.platformDispatcher.locale`，
  /// 但为了"界面不依赖 context 也能算出该用哪种语言"，这里在构造时抓一份快照。
  final Locale _systemLocale;

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
  Locale? get locale => _choice == LanguageChoice.auto ? null : Locale(_choice.name);

  /// 实际生效的语言代码（'en' / 'zh'），设置页"当前：简体中文"这类提示用。
  String get effectiveCode {
    if (_choice != LanguageChoice.auto) return _choice.name;
    return _resolveFromSystem();
  }

  /// 语言的显示名 —— 注意这里【故意不翻译】。
  /// 语言列表里"简体中文"永远写作"简体中文"、"English"永远写作"English"，
  /// 这是全球软件的通行做法：用户用自己的母语才认得出自己的语言，
  /// 把它翻译成"Chinese Simplified"反而可能看不懂。
  ///
  /// 返回 String?（可空）：auto 这一档的名字是"跟随系统"，属于普通文案、
  /// 必须翻译，所以交回给调用方用 AppLocalizations 取，这里返回 null 表示
  /// "这一档没有母语名，你自己按当前语言说"。
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
