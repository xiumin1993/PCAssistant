// ============================================================================
// audio_service.dart —— 音频服务层
// ----------------------------------------------------------------------------
// 职责：接收从 NetworkService 转发来的音频字节，缓冲后交给播放器播放。
// 它是"手机变音箱"链条的最后一环：
//
//   电脑(Rust服务器) --WebSocket--> NetworkService --流--> AudioService --> 扬声器
//
// ⚠️ 当前状态说明（重要）：
//   本文件是"骨架 + 待完善"状态。_playBufferedAudio() 里只有日志和 TODO，
//   还没有真正接入解码/播放，因为"PCM 裸数据如何流式播放"需要选型：
//     方案 A：raw_pcm_audio 之类的插件直接播 PCM 流
//     方案 B：服务器发 WAV/OGG 容器格式，用 just_audio 播 StreamAudioSource
//     方案 C：自己往 PCM 前加 44 字节 WAV 头再喂给播放器
//   注释中会在相应位置标出 TODO，供后续开发时参考。
// ============================================================================

// dart:async：StreamController，用于内部流管理（当前主要用于缓冲中转）
import 'dart:async';

// dart:typed_data：Uint8List 字节数组，音频原始数据的载体
import 'dart:typed_data';

// just_audio：本项目使用的音频播放插件（pubspec.yaml 中声明的第三方依赖）。
// 它封装了各平台的原生播放器（Android 用 ExoPlayer，iOS 用 AVPlayer），
// 我们只管调 API，不用关心底层差异。
import 'package:just_audio/just_audio.dart';

// logger：日志库，同 network_service.dart 中的说明
import 'package:logger/logger.dart';

/// 音频服务 - 负责接收和播放音频流
class AudioService {
  /// 日志器（带颜色格式化输出，methodCount:0 不打印调用栈）
  final _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  /// 播放器实例。
  /// late final 的含义：
  ///   final —— 赋值后不可再改；
  ///   late  —— "现在不初始化，但我保证在使用前会赋值"。
  /// Dart 要求非空字段必须在构造时初始化，而这里想先声明、
  /// 在构造函数体里再 new，late 就是这种写法的许可证明。
  late final AudioPlayer _audioPlayer;

  /// 内部音频流控制器（预留：将来做真正的流式播放时，
  /// 收到的字节会经它转发给播放器的数据源）。
  /// 可空：未开始推流时没有这个管道，所以是 StreamController?。
  StreamController<List<int>>? _audioStreamController;

  /// 内存缓冲区：先攒字节，攒够一段再播放。
  /// 为什么要缓冲？网络数据是一小块一小块零碎到达的（每块可能只有
  /// 几百字节），直接喂播放器会因为"数据断档"而卡顿爆音。
  final List<int> _audioBuffer = [];

  /// 缓冲阈值：攒够多少字节才开始播。
  /// 4800 字节的来历：按"PCM 16-bit / 44.1kHz / 双声道"算，
  /// 每秒数据量 = 44100 × 2字节 × 2声道 = 176400 字节/秒，
  /// 4800 字节 ≈ 27 毫秒音频 —— 大约是延迟与流畅的折中起点，
  /// 实际调优时可加大（更流畅但更延迟）或减小（反之）。
  static const int _bufferThreshold = 4800; // static const：全类共享的编译期常量

  /// 是否处于"接收推流"状态。普通布尔私有变量，_ 前缀 = 私有。
  bool _isPlaying = false;

  /// 构造函数：创建 AudioService 时自动 new 出播放器并挂好监听。
  /// 没有参数体，方法体里完成初始化即可。
  AudioService() {
    _audioPlayer = AudioPlayer();
    _initPlayer();
  }

  /// 初始化：给播放器挂"监听器"，用于调试和错误捕获。
  /// 类似汽车仪表盘：播放器内部状态变化时，仪表盘同步显示。
  void _initPlayer() {
    // 监听播放状态流（播放中/暂停/缓冲中/已结束……）。
    // playerStateStream 是 just_audio 暴露的 Stream，
    // listen 的回调会在每次状态变化时被调用。
    _audioPlayer.playerStateStream.listen((state) {
      _logger.d('播放器状态: playing=${state.playing}, processingState=${state.processingState}'); // .d = debug 级别
    });

    // 监听播放事件流，重点是用 onError 捕获异步错误。
    // (_) {} 表示"数据本身不处理，忽略"；
    // 但播放出错时走 onError 回调打印日志。
    // 不挂这个监听的话，播放器内部错误会被静默吞掉，排障极难。
    _audioPlayer.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _logger.e('播放器错误: $e');
      },
    );
  }

  /// 开始接收音频流（ConnectionProvider 在连接成功后调用）。
  /// 建立内部管道、清空旧缓冲、置位标志 —— 进入"待收货"状态。
  void startStreaming() {
    _audioStreamController = StreamController<List<int>>();
    _audioBuffer.clear();
    _isPlaying = true;
    _logger.i('音频流已开始');
  }

  /// 接收一块音频数据（NetworkService 每收到一帧就被调用一次）。
  ///
  /// @param data 原始音频字节（Uint8List 本质就是 `List<int>`，
  ///             每个元素 0~255，对应音频采样的二进制内容）
  void receiveAudioData(Uint8List data) {
    // 卫语句（guard clause）：不在推流状态或管道没建，直接丢弃。
    // 这是一种防御式编程，避免在非法状态下继续往下走。
    if (!_isPlaying || _audioStreamController == null) return;

    // 把新到的字节追加进缓冲区（addAll = 整批加入）
    _audioBuffer.addAll(data);

    // 缓冲达到阈值 且 播放器当前没在播 → 触发一次播放
    // （_audioPlayer.playing 为 false 说明还没开始或已播完）
    if (_audioBuffer.length >= _bufferThreshold && !_audioPlayer.playing) {
      _playBufferedAudio();
    }
  }

  /// 播放缓冲区中攒够的音频。
  ///
  /// ⚠️ 待实现核心（TODO）：目前只是骨架，不会真正出声。
  /// 下一步选型建议（三选一，见文件头说明）：
  ///   TODO: 用 StreamAudioSource / raw_pcm_audio 实现流式播放
  ///   TODO: 或与 Rust 服务器约定发送带 WAV 头的 PCM / OGG 容器格式
  ///
  /// 注：返回 void 的 async 方法在 Dart 里不推荐（调用方无法 await
  /// 和捕获异常）；这里因为是骨架暂未报错，正式实现时建议改成
  /// Future\<void\>。
  void _playBufferedAudio() async {
    try {
      // 把 List<int> 缓冲快照转成不可变字节数组 Uint8List。
      // Uint8List.fromList：逐元素复制并转成 8 位宽度，
      // 这是交给播放器/原生层的标准数据格式。
      final audioData = Uint8List.fromList(_audioBuffer);

      // TODO: 真正的播放调用在这里，例如：
      //   await _audioPlayer.setAudioSource(自定义流数据源);
      //   await _audioPlayer.play();
      _logger.d('开始播放缓冲音频，大小: ${audioData.length} bytes');

      // 关键提醒：just_audio 不能直接播"裸 PCM 流"，它需要
      // 可识别的音频容器（WAV/MP3/AAC/OGG）。所以要么在本端
      // 补 WAV 头，要么让服务器改变编码 —— 这是联调时最先
      // 会踩的坑。
    } catch (e) {
      _logger.e('播放音频失败: $e');
    }
  }

  /// 停止音频流（断开连接时调用）：关管道、清缓冲、停播放。
  /// 每一步都对应 startStreaming 里的动作，对称释放。
  void stopStreaming() {
    _isPlaying = false;
    _audioStreamController?.close(); // ?. 空安全调用：为 null 就跳过
    _audioStreamController = null;
    _audioBuffer.clear();
    _audioPlayer.stop(); // 停止播放并清空播放器自己的缓冲
    _logger.i('音频流已停止');
  }

  /// 设置音量（预留功能：将来电脑端或手机端调音量时用）。
  ///
  /// clamp(min, max)：把值"夹"在 0.0~1.0 之间。
  /// 传 2.0 会变成 1.0，传 -1 会变成 0.0 —— 防止非法值导致播放器异常。
  /// 返回 `Future<void>` 因为设置音量是异步操作（要跨到原生层），
  /// 调用方可 await 确认完成。
  Future<void> setVolume(double volume) async {
    await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
  }

  /// 对外只读属性：是否正在接收推流。
  /// getter 写法让外部用 provider.isPlaying 直接读，不用写 .getIsPlaying()。
  bool get isPlaying => _isPlaying;

  /// 释放全部资源（App 退出时由 main.dart 触发）。
  /// 顺序讲究：先停业务（stopStreaming），再销毁播放器本体。
  /// AudioPlayer.dispose 会释放原生层占用（音频焦点、解码器等），
  /// 不调用它可能造成其他 App 无声等诡异问题。
  void dispose() {
    stopStreaming();
    _audioPlayer.dispose();
  }
}
