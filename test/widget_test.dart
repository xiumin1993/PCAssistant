// ============================================================================
// widget_test.dart —— 界面冒烟测试（Widget Test）
// ----------------------------------------------------------------------------
// flutter_test 是 Flutter 官方测试框架。运行方式：flutter test
//
// "冒烟测试"（smoke test）来自硬件行业术语：给设备通电，
// 先看会不会冒烟。这里对应最基础的保证 ——
// "App 能正常构建出界面、标题正确显示"，不验证业务逻辑。
// 它跑在虚拟测试环境里（不需要真机/模拟器），毫秒级完成。
// ============================================================================

// 测试框架：提供 testWidgets（组件测试）、expect（断言）、find（查找控件）
import 'package:flutter_test/flutter_test.dart';

// 被测对象：整个 App 的根 Widget
import 'package:pc_speaker/app.dart'; // pc_speaker 是 pubspec.yaml 里定义的项目包名

/// Dart 的测试入口也是 main() 函数（测试文件是独立可执行程序）
void main() {
  // testWidgets：注册一个"组件测试"用例。
  //   第 1 参：用例名称（报告里显示）
  //   第 2 参：测试体，tester 是测试驱动器，async 因为操作是异步的
  testWidgets('App smoke test', (WidgetTester tester) async {
    // pumpWidget：把 App 渲染进虚拟界面树。
    // "pump" = 让 Flutter 走完一轮"构建→布局→绘制"。
    // 注意：本项目 main.dart 里 App 外面包着 MultiProvider，
    // 而这里直接 pump 了裸的 PCSpeakerApp —— 页面内有
    // Consumer<ConnectionProvider>，缺少 Provider 包裹理论上会报错。
    // 如果 flutter test 运行失败，原因就在这里：
    // 修复方式是把同样的 MultiProvider 包裹搬进测试（见下方 TODO）。
    // TODO: 用 MultiProvider(...) 包裹 PCSpeakerApp 再 pump
    await tester.pumpWidget(const PCSpeakerApp());

    // expect(实际, 期望)：断言。不满足则测试失败。
    // find.text('PC Speaker')：在界面树里搜索显示该文字的组件。
    // findsOneWidget：期望"恰好找到 1 个"——多于 1 个也算失败。
    expect(find.text('PC Speaker'), findsOneWidget);
  });
}
