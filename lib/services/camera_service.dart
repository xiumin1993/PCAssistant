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
// ============================================================================

import 'dart:async';
import 'dart:typed_data'; // Uint8List：JPEG 原始字节

import 'package:flutter/services.dart';

/// 单颗镜头的能力描述（由原生 CameraCharacteristics 探测而来）
///
/// Dart 3 的 class 可以只包数据（类似别的语言的 struct）。
/// 一个 CamLensCaps = 一颗镜头（前置或后置）+ 它支持的画质档位清单。
class CamLensCaps {
  final String facing; // "back" 后置 / "front" 前置
  final List<CamSizeCaps> sizes; // 支持的分辨率档位（面积从大到小已排好）

  const CamLensCaps({required this.facing, required this.sizes});

  /// 从原生传来的 Map（JSON 形状）构造对象。
  /// as / as? 是 Dart 的"类型断言"：告诉编译器我相信这个字段是什么类型。
  /// 原生返回的数字在 Dart 里都是 int，但防御性写法仍保留。
  factory CamLensCaps.fromMap(Map<dynamic, dynamic> m) {
    return CamLensCaps(
      facing: m['facing'] as String? ?? 'back',
      sizes: ((m['sizes'] as List?) ?? const [])
          .map((s) => CamSizeCaps.fromMap(s as Map))
          .toList(),
    );
  }

  /// 转回 Map 以便 jsonEncode 发给 PC（"手机最高支持什么画质"）
  Map<String, dynamic> toMap() => {
        'facing': facing,
        'sizes': sizes.map((s) => s.toMap()).toList(),
      };
}

/// 一颗镜头的某个画质档位：宽 × 高 @ 最高帧率
class CamSizeCaps {
  final int width;
  final int height;
  final int maxFps;

  const CamSizeCaps({required this.width, required this.height, required this.maxFps});

  factory CamSizeCaps.fromMap(Map<dynamic, dynamic> m) => CamSizeCaps(
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
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  /// 事件通道：原生采集线程持续推来的 JPEG 帧
  static const EventChannel _dataChannel = EventChannel('com.pcspeaker/cam_data');

  StreamSubscription? _dataSub; // 水管订阅句柄（listen 了必须 cancel）

  /// 是否正在采集（原生相机已打开）
  bool isRunning = false;

  /// 每来一帧 JPEG 就回调一次 —— CameraProvider 在这里发往 PC + 刷预览
  void Function(Uint8List jpeg)? onFrame;

  /// 静默查询相机权限（不弹系统窗）。自动流程用，避免突然弹窗打扰。
  Future<bool> hasPermission() async {
    final granted =
        await _channel.invokeMethod<bool>('checkCamPermission') ?? false;
    return granted;
  }

  /// 确保拿到相机权限：已有 → 直接 true；没有 → 弹系统授权窗问一次。
  Future<bool> ensurePermission() async {
    final granted = await hasPermission();
    if (granted) return true;
    final result =
        await _channel.invokeMethod<bool>('requestCamPermission') ?? false;
    return result;
  }

  /// 能力探测：返回每颗镜头支持的画质档位（不开相机、无需权限，纯查询）。
  Future<List<CamLensCaps>> getCapabilities() async {
    final raw =
        await _channel.invokeMethod<List<dynamic>>('getCameraCaps') ?? [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(CamLensCaps.fromMap)
        .toList();
  }

  /// 打开相机开始采集。
  /// 返回 null = 成功；返回错误码字符串 = 失败（上层翻译成中文提示）。
  ///
  /// @param facing  "back" 后置 / "front" 前置（设计决定：默认后置）
  /// @param width/height  选定的画质档位
  /// @param fps     目标帧率（原生内部再限幅 1~30）
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
    final error = await _channel.invokeMethod<String>('startCamera', {
      'facing': facing,
      'width': width,
      'height': height,
      'fps': fps,
    });
    if (error != null) return error;

    // 订阅 JPEG 水管（receiveBroadcastStream 是 EventChannel 标准读法）
    isRunning = true;
    _dataSub = _dataChannel.receiveBroadcastStream().listen((event) {
      if (event is! Uint8List) return;
      onFrame?.call(event); // 原样转发给上层
    });
    return null;
  }

  /// 停止采集并释放原生相机（关硬件 = 绿点熄灭，隐私承诺的支点）
  Future<void> stop() async {
    if (!isRunning) {
      // 即便 Dart 侧认为没在跑，也通知原生兜底关一次
      await _channel.invokeMethod('stopCamera');
      return;
    }
    isRunning = false;
    await _dataSub?.cancel(); // 先关水管
    _dataSub = null;
    await _channel.invokeMethod('stopCamera'); // 再让原生关设备、退线程
  }

  /// 切换前/后置镜头（原生内部 stop→start 沿用当前画质）。
  /// 返回切换后的 facing："back" / "front"。
  Future<String> switchLens() async {
    final facing = await _channel.invokeMethod<String>('switchCamera') ?? 'back';
    return facing;
  }

  /// v3.4.1：手动顺时针旋转 90°（0→90→180→270→0 循环）。
  /// 原生只改一个角度数字，下一帧立即生效 —— 不重启相机、不断流。
  /// 返回设置后的新角度（度）。
  Future<int> rotateManual() async {
    final deg = await _channel.invokeMethod<int>('rotateCamera') ?? 0;
    return deg;
  }

  // ── v3.4：摄像头守护前台服务（与麦克风的守护服务同理）────────
  // 连上电脑并启用摄像头守护后挂一条常驻通知保活进程 ——
  // 息屏时 PC 的 cam_state 唤醒指令才能送达。
  // 服务本身【不开相机】，省电的是"只有 PC 真在看才开硬件"。

  Future<void> startGuardService() async {
    try {
      await _channel.invokeMethod('startCamStandby');
    } catch (_) {
      // 启动失败（如通知权限被拒）不致命：亮屏时功能照常，只是息屏待机不可靠
    }
  }

  Future<void> stopGuardService() async {
    try {
      await _channel.invokeMethod('stopCamStandby');
    } catch (_) {}
  }

  /// 释放（App 退出时调用）
  Future<void> dispose() async {
    await stop();
    await stopGuardService();
  }
}
