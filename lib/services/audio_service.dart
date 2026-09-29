// ============================================================================
// audio_service.dart —— 音频服务层（实时 PCM 播放）
// ----------------------------------------------------------------------------
// 职责：接收从 NetworkService 转发来的音频字节，通过 flutter_pcm_sound
// 直接送到手机扬声器播放。
//
//   电脑(Rust服务器) --WebSocket--> NetworkService --流--> AudioService --> 扬声器
//
// 工作原理（"拉模式"回调）：
//   1. setup() 配置采样率/声道数
//   2. start() 启动播放引擎
//   3. 引擎缓冲区快空时，调用 _onFeed 回调
//   4. 回调里调 feed() 喂一批 PCM 样本
//   5. 循环 3-4，直到 stop()
//
// 关键设计：
//   - 回调里只做最少工作（标记 + 调度），避免阻塞原生线程导致 ANR
//   - 用 Future.microtask 把实际 feed 操作推迟到 Dart 事件循环
//   - 缓冲区空时喂静音，保持回调链活跃
// ============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// 音频服务 - 接收 PCM 字节流并实时播放
class AudioService {
  /// 音频样本缓冲区
  final List<int> _sampleBuffer = [];

  int _sampleRate = 48000;
  int _channelCount = 2;
  bool _isPlaying = false;
  bool _isInitialized = false;

  /// 防止并发 feed 的标志
  bool _isFeeding = false;

  /// 初始化任务的 Future
  late final Future<void> _initFuture;

  AudioService() {
    _initFuture = _init();
  }

  /// 初始化：配置 flutter_pcm_sound 引擎参数
  Future<void> _init() async {
    try {
      await FlutterPcmSound.setup(
        sampleRate: _sampleRate,
        channelCount: _channelCount,
      );
      // 2400 帧 ≈ 50ms @48kHz，平衡延迟和稳定性
      await FlutterPcmSound.setFeedThreshold(2400);
      FlutterPcmSound.setFeedCallback(_onFeed);
      _isInitialized = true;
    } catch (_) {}
  }

  /// "需要数据"回调 —— 引擎缓冲区快空时被调用
  ///
  /// 【关键】这个函数必须极轻量！
  /// 它在原生音频线程被调用，任何耗时操作都会导致 ANR。
  /// 策略：只设置标志 + 用 microtask 调度实际工作到 Dart 事件循环
  void _onFeed(int remainingFrames) {
    // 只设置标志，不 await，不创建大对象
    if (!_isFeeding) {
      _isFeeding = true;
      // 用 microtask 把实际 feed 推迟到 Dart 事件循环，立即返回
      Future.microtask(_doFeed);
    }
  }

  /// 实际的 feed 操作（在 Dart 事件循环中执行，不在原生线程）
  Future<void> _doFeed() async {
    // 每次喂 2400 帧 = 50ms @48kHz
    const int feedFrames = 2400;
    final int needSamples = feedFrames * _channelCount;

    List<int> samples;

    if (_sampleBuffer.length >= needSamples) {
      // 缓冲区充足：取正好需要的量
      samples = _sampleBuffer.sublist(0, needSamples);
      _sampleBuffer.removeRange(0, needSamples);
    } else if (_sampleBuffer.isNotEmpty) {
      // 缓冲区有部分数据：取真实数据 + 补静音
      samples = List<int>.from(_sampleBuffer);
      _sampleBuffer.clear();
      // 补静音到固定长度
      while (samples.length < needSamples) {
        samples.add(0);
      }
    } else {
      // 缓冲区空了：全静音，但继续喂以保持回调链活跃
      samples = List<int>.filled(needSamples, 0);
    }

    // 现在可以安全地创建 PcmArrayInt16 并 feed
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));

    // 释放标志，允许下次回调触发新的 feed
    _isFeeding = false;
  }

  /// 开始接收音频流（ConnectionProvider 在连接成功后调用）
  Future<void> startStreaming() async {
    if (!_isInitialized) {
      await _initFuture;
      if (!_isInitialized) return;
    }
    if (_isPlaying) return;

    try {
      _sampleBuffer.clear();
      _isFeeding = false;

      final started = FlutterPcmSound.start();
      if (!started) return;

      _isPlaying = true;
    } catch (_) {}
  }

  /// 接收一块音频数据（每收到一帧 WebSocket 数据就调用一次）
  void receiveAudioData(Uint8List data) {
    if (!_isPlaying) return;

    // WebSocket 返回的 Uint8List 可能带有非零 offsetInBytes，
    // 需要先拷贝到独立 buffer 再转 Int16List，避免数据污染
    if (data.length % 2 != 0) {
      data = data.sublist(0, data.length - 1);
    }
    final cleanBytes = Uint8List.fromList(data);
    final samples = cleanBytes.buffer.asInt16List();
    _sampleBuffer.addAll(samples);

    // 缓冲区溢出保护：超过 2 秒音频就丢弃最旧的
    final maxSamples = _sampleRate * _channelCount * 2;
    if (_sampleBuffer.length > maxSamples) {
      final dropCount = _sampleBuffer.length - maxSamples;
      _sampleBuffer.removeRange(0, dropCount);
    }
  }

  /// 停止音频流（断开连接时调用）
  Future<void> stopStreaming() async {
    if (!_isPlaying) return;
    try {
      await FlutterPcmSound.release();
      _isInitialized = false;
      _sampleBuffer.clear();
      _isPlaying = false;
      _isFeeding = false;
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
        await FlutterPcmSound.setup(
          sampleRate: _sampleRate,
          channelCount: _channelCount,
        );
        await FlutterPcmSound.setFeedThreshold(2400);
        FlutterPcmSound.setFeedCallback(_onFeed);

        if (_isPlaying) {
          FlutterPcmSound.start();
        }
      } catch (_) {}
    }
  }

  /// 设置音量（预留功能，flutter_pcm_sound 暂不支持）
  Future<void> setVolume(double volume) async {}

  bool get isPlaying => _isPlaying;

  /// 释放全部资源（App 退出时由 main.dart 触发）
  Future<void> dispose() async {
    await stopStreaming();
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
