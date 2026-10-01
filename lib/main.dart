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
import 'providers/mic_provider.dart';     // 管理"手机麦克风模式"的逻辑中心
import 'providers/camera_provider.dart';  // 管理"手机摄像头模式"的逻辑中心（v3.4）
import 'providers/device_provider.dart';   // 三设备总闸与状态词（v3.6）
import 'providers/language_provider.dart';  // 界面语言选择（v3.7 国际化）
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
  // 更准确地说：runApp 把这个 Widget 挂成"界面树"的根节点，触发第一次
  // 布局-绘制，并从此驱动整个 App。一个程序只调用它一次。
  // 这里最外层包了一个 MultiProvider，意思是：
  // "在启动界面前，先把下面这几个服务对象注册到全局仓库中"。
  //
  // 【关于 SharedPreferences（本地存储）与启动顺序】
  // 很多教程把 main() 写成 async 并先 await 读本地存储再 runApp。
  // 本项目刻意选了另一条路：main() 保持同步、界面第一时间起来；
  // 需要存档的 Provider（LanguageProvider / DeviceProvider 的 _load()）
  // 在构造时自己发起异步读取，读到旧档后 notifyListeners()，
  // 相关界面自动重建一次、显示真正的档位。两种做法都对，区别是：
  //   先 await 再 runApp —— 首帧即最终状态，代价是启动多等一次磁盘；
  //   先 runApp 后异步恢复 —— 启动最快，极短时间内可能先看到默认值
  //                        （如语言默认"跟随系统"）再刷新成存档值。
  // 但无论选哪条，上面的 ensureInitialized() 都必须排在所有事情之前：
  // SharedPreferences 这类插件底层靠"平台通道(platform channel)"跟原生
  // 代码通信，而通道要等 Binding 初始化完成后才存在——顺序反了直接抛异常。
  runApp(
    MultiProvider(
      // providers 列表就是"挂到树上"这个动作本身：
      // MultiProvider 是语法糖，等价于把 6 个 Provider 一层套一层地
      // 包在 PCSpeakerApp 外面（第一个写在最外层）。每个 Provider 往
      // Widget 树里塞一个"仓库节点"，之后的任何后代 Widget 都能顺着
      // 自己的 context 沿祖先链往上找到对应类型的服务，并且全 App
      // 拿到的都是同一个实例（单例效果）。
      // ChangeNotifierProvider 再多做一步：它监听内部对象的
      // notifyListeners()，一旦触发就把"订阅了它的子孙"重新 build，
      // 这就是"状态挂在树上、数据驱动界面"的完整链路。
      providers: [
        // --------------------------------------------------------------------
        // 服务 0：界面语言（v3.7 国际化新增）
        // --------------------------------------------------------------------
        // 放在最前面只是阅读顺序上的考虑：它是"跟业务无关的全局偏好"。
        // 构造时抓一份系统语言的快照，之后从 SharedPreferences 恢复
        // 用户手动选过的档位（auto / en / zh）。
        // 为什么"跟随系统"和"手动选择"要并存？
        //   纯跟随系统：手机是德语而 App 只有中英两套文案时，用户没有自救入口；
        //   纯手动：新装 App 时界面语言和手机系统对不上，体验差。
        //   所以默认走 auto（=跟随系统，locale 传 null 让 Flutter 自己匹配），
        //   同时永远保留 en/zh 两档手动覆盖 —— 用户的选择存本地、重启还认。
        // 用 ChangeNotifierProvider：用户改语言 → notifyListeners →
        // app.dart 里的 Consumer 重建 MaterialApp → 全 App 换语言。
        ChangeNotifierProvider<LanguageProvider>(
          create: (_) => LanguageProvider(),
        ),

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

        // --------------------------------------------------------------------
        // 服务 4：麦克风状态管理器（手机麦克风模式的核心逻辑层）
        // --------------------------------------------------------------------
        // 同样用 ChangeNotifierProvider：MicProvider 内部状态
        // （idle/starting/live、音量条、错误信息）一变，
        // mic_screen.dart 里的 Consumer 就自动刷新界面。
        //
        // 它只需要 NetworkService（用来把录音字节发上 WebSocket、
        // 监听服务器的 mic_ack），不依赖音频播放服务。
        ChangeNotifierProvider<MicProvider>(
          create: (context) => MicProvider(
            networkService: context.read<NetworkService>(),
          ),
        ),

        // --------------------------------------------------------------------
        // 服务 5：摄像头状态管理器（手机摄像头模式的核心逻辑层，v3.4）
        // --------------------------------------------------------------------
        // 与 MicProvider 同款结构：待命/取景/冻结状态一变，
        // camera_screen.dart 与首页区块自动刷新。
        // 双入口启用（手机开关 or PC 请求+手机确认）的逻辑都住在这里。
        ChangeNotifierProvider<CameraProvider>(
          create: (context) => CameraProvider(
            networkService: context.read<NetworkService>(),
          ),
        ),

        // --------------------------------------------------------------------
        // 服务 6：三设备总闸与状态账本（v3.6 新增）
        // --------------------------------------------------------------------
        // 它自己不干活，只把上面三个 Provider 的"技术状态"翻译成
        // 界面要的状态词（已禁用/未连接/待命/使用中），并把用户的
        // 启用/禁用意图执行下去 + 存本地。
        //
        // 注册顺序有讲究：必须排在 ConnectionProvider / MicProvider /
        // CameraProvider 之后，因为 create 里要用 context.read 取它们。
        // Provider 列表是从上往下构建的，先注册的才是"祖先"，读得到。
        ChangeNotifierProvider<DeviceProvider>(
          create: (context) => DeviceProvider(
            connection: context.read<ConnectionProvider>(),
            mic: context.read<MicProvider>(),
            camera: context.read<CameraProvider>(),
            audio: context.read<AudioService>(),
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
