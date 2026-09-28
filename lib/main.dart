// ============================================================================
// main.dart —— 应用入口文件
// ----------------------------------------------------------------------------
// 整个 Flutter 应用从这里启动。main() 函数相当于 C/Java 的 main 函数，
// 是程序执行的第一个入口点。
//
// 这个文件做了三件事：
//   1. 初始化 Flutter 引擎（WidgetsFlutterBinding）
//   2. 创建并注册全局的"服务"和"状态管理器"（通过 Provider）
//   3. 启动根 Widget（PCSpeakerApp）
// ============================================================================

// material.dart 是 Flutter 的核心 UI 库，提供了 Material Design 风格的
// 组件（按钮、卡片、导航栏等）以及 runApp 函数
import 'package:flutter/material.dart';

// provider 是本项目使用的"状态管理"库。
// 简单理解：它像一个全局仓库，把服务对象（如网络服务）放进去，
// 页面在任何地方都能取出来用，而不需要一层层手动传递。
import 'package:provider/provider.dart';

// 导入本项目自己的文件（相对路径导入）
import 'app.dart';                        // 应用的根 Widget，负责配置主题、路由
import 'providers/connection_provider.dart'; // 管理"连接状态"的逻辑中心
import 'services/audio_service.dart';     // 负责播放音频流
import 'services/network_service.dart';   // 负责 WebSocket 网络连接

/// 程序入口。Flutter 应用必须有一个 main 函数。
void main() {
  // 【第一步：初始化引擎】
  // Flutter 的 Dart 代码和底层的 C++ 渲染引擎之间需要一个"桥梁"，
  // 这行代码就是这个桥梁的初始化。
  // 凡是需要在 runApp 之前调用原生功能（比如读取本地存储、播放音频），
  // 都必须先执行这一行，否则会报错。
  WidgetsFlutterBinding.ensureInitialized();

  // 【第二步：启动应用】
  // runApp() 接收一个 Widget（界面组件），它会渲染到手机屏幕上。
  // 这里最外层包了一个 MultiProvider，意思是：
  // "在启动界面前，先把下面这几个服务对象注册到全局仓库中"。
  runApp(
    MultiProvider(
      providers: [
        // --------------------------------------------------------------------
        // 服务 1：网络服务 —— 管理 WebSocket 连接
        // --------------------------------------------------------------------
        // Provider<T> 是最简单的提供者：只提供对象，不通知界面刷新。
        // 因为 NetworkService 自己通过"流(Stream)"对外广播事件，
        // 不需要 Provider 的刷新机制，所以用普通 Provider 即可。
        //
        // create：lambda 函数，(_代表不用的 BuildContext) => 构造对象。
        //         Flutter 在第一次有人使用这个服务时才调用它（懒加载）。
        // dispose：应用退出/Provider 被销毁时调用，用来关闭连接、
        //          释放内存，防止资源泄漏。
        Provider<NetworkService>(
          create: (_) => NetworkService(),
          dispose: (_, service) => service.dispose(),
        ),

        // --------------------------------------------------------------------
        // 服务 2：音频服务 —— 管理音频播放
        // --------------------------------------------------------------------
        // 同上，注册 AudioService 单例，整个 App 共用这一个播放器实例。
        Provider<AudioService>(
          create: (_) => AudioService(),
          dispose: (_, service) => service.dispose(),
        ),

        // --------------------------------------------------------------------
        // 服务 3：连接状态管理器（核心逻辑层）
        // --------------------------------------------------------------------
        // ChangeNotifierProvider 与普通 Provider 的区别：
        // 它管理的对象继承了 ChangeNotifier，内部状态一旦变化并调用
        // notifyListeners()，所有"订阅"了它的界面都会自动重建刷新。
        // 这就是 Flutter 中"数据驱动界面"的实现方式。
        //
        // create 中的 context.read<NetworkService>()：
        // 从上面的全局仓库中取出已经创建好的网络服务实例，注入进来。
        // 这叫"依赖注入"——ConnectionProvider 不自己 new 网络服务，
        // 而是使用外部传入的，方便测试和替换。
        ChangeNotifierProvider<ConnectionProvider>(
          create: (context) => ConnectionProvider(
            networkService: context.read<NetworkService>(),
            audioService: context.read<AudioService>(),
          ),
        ),
      ],
      // child：所有服务就绪后，渲染真正的 App。
      // const 表示这个 Widget 是编译期常量，不会变化，
      // Flutter 可以跳过它的重建，属于性能优化写法。
      child: const PCSpeakerApp(),
    ),
  );
}
