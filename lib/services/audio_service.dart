// ============================================================================
// audio_service.dart —— 音频服务层（实时 PCM 播放）
// ----------------------------------------------------------------------------
// 职责：接收从 NetworkService 转发来的音频字节，通过原生 AudioTrack
// 直接送到手机扬声器播放。
//
//   电脑(Rust服务器) --WebSocket--> NetworkService --流--> AudioService --> 扬声器
//
// 低延迟设计（参考 AudioShare 开源项目）：
//   1. 使用 Android 原生 AudioTrack，设置 FLAG_LOW_LATENCY
//   2. 使用 AudioTrack.getMinBufferSize() 获取最小缓冲区
//   3. 收到数据立即写入，几乎无中间缓冲
//   4. 每次 write 后 flush，清空缓冲区减少延迟
//   5. 用 isWriting 标志防止并发写入
// ============================================================================

import 'dart:typed_data';
import 'package:flutter/services.dart';

/// 音频服务 - 接收 PCM 字节流并实时播放
class AudioService {
  /// 平台通道，与原生 AudioTrack 通信
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  int _sampleRate = 48000;
  int _channelCount = 2;
  bool _isPlaying = false;
  bool _isInitialized = false;

  /// 初始化任务的 Future
  late final Future<void> _initFuture;

  AudioService() {
    _initFuture = _init();
  }

  /// 初始化：配置原生 AudioTrack
  Future<void> _init() async {
    try {
      await _channel.invokeMethod('setup', {
        'sampleRate': _sampleRate,
        'channels': _channelCount,
      });
      _isInitialized = true;
    } catch (_) {}
  }

  /// 开始接收音频流（ConnectionProvider 在连接成功后调用）
  Future<void> startStreaming() async {
    if (!_isInitialized) {
      await _initFuture;
      if (!_isInitialized) return;
    }
    if (_isPlaying) return;

    try {
      await _channel.invokeMethod('start');
      _isPlaying = true;
    } catch (_) {}
  }

  /// 接收一块音频数据（每收到一帧 WebSocket 数据就调用一次）
  ///
  /// 低延迟关键：收到数据立即写入原生 AudioTrack，不做任何缓冲
  void receiveAudioData(Uint8List data) {
    if (!_isPlaying) return;

    // 直接写入原生层，几乎零延迟
    _channel.invokeMethod('write', {'data': data});
  }

  /// 停止音频流（断开连接时调用）
  Future<void> stopStreaming() async {
    if (!_isPlaying) return;

    try {
      await _channel.invokeMethod('pause');
      _isPlaying = false;
    } catch (_) {}
  }

  /// 更新音频配置（服务器连接后发送 JSON 配置头时调用）
  Future<void> updateConfig({
    required int sampleRate,
    required int channelCount,
  }) async {
    if (sampleRate == _sampleRate && channelCount == _channelCount) return;

    _sampleRate = sampleRate;
    _channelCount = channelCount;

    if (_isInitialized) {
      try {
        await _channel.invokeMethod('setup', {
          'sampleRate': _sampleRate,
          'channels': _channelCount,
        });

        if (_isPlaying) {
          await _channel.invokeMethod('start');
        }
      } catch (_) {}
    }
  }

  /// 设置音量（预留功能）
  Future<void> setVolume(double volume) async {}

  /// v3.4.2：回到手机桌面（等价于按了 Home 键），App 退后台继续运行。
  /// 首页的返回键会调用它——而不是让系统直接"退出应用"杀掉进程，
  /// 这样 WebSocket 连接、麦克风/摄像头守护都保持在后台工作。
  /// 真正的实现在原生层 MainActivity.kt 的 "goHome" 分支。
  ///
  /// iOS 行为说明（v3.5 交叉适配审计）：苹果系统【不存在】"应用把自己
  /// 送回桌面"的 API（防止 App 伪装系统行为），所以 AppDelegate.swift
  /// 里 goHome 有意回复 notImplemented → 这里静默捕获，表现为"返回键
  /// 无动作"。iPhone 用户请用上滑手势回桌面——配合 Info.plist 里的
  /// UIBackgroundModes=audio，麦克风与连接照样在后台活着。
  Future<void> goHome() async {
    try {
      await _channel.invokeMethod('goHome');
    } catch (_) {
      // 万一原生层没响应（比如热重载后通道未就绪、或 iOS 的 notImplemented），
      // 静默失败即可——用户再按一次返回键就好
    }
  }

  bool get isPlaying => _isPlaying;

  /// 释放全部资源（App 退出时由 main.dart 触发）
  Future<void> dispose() async {
    await stopStreaming();
    try {
      await _channel.invokeMethod('release');
      _isInitialized = false;
    } catch (_) {}
  }
}
