// ============================================================================
// mic_service.dart —— 麦克风采集服务层（v3 新增）
// ----------------------------------------------------------------------------
// 职责：调用 Android 原生 AudioRecord 采集手机话筒声音，
//       把 PCM 字节块"原样"转发出去（通过 onData 回调），
//       同时算出每块的响度（通过 onLevel 回调）给界面画电平条。
//
//   手机话筒 --原生AudioRecord--> EventChannel(字节流) --> MicService
//                                                        ├─ onData  → 上行发送
//                                                        └─ onLevel → 界面电平
//
// 与 AudioService（播放）的分工：
//   AudioService 管"耳朵听"（PC → 手机扬声器），
//   MicService    管"嘴巴说"（手机话筒 → PC 虚拟麦克风），
//   两者互不干扰，所以可以全双工同时进行。
//
// 平台通道复习（新手关键）：
//   MethodChannel —— "打电话问一句答一句"：startMic / stopMic / 权限请求
//   EventChannel  —— "装一根水管持续放水"：麦克风 PCM 帧从水管里不断流出
// ============================================================================

import 'dart:async';
import 'dart:math' as math; // 只用它的 sqrt 开平方算 RMS
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 麦克风采集服务
class MicService {
  /// 方法通道：复用播放那一条（原生 MainActivity 里同一个 CHANNEL）
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  /// 事件通道：原生采集线程持续推来的 PCM 字节块
  static const EventChannel _dataChannel = EventChannel('com.pcspeaker/mic_data');

  StreamSubscription? _dataSub; // 水管订阅句柄（不取消会泄漏）

  /// 是否正在采集
  bool isRunning = false;

  /// 每来一块 PCM 字节就回调一次 —— MicProvider 在这里把数据发往 PC
  void Function(Uint8List bytes)? onData;

  /// 每块数据算好的响度（0.0 ~ 1.0）—— MicProvider 在这里刷电平条
  void Function(double level)? onLevel;

  /// 静默查询录音权限（不弹系统窗）。自动待命流程用：
  /// 没权限就跳过登记，避免连接瞬间弹窗打扰。
  Future<bool> hasPermission() async {
    final granted =
        await _channel.invokeMethod<bool>('checkMicPermission') ?? false;
    return granted;
  }

  /// 确保拿到录音权限。
  /// 返回 true = 已授权；false = 用户拒绝（或系统弹窗点了"不允许"）。
  Future<bool> ensurePermission() async {
    // invokeMethod<bool> 的泛型参数：告诉 Dart "原生会回一个 bool"，
    // 返回值是可空 bool（?），用 ?? false 兜底（万一原生返回 null）
    final granted =
        await _channel.invokeMethod<bool>('checkMicPermission') ?? false;
    if (granted) return true; // 已有权限，直接过，不打扰用户

    // 没有权限 → 请求原生弹系统授权窗（用户看到"允许录音吗？"）
    final result =
        await _channel.invokeMethod<bool>('requestMicPermission') ?? false;
    return result;
  }

  /// 开始采集。
  /// 返回 null = 成功；返回错误码字符串 = 失败（调用方翻译成中文提示）。
  Future<String?> start({int sampleRate = 48000, int channels = 1}) async {
    if (isRunning) return null; // 幂等：已在跑就不重复启动

    // 第一步：权限（Android 6.0+ 必须运行时申请，写死在 Manifest 不够）
    if (!await ensurePermission()) return 'PERMISSION_DENIED';

    // 第二步：让原生打开 AudioRecord 并开始采集线程
    // 原生 startMic 约定：成功 success(null)，失败 success("错误码")
    final error = await _channel.invokeMethod<String>('startMic', {
      'sampleRate': sampleRate,
      'channels': channels,
    });
    if (error != null) return error;

    // 第三步：订阅 PCM 水管。receiveBroadcastStream() 是
    // EventChannel 的标准读法，返回 Stream<dynamic>，
    // 原生推的是 ByteArray → 到这里就是 Uint8List。
    isRunning = true;
    _dataSub = _dataChannel.receiveBroadcastStream().listen((event) {
      if (event is! Uint8List) return;
      onData?.call(event); // 原样转发给上层（MicProvider 发 WebSocket）
      onLevel?.call(_rms(event)); // 顺手算个响度给界面
    });
    return null;
  }

  /// 停止采集并释放原生资源
  Future<void> stop() async {
    if (!isRunning) return;
    isRunning = false;
    await _dataSub?.cancel(); // 先关水管（listen 了必须 cancel）
    _dataSub = null;
    await _channel.invokeMethod('stopMic'); // 再让原生停线程、release
  }

  /// 计算一块 PCM s16le 数据的 RMS 响度（均方根），归一化 0.0 ~ 1.0。
  ///
  /// 通俗解释：把每个采样值平方 → 求平均 → 开平方，
  /// 得到"平均能量"，比取最大值更稳定，适合画电平条。
  double _rms(Uint8List data) {
    if (data.length < 2) return 0;
    // asByteData()：把字节数组"换个视角"看成 16 位采样序列
    final bd = ByteData.sublistView(data);
    double sum = 0;
    final count = data.length ~/ 2; // ~/ 是整数除法：字节数 ÷2 = 采样数
    for (var i = 0; i < count; i++) {
      final s = bd.getInt16(i * 2, Endian.little); // 小端序读 16 位采样
      sum += s * s;
    }
    // 32768 = i16 的最大幅度，除完结果落在 0~1
    return math.sqrt(sum / count) / 32768.0;
  }

  // ── v3.1：麦克风守护前台服务 ────────────────────────────────
  // 作用：连上电脑后挂一条常驻通知，让系统不要杀进程 ——
  // 息屏状态下 PC 的唤醒指令（mic_state）才能随时送达。
  // 注意这个服务本身不开麦克风，省电靠的就是"只在需要时开采集"。

  /// 启动守护服务（连接成功、待命登记前调用）
  Future<void> startStandbyService() async {
    try {
      await _channel.invokeMethod('startMicStandby');
    } catch (_) {
      // 服务启动失败（如通知权限被拒）不致命：手机亮屏时功能照常，
      // 只是息屏待机不可靠，不做错误弹窗打扰
    }
  }

  /// 停止守护服务（手动关闭麦克风、断开连接时调用）
  Future<void> stopStandbyService() async {
    try {
      await _channel.invokeMethod('stopMicStandby');
    } catch (_) {}
  }

  /// 释放（App 退出时调用；stop 内部已处理未启动的情况）
  Future<void> dispose() async {
    await stop();
    await stopStandbyService();
  }
}
