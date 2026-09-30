// ============================================================================
// camera_service.dart —— 摄像头采集服务层（v3.4 新增）
// ----------------------------------------------------------------------------
// 职责：把 Android 原生 CameraEngine.kt（Camera2 采集 + JPEG 压缩）
//       包装成 Dart 好用的接口，自己不含任何业务判断。
//
//   手机相机 --原生Camera2--> JPEG帧(EventChannel) --> CameraService
//                                                      ├─ onFrame → 上行发送+预览
//                                                      └─ (能力探测/开关镜头 走 MethodChannel)
//
// 与 MicService 是"同构"的（结构几乎一样，方便对照学习）：
//   MethodChannel —— "打电话问一句答一句"：开相机 / 关相机 / 查能力 / 切镜头
//   EventChannel  —— "装一根水管持续放水"：JPEG 帧从水管里不断流出
//
// 为什么这里不算"每帧大小/统计"？—— 那是上层 CameraProvider 的事，
// 本层只做"通道翻译"，保持服务层纯净（关注点分离）。
//
// ── 补充说明书（给初学者；以下全是注释，不含代码改动）─────────────────────
//
// 【谁调用我】只有一个：lib/providers/camera_provider.dart
//   · 构造时挂 onFrame 回调（该文件"接线 1"：加 4 字节魔术头 → NetworkService.send
//     → 同时留一份给界面 Image.memory 画预览）。
//   · start/stop/switchLens/rotateManual/getCapabilities/ensurePermission/
//     startGuardService/stopGuardService 分别由 _openCamera/_closeCamera/
//     switchLens/rotateManual90/ensureCaps/toggle/stop/dispose 调用。
//   · 界面 lib/screens/camera_screen.dart 与首页只读 CameraProvider，不直接碰我。
//
// 【我调用谁】原生 CameraEngine.kt（同目录 android/app/src/main/kotlin/com/
//   pcspeaker/pc_speaker/），方法名由 MainActivity.kt:249 那个 handler 分流：
//   checkCamPermission / requestCamPermission / getCameraCaps / startCamera /
//   stopCamera / switchCamera / rotateCamera / startCamStandby / stopCamStandby。
//   这些字符串两端必须一字不差（差一个字母就是 MissingPluginException）。
//
// 【数据流方向】上行：手机相机 → Camera2 出 NV21 原始帧 → 原生压缩成 JPEG →
//   EventChannel('com.pcspeaker/cam_data') → 本服务 onFrame → CameraProvider
//   加魔术头 → WebSocket → PC 的 Unity Video Capture 虚拟摄像头。
//   下行只有控制指令（cam_state / cam_request / cam_stop），见 network_service.dart。
//
// 【上行一帧的完整布局】（CameraProvider 拼装，见该文件 _frameMagic，约 98 行）
//   字节 0     : 0x03            —— 分隔哨兵值（见下）
//   字节 1~3   : 0x43 0x41 0x4D  —— ASCII 的 'C' 'A' 'M'
//   字节 4~末尾: JPEG 本体（FF D8 开头、FF D9 结尾，自带头尾）
//   为什么要有这 4 字节：麦克风 PCM 和摄像头 JPEG 共用同一条 WebSocket 的
//   二进制消息通道，Rust 侧要看前 4 字节才知道"这是画面还是声音"。
//   0x03 是控制字符（ETX），正常音频几乎不会出现；PCM 恰好撞上这 4 字节的
//   概率约 2^-32，可忽略。改了这边必须同步改 Rust 侧。
//   注意：本项目【没有】"4 字节长度前缀"那种帧头 —— 分帧靠 WebSocket 自己的
//   消息边界（TCP 之上 WS 保证一条消息完整送达），接收端不需要数长度。
//
// 【一帧多大、码率多少】JPEG 是变长的：640×480、质量 60 大约 20~40KB/帧，
//   30fps 就是约 0.6~1.2 MB/秒。这就是画质下拉框存在的意义
//  （画质档与帧率由 CameraProvider 挑，见 selectProfile / _pickBestProfile）。
//
// 【原生侧的三个魔数（在 CameraEngine.kt，本文件只是把它们透传）】
//   · JPEG 质量 = 60（约 310 行 nv21ToJpeg(..., 60)）：网络传输场景的甜点值，
//     再高体积暴涨带宽吃紧，再低马赛克明显。
//   · 帧率限幅 1~30（约 185 行 fps.coerceIn(1, 30)）：网络+CPU 场景 30fps 封顶，
//     再高只是丢帧、白花电量。
//   · 能力探测查不到帧率时回退 33_000_000L 纳秒 = 33ms/帧 ≈ 30fps（约 146 行）。
//   · 压缩忙时直接【丢帧】（jpegBusy 开关，约 268 行）：宁可跳帧也不堆积延迟。
//
// 【新手建议阅读顺序】start() → listen 回调那段 → stop() → getCapabilities()，
//   两个数据类 CamLensCaps/CamSizeCaps 可以最后看（纯搬运）。
// ============================================================================

// dart:async：StreamSubscription（水管订阅句柄的类型）。
import 'dart:async';
import 'dart:typed_data'; // Uint8List：JPEG 原始字节
// 为什么 JPEG 要用 Uint8List 而不是 String：JPEG 是二进制，里面有 0x00 这种
// 对文本无意义的字节；Uint8List 是内存里紧密排列的字节，能原样落盘/上网络。

import 'package:flutter/services.dart';
// MethodChannel + EventChannel 都在这里；ByteData 也由它转导出。
// 备注（不改代码）：如果 flutter analyze 在本文件报 unnecessary_import
//   （dart:typed_data 与 flutter/services 提供的类型重叠），删掉多余那行即可，
//   本任务按要求只加注释、不动 import。

/// 单颗镜头的能力描述（由原生 CameraCharacteristics 探测而来）
///
/// Dart 3 的 class 可以只包数据（类似别的语言的 struct）。
/// 一个 CamLensCaps = 一颗镜头（前置或后置）+ 它支持的画质档位清单。
// 这种"只有字段 + 构造 + 转换方法"的类叫 DTO（Data Transfer Object，
// 数据传输对象）：专门用来承接原生传来的 Map，或在网络上传 JSON。
class CamLensCaps {
  // final：一经赋值不可改。DTO 全部用 final 是好习惯 ——
  // 对象不可变就能在流里放心传递，谁也别想偷偷改历史数据。
  final String facing; // "back" 后置 / "front" 前置
  final List<CamSizeCaps> sizes; // 支持的分辨率档位（面积从大到小已排好）

  // const 构造：允许在编译期就把对象算出来（可以写成 const CamLensCaps(...)），
  // 前提是所有字段都是编译期常量。运行中探测出来的值用普通构造即可。
  // required this.facing：命名参数必填 + 直接赋给同名字段（this.x = x 的简写）。
  const CamLensCaps({required this.facing, required this.sizes});

  /// 从原生传来的 Map（JSON 形状）构造对象。
  /// as / as? 是 Dart 的"类型断言"：告诉编译器我相信这个字段是什么类型。
  /// 原生返回的数字在 Dart 里都是 int，但防御性写法仍保留。
  // 再细讲一层：
  //   m['facing'] 的类型是 dynamic（Map<dynamic,dynamic> 的取值结果，编译期不校验），
  //   as String?   = "按可空字符串取"，实际不是字符串就抛异常；
  //   ?? 'back'    = 真的是 null 就用默认值兜底。
  // 所以 `as String? ?? 'back'` 读作"能当字符串就拿来用，没有就说后置"。
  // factory 构造：不是每次都 new 一个新对象，而是一个"根据输入造对象"的工厂方法，
  // 常用来把外部格式（Map/JSON）转成内部类型；调用写法一样是 CamLensCaps.fromMap(m)。
  factory CamLensCaps.fromMap(Map<dynamic, dynamic> m) {
    return CamLensCaps(
      facing: m['facing'] as String? ?? 'back',
      // ((... as List?) ?? const []) 的意思是：不是列表就当空列表处理，
      // 后面的 .map(...).toList() 于是安全地返回 []，不会因 null 崩溃。
      // 注意：原生传来的每一项又是 Map，所以内层要 s as Map 再交给 CamSizeCaps。
      sizes: ((m['sizes'] as List?) ?? const [])
          .map((s) => CamSizeCaps.fromMap(s as Map))
          .toList(),
    );
  }

  /// 转回 Map 以便 jsonEncode 发给 PC（"手机最高支持什么画质"）
  // 用法见 lib/providers/camera_provider.dart：
  //   _networkService.send(jsonEncode({'type': 'cam_capabilities',
  //     'cams': _caps.map((c) => c.toMap()).toList()}))
  // 这里字段名（facing/width/height/maxFps）就是和 PC 端 GUI 的数据契约，
  // 改名要和 Rust 侧同步，否则那边解析不到、显示 0。
  Map<String, dynamic> toMap() => {
        'facing': facing,
        // 这里不是展开操作符，就是一行普通表达式：每个 CamSizeCaps 转成 Map，
        // 再 toList() 成"Map 的列表"，jsonEncode 后就是一个 JSON 数组。
        // 顺带把两个易混操作符说清（本文件没用到，camera_provider.dart 里有）：
        //   展开 ...  形如 [a, ...b, c] —— 把 b 的元素摊平进新列表；
        //   级联 ..   形如 builder..add(x)..add(y) —— 对同一个对象连续调方法，
        //             返回值还是那个对象本身（省掉重复写变量名）。
        'sizes': sizes.map((s) => s.toMap()).toList(),
      };
}

/// 一颗镜头的某个画质档位：宽 × 高 @ 最高帧率
// 这个类会被界面下拉框直接遍历（CameraProvider.lensSizes getter），
// 也被 toMap 打包上报 PC。
class CamSizeCaps {
  final int width;
  final int height;
  final int maxFps;

  const CamSizeCaps({required this.width, required this.height, required this.maxFps});

  factory CamSizeCaps.fromMap(Map<dynamic, dynamic> m) => CamSizeCaps(
        // 宽高缺失兜底 0（表示"这条无效"，上层挑档时会因面积 0 被自然忽略）；
        // maxFps 缺失兜底 15：给一个"保守但可用"的帧率，
        // 上层还会再 clamp(1, 30)（见 camera_provider._pickBestProfile）。
        width: m['width'] as int? ?? 0,
        height: m['height'] as int? ?? 0,
        maxFps: m['maxFps'] as int? ?? 15,
      );

  Map<String, dynamic> toMap() =>
      {'width': width, 'height': height, 'maxFps': maxFps};
}

/// 摄像头采集服务
class CameraService {
  /// 方法通道：复用麦克风/播放那一条（原生 MainActivity 里同一个 CHANNEL）
  // 也就是说：播放、麦克风、摄像头三件事的命令都走 'com.pcspeaker/audio'，
  // 只有"大数据推流"各自单开 EventChannel。这样 Dart/原生两侧只需对齐
  // 一个 MethodChannel 名字 + 两个 EventChannel 名字，管理成本最低。
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  /// 事件通道：原生采集线程持续推来的 JPEG 帧
  // 名字必须等于原生 MainActivity.kt:167 的 CAM_DATA_CHANNEL = "com.pcspeaker/cam_data"。
  // 原生在 420 行附近 setStreamHandler 接水管，CameraEngine 每压好一帧就
  // camEventSink?.success(jpegBytes) 推一次（同样必须在主线程推）。
  static const EventChannel _dataChannel = EventChannel('com.pcspeaker/cam_data');

  // 水管订阅句柄：listen 了就必须 cancel，否则回调一直挂在 EventChannel 上，
  // 相机即使关了也可能残留"推流给已销毁对象"的崩溃风险。
  StreamSubscription? _dataSub; // 水管订阅句柄（listen 了必须 cancel）

  /// 是否正在采集（原生相机已打开）
  bool isRunning = false;

  /// 每来一帧 JPEG 就回调一次 —— CameraProvider 在这里发往 PC + 刷预览
  // 函数类型可空字段：类型读作"参数是 Uint8List、返回 void 的函数，可能没被赋值"。
  // 由 lib/providers/camera_provider.dart 在构造时挂上（接线 1）。
  // 调用时写 onFrame?.call(event)：?. 保证没人挂回调时不会空指针崩溃。
  void Function(Uint8List jpeg)? onFrame;

  /// 静默查询相机权限（不弹系统窗）。自动流程用，避免突然弹窗打扰。
  Future<bool> hasPermission() async {
    // invokeMethod<bool> 的泛型只是"我对原生返回值的预期"，实际返回是 bool?，
    // 所以必须 ?? false 兜底（原生回 null 就当没权限）。
    final granted =
        await _channel.invokeMethod<bool>('checkCamPermission') ?? false;
    return granted;
  }

  /// 确保拿到相机权限：已有 → 直接 true；没有 → 弹系统授权窗问一次。
  Future<bool> ensurePermission() async {
    // 先静默查一次，省掉不必要的弹窗（Android 对重复弹窗也会反感）。
    final granted = await hasPermission();
    if (granted) return true;
    // 这里 await 会挂起直到【用户点完】：原生把 result 暂存进 pendingCamPermResult，
    // 在 onRequestPermissionsResult 里才回话 —— 所以这句 await 一等可能就是几秒。
    final result =
        await _channel.invokeMethod<bool>('requestCamPermission') ?? false;
    return result;
  }

  /// 能力探测：返回每颗镜头支持的画质档位（不开相机、无需权限，纯查询）。
  // 为什么能不开相机：Android 的 CameraCharacteristics 是一份"静态说明书"，
  // 只读设备元数据，不碰硬件，所以不会有绿点、不耗电、不申请权限。
  // CameraProvider 因此在"一连上就探一次"（见该文件 ensureCaps/接线 2）。
  Future<List<CamLensCaps>> getCapabilities() async {
    // 泛型 List<dynamic>：原生回的是"Map 组成的列表"（StandardMessageCodec
    // 把 Kotlin 的 List<Map<..>> 映射成这样），所以取值时还得自己转型。
    // ?? [] = 原生没回数据就当"一颗镜头都探不到"，上层会退回保守默认档。
    final raw =
        await _channel.invokeMethod<List<dynamic>>('getCameraCaps') ?? [];
    return raw
        // whereType：按类型过滤列表（只留 Map），把脏数据（比如 null 元素）滤掉，
        // 比在 map 里包 try/catch 更干净。
        .whereType<Map<dynamic, dynamic>>()
        // .map(方法名) 的简写：每个元素调用这个函数（等价 map((m) => CamLensCaps.fromMap(m))）。
        .map(CamLensCaps.fromMap)
        // map 返回的是惰性 Iterable（用时才算），toList() 物化成列表好复用。
        .toList();
  }

  /// 打开相机开始采集。
  /// 返回 null = 成功；返回错误码字符串 = 失败（上层翻译成中文提示）。
  ///
  /// @param facing  "back" 后置 / "front" 前置（设计决定：默认后置）
  /// @param width/height  选定的画质档位
  /// @param fps     目标帧率（原生内部再限幅 1~30）
  // 默认值 640×480@30 的来由：这是所有 Android 设备几乎都支持的"保底档"，
  // 万一能力探测失败（camera_provider 的 catch 分支）也能开到东西。
  // 实际使用时 CameraProvider 传的是探测出来的最高档或用户手选档。
  // 为什么默认后置：隐私上"后置不拍自己"、画质普遍更好（设计决定，记在 provider 里）。
  Future<String?> start({
    String facing = 'back',
    int width = 640,
    int height = 480,
    int fps = 30,
  }) async {
    if (isRunning) return null; // 幂等：已在跑不重复启动

    // 权限兜底（正常流程上层已确认；防系统撤销权限的极端情况）
    if (!await ensurePermission()) return 'PERMISSION_DENIED';

    // 让原生打开 Camera2 并开始出帧。约定与 startMic 一致：
    // 成功 success(null)，失败 success("错误码")
    // 原生可能回的错误码（CameraEngine.start / MainActivity 的 startCamera 分支）：
    //   NO_CAMERA      没有该朝向的镜头（有些机器没有前置）
    //   OPEN_TIMEOUT   相机被别的 App 占着，等超时了才回
    //   SESSION_FAILED 建 CameraCaptureSession 失败（并发抢占等）
    // 上层用 _reportNativeError() 把这些码翻成文案键（camera_provider.dart 末尾）。
    // 4 个参数都放进 Map，key 必须和原生 call.argument<Int>("width") 之类对齐。
    final error = await _channel.invokeMethod<String>('startCamera', {
      'facing': facing,
      'width': width,
      'height': height,
      'fps': fps,
    });
    if (error != null) return error;

    // 订阅 JPEG 水管（receiveBroadcastStream 是 EventChannel 标准读法）
    // 顺序要点：先让原生开起来（上面已 await 成功），再开始接水；
    // isRunning 必须在水管挂好前置 true，否则 stop 会以为没在跑而漏关。
    isRunning = true;
    _dataSub = _dataChannel.receiveBroadcastStream().listen((event) {
      // event 是 dynamic（编译期不校验类型），先 is! 确认是字节再转发，
      // 不是就丢掉这一条（比如原生偶发推进度 Map 之类的异常情况）。
      if (event is! Uint8List) return;
      onFrame?.call(event); // 原样转发给上层
      // 本层到此为止：加魔术头、发 WebSocket、刷预览、节流刷新界面，
      // 全在 camera_provider.dart 的"接线 1"里做。
    });
    return null;
  }

  /// 停止采集并释放原生相机（关硬件 = 绿点熄灭，隐私承诺的支点）
  Future<void> stop() async {
    if (!isRunning) {
      // 即便 Dart 侧认为没在跑，也通知原生兜底关一次
      // 为什么要兜底：Dart 侧的状态可能和原生不一致（比如原生自己因异常退了、
      // 或者上一次 stop 跨语言调用失败）。相机是隐私硬件，宁可多发一次
      // "关"（原生 stopCamera 是幂等的，没开就是空操作）。
      await _channel.invokeMethod('stopCamera');
      return;
    }
    // 先置 false 再收尾：避免"正在 stop 时又有人调 start"的窗口期。
    isRunning = false;
    await _dataSub?.cancel(); // 先关水管
    // cancel() 会触发原生 StreamHandler.onCancel → camEventSink 置 null，
    // 采集线程此后即使还在跑也推不出东西（省掉无谓的跨语言序列化）。
    _dataSub = null;
    await _channel.invokeMethod('stopCamera'); // 再让原生关设备、退线程
  }

  /// 切换前/后置镜头（原生内部 stop→start 沿用当前画质）。
  /// 返回切换后的 facing："back" / "front"。
  // 为什么返回值要回给 Dart：前后置是"原生真的换了设备"，
  // CameraProvider 需要用回值校准自己的 _facing（并 _pickBestProfile 重挑档位，
  // 见 lib/providers/camera_provider.dart 的 switchLens）。
  Future<String> switchLens() async {
    // invokeMethod<String> 的返回是 String?，?? 'back' 兜底成后置
    //（兜底值选 back 和设计默认一致：宁可显示保守的那个）。
    final facing = await _channel.invokeMethod<String>('switchCamera') ?? 'back';
    return facing;
  }

  /// v3.4.1：手动顺时针旋转 90°（0→90→180→270→0 循环）。
  /// 原生只改一个角度数字，下一帧立即生效 —— 不重启相机、不断流。
  /// 返回设置后的新角度（度）。
  // 为什么在压缩阶段转而不是让 Camera2 改 sensor orientation：
  // 改硬件方向要 close→open 重启会话，画面会断流几百毫秒；
  // 在 nv21ToJpeg 时套一个角度，代价只是每帧多一点 CPU，画面连续。
  // 相机没开时也能按：这个角度存在原生里，下次 start 自动套用
  //（camera_provider.dart 的 rotateManual90 只做"调用 + 镜像数字刷按钮文案"）。
  Future<int> rotateManual() async {
    // ?? 0：原生没回数字就当 0°（界面最多是按钮文案晚一步对齐，不影响功能）。
    final deg = await _channel.invokeMethod<int>('rotateCamera') ?? 0;
    return deg;
  }

  // ── v3.4：摄像头守护前台服务（与麦克风的守护服务同理）────────
  // 连上电脑并启用摄像头守护后挂一条常驻通知保活进程 ——
  // 息屏时 PC 的 cam_state 唤醒指令才能送达。
  // 服务本身【不开相机】，省电的是"只有 PC 真在看才开硬件"。
  // 新手补充：前台服务（Foreground Service）是 Android 唯一"温和的保活"手段，
  // 代价是通知栏必须常驻一条通知；Android 12+ 还需要通知权限，被拒时启动会抛异常。
  // 启用路径由 CameraProvider 的 _enterStandbyInternal() 调下面这个方法。

  // 注：方法名 startGuardService（摄像头）与 MicService.startStandbyService
  //（麦克风）是同一类东西的不同命名，读代码时别当成两套机制。
  Future<void> startGuardService() async {
    try {
      await _channel.invokeMethod('startCamStandby');
    } catch (_) {
      // 启动失败（如通知权限被拒）不致命：亮屏时功能照常，只是息屏待机不可靠
      // 有意"静默降级"：不弹窗、不改状态，让用户至少亮屏时能正常用。
    }
  }

  Future<void> stopGuardService() async {
    try {
      await _channel.invokeMethod('stopCamStandby');
    } catch (_) {}
    // 这里 catch 空 = 重复调用无害（CameraProvider 的 stop/dispose 都会调它）。
  }

  /// 释放（App 退出时调用）
  // 由 CameraProvider.dispose() 触发；顺序同样是"先关硬件再撤通知"。
  Future<void> dispose() async {
    await stop();
    await stopGuardService();
  }
}
