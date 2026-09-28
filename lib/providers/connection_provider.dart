import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_service.dart';
import '../services/network_service.dart';

/// 连接状态管理
class ConnectionProvider extends ChangeNotifier {
  final NetworkService _networkService;
  final AudioService _audioService;

  StreamSubscription? _statusSubscription;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _errorSubscription;

  String _serverAddress = '';
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  String? _errorMessage;
  bool _isLoading = false;

  final TextEditingController _serverAddressController = TextEditingController();

  ConnectionProvider({
    required NetworkService networkService,
    required AudioService audioService,
  })  : _networkService = networkService,
        _audioService = audioService {
    _init();
    _setupListeners();
  }

  Future<void> _init() async {
    // 加载保存的服务器地址
    final prefs = await SharedPreferences.getInstance();
    _serverAddress = prefs.getString('server_address') ?? '';
    _serverAddressController.text = _serverAddress;
    notifyListeners();
  }

  void _setupListeners() {
    // 监听连接状态
    _statusSubscription = _networkService.connectionStatusStream.listen((status) {
      _connectionStatus = status;
      _isLoading = status == ConnectionStatus.connecting;

      if (status == ConnectionStatus.connected) {
        _audioService.startStreaming();
      } else if (status == ConnectionStatus.disconnected) {
        _audioService.stopStreaming();
      }

      notifyListeners();
    });

    // 监听音频数据
    _audioSubscription = _networkService.audioDataStream.listen((data) {
      _audioService.receiveAudioData(data);
    });

    // 监听错误
    _errorSubscription = _networkService.errorStream.listen((error) {
      _errorMessage = error;
      notifyListeners();
    });
  }

  // Getters
  bool get isConnected => _connectionStatus == ConnectionStatus.connected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  TextEditingController get serverAddressController => _serverAddressController;

  String get connectionStatus {
    switch (_connectionStatus) {
      case ConnectionStatus.disconnected:
        return '点击连接按钮开始';
      case ConnectionStatus.connecting:
        return '正在连接...';
      case ConnectionStatus.connected:
        return '正在接收音频流';
      case ConnectionStatus.error:
        return _errorMessage ?? '连接错误';
    }
  }

  /// 切换连接状态
  Future<void> toggleConnection() async {
    _errorMessage = null;

    if (_networkService.isConnected) {
      await _networkService.disconnect();
    } else {
      final address = _serverAddressController.text.trim();
      if (address.isEmpty) {
        _errorMessage = '请输入服务器地址';
        notifyListeners();
        return;
      }

      // 保存服务器地址
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_address', address);
      _serverAddress = address;

      await _networkService.connect(address);
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _audioSubscription?.cancel();
    _errorSubscription?.cancel();
    _serverAddressController.dispose();
    super.dispose();
  }
}
