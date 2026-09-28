import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 网络连接状态
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// 网络服务 - 管理 WebSocket 连接
class NetworkService {
  final _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final _audioDataController = StreamController<Uint8List>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// 连接状态流
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  /// 音频数据流
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  /// 错误信息流
  Stream<String> get errorStream => _errorController.stream;

  /// 当前连接状态
  ConnectionStatus get status => _status;

  /// 是否已连接
  bool get isConnected => _status == ConnectionStatus.connected;

  /// 连接到服务器
  Future<void> connect(String serverAddress) async {
    if (_status == ConnectionStatus.connecting) return;

    _updateStatus(ConnectionStatus.connecting);

    try {
      // 构建 WebSocket URL
      final url = serverAddress.startsWith('ws://')
          ? serverAddress
          : 'ws://$serverAddress/ws/audio';

      _logger.i('正在连接到: $url');

      _channel = WebSocketChannel.connect(Uri.parse(url));

      // 等待连接建立
      await _channel!.ready;

      _logger.i('WebSocket 连接已建立');
      _updateStatus(ConnectionStatus.connected);

      // 监听消息
      _subscription = _channel!.stream.listen(
        (data) {
          if (data is Uint8List) {
            _audioDataController.add(data);
          } else if (data is List<int>) {
            _audioDataController.add(Uint8List.fromList(data));
          }
        },
        onError: (error) {
          _logger.e('WebSocket 错误: $error');
          _errorController.add('连接错误: $error');
          _updateStatus(ConnectionStatus.error);
        },
        onDone: () {
          _logger.i('WebSocket 连接已关闭');
          _updateStatus(ConnectionStatus.disconnected);
        },
      );
    } catch (e) {
      _logger.e('连接失败: $e');
      _errorController.add('连接失败: $e');
      _updateStatus(ConnectionStatus.error);
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _subscription?.cancel();
    _subscription = null;

    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }

    _updateStatus(ConnectionStatus.disconnected);
    _logger.i('已断开连接');
  }

  /// 发送消息到服务器
  void send(dynamic data) {
    if (_channel != null && _status == ConnectionStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  void _updateStatus(ConnectionStatus status) {
    _status = status;
    _connectionStatusController.add(status);
  }

  /// 释放资源
  void dispose() {
    disconnect();
    _connectionStatusController.close();
    _audioDataController.close();
    _errorController.close();
  }
}
