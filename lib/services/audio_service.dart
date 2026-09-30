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
//
// ── 补充说明书（给初学者，以下全是注释，不含任何代码改动）─────────────────
//
// 【谁调用我】
//   lib/providers/connection_provider.dart —— 连接状态变 connected 时调
//     startStreaming()、断开时调 stopStreaming()；每来一块音频字节调
//     receiveAudioData()；收到服务器 audio_config 时调 updateConfig()。
//   lib/providers/device_provider.dart —— setEnabled()/setMuted()（首页与
//     音响页那个"启用/禁用"块和静音，账本在它那边，这里只执行）。
//   lib/screens/speaker_screen.dart —— 只读 getter（sampleRate/channelCount/
//     nominalBitrateMbps/bytesReceived/isPlaying）用来画"音响详情页"的真数据。
//   lib/screens/home_screen.dart —— 首页返回键调 goHome()。
//   lib/main.dart —— Provider<AudioService> 创建这一个全局单例，App 退出时 dispose()。
//
// 【我调用谁】只调用 Android 原生层，不碰网络、不碰界面：
//   android/app/src/main/kotlin/com/pcspeaker/pc_speaker/MainActivity.kt
//   （第 146 行定义 CHANNEL，第 249 行起 setMethodCallHandler 接方法）。
//
// 【数据流方向】严格单向、只进不出：
//   PC(Rust AudioServer) --WebSocket--> NetworkService --流--> ConnectionProvider
//     --> 本服务 --> 原生 AudioTrack --> 手机扬声器
//   上行（话筒/摄像头回 PC）与我无关，见 lib/services/mic_service.dart、
//   lib/services/camera_service.dart。全双工（边放边录）靠的就是两条独立通路。
//
// 【PCM 字节到底是什么】未压缩的原始采样序列，一秒的字节数=
//   采样率(Hz) × 声道数 × 每样本字节数。本项目格式是 pcm_s16le
//   （16 位有符号整数、小端序），即每样本固定 2 字节：
//     48000 × 2 × 2 = 192000 字节/秒（下行播放 ≈ 0.19 MB/秒）
//     48000 × 1 × 2 =  96000 字节/秒（麦克风上行是单声道，见 mic_service）
//   所以 bytesReceived 每秒大约涨 19 万；页面上"已接收"的 MB 数就是它除以
//   1024×1024（换算函数 _fmtBytes 在 speaker_screen.dart 里）。
//
// 【新手建议阅读顺序】_init() → startStreaming() → receiveAudioData() →
//   updateConfig() → dispose()，其余 getter 最后扫一眼即可。
//
// 【为什么走原生 AudioTrack，而不用 Flutter 音频插件】项目历史：早先用第三方
//   插件 flutter_pcm_sound 播 PCM，它在回调线程里做重活，实测会触发 ANR
//   （Application Not Responding：主线程被卡太久，系统弹"应用无响应"并可杀进程）。
//   所以改成现在这条路：Dart 只发一次 invokeMethod('write')，真正阻塞的
//   AudioTrack.write 放在原生自己的单线程执行器里。插件残留的构建补丁还能在
//   android/build.gradle.kts:11 附近看到，可当历史证据；设计稿
//   design/audioserver-v3-ui.html:499 也明确写了"不引入 flutter_pcm_sound"。
//
// 【发现但没改的一处不一致（仅标注）】上面第 4、5 条"每次 write 后 flush、
//   用 isWriting 标志防并发"是旧版原生实现的做法。现在 MainActivity.kt 的
//   writeAudio（约 470 行起的注释）明确写着"不调 flush()""不用 isWriting 丢包"，
//   改为靠 executor 排队 + AudioTrack.write 阻塞天然形成背压（backpressure：
//   写不过来时让写入方慢下来，而不是丢数据，丢数据会造成波形断裂→杂音）。
//   以原生代码为准；要不要改这段头部文字由作者决定，本任务不动任何代码行。
// ============================================================================

// dart:typed_data：提供 Uint8List —— "无符号 8 位整型数组"，也就是紧密排列
//   的原始字节。音频在网线/通道里跑的就是这种字节串。
//   为什么不用普通 List<int>：List<int> 每个元素可能占 4~8 字节且有对象头，
//   Uint8List 每个元素严格 1 字节、内存连续，搬运 PCM 才既省内存又快。
// package:flutter/services.dart：Flutter 官方"和原生打交道"的库，
//   本文件只用它的 MethodChannel（顺带提供 ByteData/Endian 这些字节视图类型）。
// 备注（不改代码）：flutter_lints 有个 unnecessary_import 规则，会在
//   "A import 提供的类型已被 B import 转导出"时提示可以删掉 A。
//   若 analyze 在这两行报提示，删掉多余那个即可，由作者处理。
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// 音频服务 - 接收 PCM 字节流并实时播放
class AudioService {
  /// 平台通道，与原生 AudioTrack 通信
  // MethodChannel 的名字是"Dart 和原生的门牌号"，两边必须一字不差：
  //   原生 MainActivity.kt:146 写的是 private val CHANNEL = "com.pcspeaker/audio"，
  //   Dart 这边也必须写成一模一样的字符串。
  //   名字打错一个字母：编译期不报错，运行时 await 回来的是
  //   MissingPluginException（"没人接这个通道"），排查成本很高 —— 这是新手最容易踩的坑。
  // 收发关系（新手必记）：
  //   Dart 侧  _channel.invokeMethod('setup', 参数Map)
  //   原生侧  MethodChannel(...).setMethodCallHandler { call, result -> when(call.method){"setup" -> ...} }
  //   原生用 result.success(值) / result.error(code, msg, null) 回话；
  //   success → invokeMethod 返回的 Future 正常完成（拿到值）
  //   error   → 那个 Future 抛 PlatformException（所以下面很多地方要 try/catch）
  // 为什么是 static const：通道对象只是一张"门牌"，不持有播放状态，
  //   全类共用一个就够；const 让它成为编译期常量，也不会每次 new 服务再建一个。
  static const MethodChannel _channel = MethodChannel('com.pcspeaker/audio');

  // ── 播放参数：下面两个默认值只是"还没连上服务器时的盲猜"──
  // 一连上，服务器会发 audio_config 文本帧带真实参数，updateConfig() 覆盖它们。
  // 为什么默认 48000/2：48kHz 是 CD 级采样率，也是 Windows 声卡 WASAPI 共享模式的
  //   混音频率（48000Hz/16bit/立体声），PC 抓到的系统声音天然就是这个格式，
  //   手机照原样播放完全不需要重采样。改成 44100 也能跑，但两端必须同时改，
  //   否则要么变速变调、要么每秒差 3900 字节的"饥饿/堆积"。
  // bool 是布尔类型（只能 true/false）。这两个标志合起来就是一个极简状态机：
  //   _isInitialized = 原生 AudioTrack 是否已成功 setup（硬件对象存在）
  //   _isPlaying     = 是否已 play()（AudioTrack 正在消费写入的数据）
  int _sampleRate = 48000;
  int _channelCount = 2;
  bool _isPlaying = false;
  bool _isInitialized = false;

  /// 累计写入扬声器的字节数（v3.6：音响详情页显示"已接收"）
  int _bytesReceived = 0;

  // ── v3.6：音响的两把"手动闸"（都由 DeviceProvider 负责持久化）──────
  // _enabled：音响功能的总开关。false = 用户在本机禁用了这个设备，
  //   此时 startStreaming() 直接不干活、来数据也不写扬声器。
  //   注意它和"静音"是两回事：禁用是功能级关闭，静音只是暂时不出声。
  // _muted：临时静音（会话保留）。true = 数据照常到达，但不落到扬声器。
  bool _enabled = true;
  bool _muted = false;

  /// 初始化任务的 Future
  // 这一行浓缩了三个 Dart 新手必学点，逐个说：
  // 1) Future = "一件还没做完但将来会做完的事" 的凭据。
  //    Dart 是单线程事件循环（isolate）模型：耗时活（跨语言调用、网络、读盘）
  //    不能原地死等，否则界面就卡住。于是函数立刻返回一个 Future 凭证，
  //    干完活再"兑现"它。async/await 是它的语法糖：
  //      async 标记函数返回 Future；await 暂停当前函数、等凭据兑现再继续，
  //      等待期间线程可以去处理别的事（不阻塞、不吃 CPU）。
  //    为什么调原生要 await：invokeMethod 是跨语言往返（Dart→C++ 消息编码→
  //    Kotlin 执行→原路回话），结果不可能在本地凭空出现，只能等回执。
  // 2) late：告诉编译器"这个字段我先声明、稍后（在构造函数体里）再赋值，
  //    别在构造阶段催我"。final 字段必须被赋值一次且只能一次，
  //    而这里要读同类的其它字段（_sampleRate 等），只能放到函数体里赋值，
  //    所以用 late final 组合。
  // 3) 存的是 Future 对象本身而不是结果：以后任何地方 `await _initFuture`
  //    等的都是【同一次】setup。若写成 `await _init()`，调几次就发几次 setup，
  //    等于重复初始化。这是"一次性异步初始化"的标准套路（首次 await，之后秒回）。
  late final Future<void> _initFuture;

  // 构造函数：Dart 的构造函数【不能】标 async，所以不能"等原生建好 AudioTrack
  // 再返回对象"。做法是 fire-and-forget（发出去就不管）：把异步任务的 Future
  // 存进 _initFuture，真正要用播放的时候（startStreaming）再去 await 它。
  AudioService() {
    _initFuture = _init();
  }

  /// 初始化：配置原生 AudioTrack
  Future<void> _init() async {
    // try/catch/finally 复习（本文件只用 try/catch）：
    //   try 里放"可能失败的活"；catch 接住抛出的异常对象；finally 不管成败都执行
    //   （本文件没有 finally，network_service.dart 的注释里再讲一遍整体语义）。
    //   这里必须包起来：原生 handler 还没挂上（热重载后）、或 iOS 侧没实现这个方法时，
    //   invokeMethod 会抛 MissingPluginException / PlatformException，
    //   不接住就会让整个 App 崩在构造阶段。
    try {
      // 方法名 'setup' 对应原生 MainActivity.kt 里 when(call.method) 的 "setup" 分支，
      //   那边收到后调 setupAudio(sampleRate, channels) 新建 AudioTrack。
      // 第二个参数是 Map<String, Object>：StandardMessageCodec 会把它编码成
      //   原生能读的结构，Kotlin 用 call.argument<Int>("sampleRate") 按 key 取值。
      //   key 字符串同样是"两端约定"，写错了原生只会拿到 null 走默认值（48000/2）。
      // await：一定要等原生真的建好 AudioTrack 再往下走，
      //   否则 _isInitialized 会提前置 true，后面 write 就写进一个不存在的对象。
      await _channel.invokeMethod('setup', {
        'sampleRate': _sampleRate,
        'channels': _channelCount,
      });
      // 只有原生回了 success 才会执行到这里（异常路径直接跳 catch）。
      _isInitialized = true;
    } catch (_) {}
    // catch (_) {}：下划线是 Dart 的惯用占位名，表示"这个异常对象我不用它"；
    // 空 catch = 静默失败（此时 _isInitialized 保持 false，startStreaming 会自己退回）。
  }

  /// 开始接收音频流（ConnectionProvider 在连接成功后调用）
  // 返回类型 Future<void>：调用方可以 await 它确认"启动动作跑完了"，
  // 但 ConnectionProvider 那边（connection_provider.dart 监听 1）没 await，
  // 属于"通知式调用"，界面刷新由流事件驱动，不依赖这个返回值。
  Future<void> startStreaming() async {
    // v3.6：音响被禁用时，连上了也不出声 —— 这是"禁用即不可用"的落点。
    if (!_enabled) return;
    // 还没 setup 成功 → 去等构造函数里发出的那次 _init()（同一个 Future，
    // 不会重复初始化）。等完再判一次：如果确实失败（iOS/原生异常），
    // 就安静放弃，不抛异常打断上面的连接流程。
    if (!_isInitialized) {
      await _initFuture;
      if (!_isInitialized) return;
    }
    // 幂等保护：已经在播就什么都不做。
    // 为什么要这句：connected 事件可能重复送达（重连、切 Tab），
    // 重复给原生发 start 会让 AudioTrack.play() 被多次调用（虽然多数机型无害，
    // 但会白白产生一次跨语言往返）。
    if (_isPlaying) return;

    try {
      // 原生 "start" 分支 = audioTrack?.play()，让硬件开始消费写入的字节。
      await _channel.invokeMethod('start');
      _isPlaying = true;
    } catch (_) {}
  }

  /// 接收一块音频数据（每收到一帧 WebSocket 数据就调用一次）
  ///
  /// 低延迟关键：收到数据立即写入原生 AudioTrack，不做任何缓冲
  //
  // 【注意这个方法的签名】它是 void（同步），不是 Future<void>：
  //   整条下行链路里唯一一个"故意不等原生回话"的调用就在这儿。
  //   调用方是 ConnectionProvider 的流回调（connection_provider.dart 的"监听 2"），
  //   每秒大约有 50~100 个包过来（每包几 KB），如果这里也 await 原生回执，
  //   每个包都要走完"编码→Kotlin→排队写入→回 success"一整圈，
  //   回调链会被拖慢、包在流里堆积，延迟立刻涨起来 —— 这正是"低延迟"要防的事。
  //   顺序与限速交给原生侧保证：单线程 executor 保证写入不乱序，
  //   AudioTrack.write 阻塞天然背压（见文件头那条订正说明）。
  //   代价要心里有数：这里拿不到失败反馈，原生 result.error("INVALID_DATA")
  //   只会以未处理异常的形式出现在日志里，排错得看 logcat / flutter run 输出。
  void receiveAudioData(Uint8List data) {
    // 两道闸：禁用（功能关了）或静音（临时不出声）都不往扬声器写。
    if (!_enabled || _muted) return;
    // 卫语句（guard clause）：条件不满足就一行 return 提前退出，
    // 免得把主逻辑裹进好几层 if 嵌套。void 函数里的 return 可以不带值。
    if (!_isPlaying) return;

    // 直接写入原生层，几乎零延迟
    // data 这个 Uint8List 会被 StandardMessageCodec 原样映射成 Kotlin 的
    // ByteArray（MainActivity 里 call.argument<ByteArray>("data")），
    // 不经过任何编解码/压缩 —— PCM 直通的代价是带宽大，换来的是延迟极低。
    _channel.invokeMethod('write', {'data': data});
    // 累计字节数：详情页"已接收"计数用。int 在 Dart 里是 64 位，
    // 按 1.5 Mbps 跑一整天也溢出不了，不需要特殊处理。
    // 参照量：48kHz 立体声 16bit 满速 = 192000 字节/秒 ≈ 11.5 MB/分钟。
    _bytesReceived += data.length;
  }

  /// v3.6：音响功能总开关（由首页/音响页的"启用/禁用"块驱动，值存本地）。
  /// 关闭 = 立刻停播放；重新打开 = 若已连着电脑则马上恢复接收。
  // 谁在调它：lib/providers/device_provider.dart（_audio.setEnabled(...)，
  // 见该文件约 120/140 行），它同时把开关值存进 SharedPreferences。
  // 第一行是"值没变就退出"的幂等写法：UI 重复点击不会反复停/启硬件。
  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    if (!on) {
      await stopStreaming();
    } else {
      await startStreaming();
    }
  }

  /// v3.6：临时静音（会话保留，数据照常到达，只是不落扬声器）
  // 标了 async 但函数体里没有 await：只是为了和 setEnabled 保持同样的
  // Future<void> 签名，方便 device_provider 用同一套 await 调用（可改进：
  // 去掉 async 直接返回 void，但会改变调用方的写法，本任务不动代码）。
  Future<void> setMuted(bool on) async {
    _muted = on;
  }

  // getter（只读取访问器）语法：bool get isEnabled => 表达式;
  // 外部写成 audio.isEnabled（没有括号！），看着像字段，实际是方法调用。
  // 为什么这么绕：把字段做成私有（_enabled）+ 只给 getter，
  // 外部就无法绕过 setEnabled 直接改状态，"改状态只有唯一入口"。
  // => 是"箭头函数"简写，等价于 { return ...; }，只适合一行表达式。
  bool get isEnabled => _enabled;
  bool get isMuted => _muted;

  // ── v3.6：音响详情页要显示的真实参数（只读出口）──
  // 之前这几个数只有服务内部知道，页面只能写死"48kHz 立体声"这种假文案；
  // 现在把它们暴露出来，显示的一定是服务器实际下发的配置。
  // 用法见 lib/screens/speaker_screen.dart。
  int get sampleRate => _sampleRate;
  int get channelCount => _channelCount;

  /// 当前链路的理论码率（bps）。
  /// 算法：采样率 × 声道数 × 每样本字节数(16bit=2) × 8 bit，
  /// 例：48000×2×2×8 = 1.536 Mbps。这是"链路满速"，不是实时统计，
  /// 用来让用户对"占多少带宽"有个数量级概念，界面需标注"约"。
  // 逐项拆给新手：
  //   bps = bits per second（比特每秒）；Mbps = 兆比特每秒。
  //   ×2（每样本字节数）来自原生 ENCODING_PCM_16BIT：16 bit = 2 字节。
  //   ×8 是"字节换成比特"。
  //   /1e6 里的 1e6 是浮点字面量，意思是 1×10^6 = 1000000（注意是 100 万，
  //   不是 1048576 —— 网络码率一向按十进制算）。
  // 返回类型是 double（带小数），因为 1536000/1e6 有小数；界面用
  //   toStringAsFixed(2) 保留两位显示。
  // 隐患提示（不改代码）：这里的"2 字节/样本"是写死的，对应 16bit 格式；
  //   将来若改用 32bit float，这一行会算少一半，需要跟着调整。
  double get nominalBitrateMbps => _sampleRate * _channelCount * 2 * 8 / 1e6;

  /// 累计写入扬声器的字节数（详情页显示"已接收"用）
  int get bytesReceived => _bytesReceived;

  /// 停止音频流（断开连接时调用）
  // 调用点：connection_provider.dart 里 disconnected 分支 + 本文件 setEnabled(false)。
  Future<void> stopStreaming() async {
    // 没在播就别白发一次跨语言调用（幂等）
    if (!_isPlaying) return;

    try {
      // 发的是 pause 不是 stop/release：AudioTrack 保留缓冲区和音频会话，
      // 下次 start 立刻能续上；重建硬件有几十毫秒抖动，会影响重连体验。
      // 原生对应 "pause" 分支 → audioTrack?.pause()。
      await _channel.invokeMethod('pause');
      _isPlaying = false;
    } catch (_) {}
  }

  /// 更新音频配置（服务器连接后发送 JSON 配置头时调用）
  // 触发路径：WebSocket 文本帧 {"type":"audio_config",...}
  //   → network_service.dart 解析成 AudioConfig → audioConfigStream
  //   → connection_provider.dart"监听 3" → 这里。参见那两个文件。
  // 命名参数（{required int sampleRate}）：调用时必须写名字
  //   updateConfig(sampleRate: 48000, channelCount: 2)，
  //   required 表示漏一个就编译报错 —— 位置参数容易传反，命名参数不会。
  Future<void> updateConfig({
    required int sampleRate,
    required int channelCount,
  }) async {
    // 参数完全没变 → 直接返回。为什么重要：下面会 setup（=原生重建 AudioTrack）
    // 再 start，中间有一段静音间隙；服务器每次连接都可能重发配置，不做这层
    // 去重就会出现"明明什么都没改却咔一下"。
    if (sampleRate == _sampleRate && channelCount == _channelCount) return;

    // 先记账再动手：即使后面原生失败，Dart 侧认为的参数与意图是一致的。
    _sampleRate = sampleRate;
    _channelCount = channelCount;

    if (_isInitialized) {
      try {
        // AudioTrack 的采样率/声道数在创建后就不能改，所以"改配置 = 重建"：
        // 原生 "setup" 分支内部先 releaseAudio() 再 new AudioTrack
        // （见 MainActivity.kt 的 setupAudio 开头几行）。
        await _channel.invokeMethod('setup', {
          'sampleRate': _sampleRate,
          'channels': _channelCount,
        });

        // 重建会把播放状态丢掉，所以要补一句 start 把 play() 恢复回来；
        // 判断 _isPlaying 是为了"原来没在播就别擅自开播"。
        if (_isPlaying) {
          await _channel.invokeMethod('start');
        }
      } catch (_) {}
    }
  }

  /// 设置音量（预留功能）
  // "预留"就是空方法体：签名先占好位置，以后实现时调用方一行不用改。
  // 新手注意：调用 audio.setVolume(0.5) 现在【什么也不会发生】，也不报错。
  // 将来该怎么做：让原生调 AudioTrack.setVolume(0.0~1.0) 或走 AudioManager
  // 改 STREAM_MUSIC 音量；不要在 Dart 侧把 PCM 字节里的采样值乘 0.5 ——
  // 那会引入量化噪声、还要处理溢出，且改的是数据本身而不是硬件音量。
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
    // 顺带说明"通道复用"：goHome 和音频毫无关系，但它仍走 'com.pcspeaker/audio'
    // 这条通道 —— 一条通道可以挂任意多个方法名，原生用 when(call.method) 分流，
    // 没必要为一个小功能再开一个 MethodChannel 名字（每多一个名字，两端就多
    // 一处要对齐的字符串，出错面更大）。
    try {
      await _channel.invokeMethod('goHome');
    } catch (_) {
      // 万一原生层没响应（比如热重载后通道未就绪、或 iOS 的 notImplemented），
      // 静默失败即可——用户再按一次返回键就好
      // 补充：这里被 catch 的异常具体是 MissingPluginException（通道/handler 不存在）
      // 或 PlatformException（原生明确 result.error(...)，iOS 的 notImplemented 就是这种）。
    }
  }

  // 播放中吗？（device_provider.dart 用它算设备状态词：isPlaying 且没静音 → "使用中"）
  bool get isPlaying => _isPlaying;

  /// 释放全部资源（App 退出时由 main.dart 触发）
  // main.dart 里 Provider<AudioService> 的 dispose 回调指向这里。
  Future<void> dispose() async {
    // 收尾顺序很关键：先 pause（停止消费）→ 再 release（销毁硬件对象）。
    // 反过来的话，原生可能在已 release 的 AudioTrack 上 pause，
    // 抛 IllegalStateException 被 catch 吞掉，但设备可能残留占用。
    await stopStreaming();
    try {
      // 原生 "release" 分支 → audioTrack?.release(); audioTrack = null
      await _channel.invokeMethod('release');
      // 置回 false：App 若还活着（例如热重载后重建服务），
      // startStreaming 会看到未初始化并重新走一次 _init()。
      _isInitialized = false;
    } catch (_) {}
  }
}
