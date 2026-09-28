import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

/// 音频服务 - 负责接收和播放音频流
class AudioService {
  final _logger = Logger(printer: PrettyPrinter(methodCount: 0));
  late final AudioPlayer _audioPlayer;

  // 音频流控制器
  StreamController<List<int>>? _audioStreamController;

  // 音频缓冲
  final List<int> _audioBuffer = [];
  static const int _bufferThreshold = 4800; // 缓冲阈值（字节）

  bool _isPlaying = false;

  AudioService() {
    _audioPlayer = AudioPlayer();
    _initPlayer();
  }

  void _initPlayer() {
    // 监听播放器状态
    _audioPlayer.playerStateStream.listen((state) {
      _logger.d('播放器状态: playing=${state.playing}, processingState=${state.processingState}');
    });

    // 监听错误
    _audioPlayer.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _logger.e('播放器错误: $e');
      },
    );
  }

  /// 开始接收音频流
  void startStreaming() {
    _audioStreamController = StreamController<List<int>>();
    _audioBuffer.clear();
    _isPlaying = true;
    _logger.i('音频流已开始');
  }

  /// 接收音频数据
  void receiveAudioData(Uint8List data) {
    if (!_isPlaying || _audioStreamController == null) return;

    _audioBuffer.addAll(data);

    // 当缓冲达到阈值时，开始播放
    if (_audioBuffer.length >= _bufferThreshold && !_audioPlayer.playing) {
      _playBufferedAudio();
    }
  }

  void _playBufferedAudio() async {
    try {
      // 将缓冲数据转换为音频源
      // 注意：这里需要根据实际音频格式调整
      // 假设是 PCM 16-bit, 44.1kHz, stereo
      final audioData = Uint8List.fromList(_audioBuffer);

      // 使用 AudioSource 播放
      // 实际项目中可能需要使用更复杂的流式播放方案
      _logger.d('开始播放缓冲音频，大小: ${audioData.length} bytes');

      // 这里需要根据实际的音频编码格式来处理
      // 如果是 PCM 原始数据，需要使用特定的解码器
      // 如果是 AAC/MP3 等编码格式，可以直接播放

    } catch (e) {
      _logger.e('播放音频失败: $e');
    }
  }

  /// 停止音频流
  void stopStreaming() {
    _isPlaying = false;
    _audioStreamController?.close();
    _audioStreamController = null;
    _audioBuffer.clear();
    _audioPlayer.stop();
    _logger.i('音频流已停止');
  }

  /// 设置音量 (0.0 - 1.0)
  Future<void> setVolume(double volume) async {
    await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
  }

  /// 是否正在播放
  bool get isPlaying => _isPlaying;

  /// 释放资源
  void dispose() {
    stopStreaming();
    _audioPlayer.dispose();
  }
}
