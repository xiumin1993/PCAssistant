// ============================================================================
// app.dart —— 应用的根 Widget（总装配件）
// ----------------------------------------------------------------------------
// 它负责整个 App 的"全局配置"：应用标题、主题颜色（亮色/暗色）、
// 以及首页是哪个页面。可以理解为房子的"总装修方案"。
//
// 界面层级关系：
//   main.dart (runApp)
//     └─ PCSpeakerApp (本文件) —— MaterialApp 提供 Material 风格环境
//          └─ HomeScreen (screens/home_screen.dart) —— 真正的首页
// ============================================================================

// Flutter Material Design UI 库（Widget、Theme、Colors 等都在这里）
import 'package:flutter/material.dart';

// provider：根 Widget 要"订阅"语言选择，语言一换整棵树重建
import 'package:provider/provider.dart';

// 官方国际化机制的入口：GlobalMaterialLocalizations 提供 Material 组件
// （日期、"取消"、进度条朗读文案等）自带的那批多语言词条。
import 'package:flutter_localizations/flutter_localizations.dart';

// 由 lib/l10n/*.arb 在构建期自动生成的文案类（flutter: generate: true）。
// 手写代码里永远不要改这三个 app_localizations*.dart —— 它们每次构建都会被覆盖。
// 生成工具是 `flutter gen-l10n`：源文件只有 app_en.arb / app_zh.arb 两个人写文件，
// 要改任何一句界面文案，改对应的 .arb 再重新生成，改生成的 .dart 等于白改。
import 'l10n/app_localizations.dart';

import 'providers/language_provider.dart';

// 导入首页。根 Widget 本身不画具体内容，只把首页"挂"上去
import 'screens/home_screen.dart';

/// 应用的根 Widget。
///
/// StatelessWidget = 无状态组件：它自己内部没有会变化、需要刷新的数据，
/// 一旦创建就固定不变（会变的部分交给下层 Widget 或 Provider 处理）。
/// 与之对应的是 StatefulWidget（有状态组件），本项目的界面刷新全部走
/// Provider，所以这里用无状态组件就够了。
class PCSpeakerApp extends StatelessWidget {
  /// 构造函数。
  /// const 关键字：声明这是一个"编译期常量构造"，创建的对象不可变，
  /// Flutter 重建界面时可以直接复用旧实例，跳过重新创建，是性能优化。
  ///
  /// super.key：key 是 Flutter 给 Widget 打的"身份证"。
  /// 在列表/刷新场景里，Flutter 靠 key 判断"这个组件还是不是原来那个"，
  /// 从而决定是更新还是重建。根组件传不传影响不大，但这是规范写法，
  /// IDE 也会强制要求子类构造函数透传 key。
  const PCSpeakerApp({super.key});

  /// build：Flutter 渲染引擎调用这个方法来"构建"界面。
  /// 每当上层数据变化需要刷新时，build 可能被反复调用，
  /// 所以这里只应描述"界面长什么样"，不要写业务逻辑。
  ///
  /// context（BuildContext）：代表当前 Widget 在界面树中的"位置"，
  /// 通过它能拿到主题、路由、Provider 等一切上层提供的信息。
  @override
  Widget build(BuildContext context) {
    // Consumer<LanguageProvider>：用户在设置页拨了语言档位 →
    // LanguageProvider.notifyListeners() → 这里重新 build →
    // MaterialApp 拿到新 locale → Flutter 把 Localizations 换一套，
    // 全 App 文案当场改语言（不需要重启）。
    return Consumer<LanguageProvider>(
      builder: (context, lang, _) {
        return MaterialApp(
          // 任务管理器/系统设置里显示的应用名（仅调试和系统层面可见）。
          // 产品名 PC Assistant 属于品牌，全球统一不翻译。
          title: 'PC Assistant',

          // 关掉右上角的 "DEBUG" 橙色横幅。开发期它用来提醒你在调试模式，
          // 但影响截图和观感，所以关闭
          debugShowCheckedModeBanner: false,

          // ---------------- 国际化三件套（缺一不可） ----------------
          // ① locale：强制使用哪种语言。
          //    null = "不干预"，Flutter 自己去系统里挑（= 跟随系统档）。
          //    非 null = 用户手动指定了 English / 简体中文。
          locale: lang.locale,

          // ② localizationsDelegates：告诉 Flutter "文案去哪儿找"。
          //    · AppLocalizations.delegate → 我们自己 arb 生成的那套（首页、设备卡…）
          //    · GlobalMaterialLocalizations → Material 组件内置的那套（系统词）
          //    · GlobalWidgetsLocalizations / GlobalCupertinoLocalizations →
          //      基础 Widget 和 iOS 风格组件的内置词，补齐才不会在某些控件上崩。
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],

          // ③ supportedLocales：本 App 声明支持的语言清单。
          //    系统语言不在这个表里时，Flutter 会回退到清单的第一项（英文），
          //    所以"永远不要把没文案的语言写进来"。
          supportedLocales: AppLocalizations.supportedLocales,

          // ---------------- 亮色（白天）主题 ----------------
          // ThemeData：一整套视觉配置（颜色、字体、圆角、阴影……）
          // ColorScheme.fromSeed：只需给一个"种子色"（这里是蓝色），
          // Material 3 会自动推导出整套协调的配色方案（主色、辅色、背景色等），
          // 不用手动逐个定义颜色，这是 Material 3 的核心特性。
          // 想改全局样式往哪儿改？就在下面 ThemeData 的参数里加：
          //   · 换主色 → 改 seedColor；逐个指定颜色 → 覆盖 colorScheme 的参数
          //   · 全局字号/字体 → textTheme（headline/body/label 各级）
          //   · 卡片圆角/阴影 → cardTheme；对话框 → dialogTheme
          // 本项目目前只用种子色推导、没有逐项覆盖，所以两套主题写得很薄；
          // 个别页面里的圆角（如 device_gate.dart 的 BorderRadius.circular）
          // 是组件局部样式，不走全局主题。
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.light, // 强制亮色方案
            ),
            useMaterial3: true, // 启用 Material Design 3（新版设计规范）
          ),

          // ---------------- 暗色（夜间）主题 ----------------
          // 结构完全相同，只是 brightness 换成 dark。
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark, // 强制暗色方案
            ),
            useMaterial3: true,
          ),

          // 主题模式：system 表示跟随手机系统的深色/浅色设置自动切换。
          // 也可以写死 light / dark。
          themeMode: ThemeMode.system,

          // home：App 启动后显示的第一个页面。
          // 页面内部自己会再套一个 Scaffold（脚手架），见 home_screen.dart
          //
          // 【路由写法说明（初学者常问）】MaterialApp 挂页面有三种方式：
          //   ① home: —— 只声明唯一起点页，本项目用的就是这种（不是
          //      MaterialApp.router，也没有写 routes 名字表）；
          //   ② routes: {'/xxx': builder} —— 页面多、跳转不带复杂参数时方便；
          //   ③ MaterialApp.router + go_router —— 大项目/深链接才值得上。
          // 页面跳转入口在首页：home_screen.dart 里点设备入口卡时用
          // Navigator.push(context, MaterialPageRoute(builder: ...))
          // 把对应的设备详情页"压"进路由栈，系统返回键自动弹回首页，
          // 因此根这里无需登记任何路由表。
          home: const HomeScreen(),
        );
      },
    );
  }
}
