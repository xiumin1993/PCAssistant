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
    // MaterialApp：Material 风格 App 的根容器。
    // 它负责页面路由跳转、文字缩放、弹窗等一系列全局行为。
    // 一个 App 通常只有一个 MaterialApp。
    return MaterialApp(
      // 任务管理器/系统设置里显示的应用名（仅调试和系统层面可见）
      title: 'PC Speaker',

      // 关掉右上角的 "DEBUG" 橙色横幅。开发期它用来提醒你在调试模式，
      // 但影响截图和观感，所以关闭
      debugShowCheckedModeBanner: false,

      // ---------------- 亮色（白天）主题 ----------------
      // ThemeData：一整套视觉配置（颜色、字体、圆角、阴影……）
      // ColorScheme.fromSeed：只需给一个"种子色"（这里是蓝色），
      // Material 3 会自动推导出整套协调的配色方案（主色、辅色、背景色等），
      // 不用手动逐个定义颜色，这是 Material 3 的核心特性。
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
      home: const HomeScreen(),
    );
  }
}
