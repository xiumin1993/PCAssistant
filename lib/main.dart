import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'providers/connection_provider.dart';
import 'services/audio_service.dart';
import 'services/network_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    MultiProvider(
      providers: [
        // 网络服务 - 管理 WebSocket 连接
        Provider<NetworkService>(
          create: (_) => NetworkService(),
          dispose: (_, service) => service.dispose(),
        ),
        // 音频服务 - 管理音频播放
        Provider<AudioService>(
          create: (_) => AudioService(),
          dispose: (_, service) => service.dispose(),
        ),
        // 连接状态管理
        ChangeNotifierProvider<ConnectionProvider>(
          create: (context) => ConnectionProvider(
            networkService: context.read<NetworkService>(),
            audioService: context.read<AudioService>(),
          ),
        ),
      ],
      child: const PCSpeakerApp(),
    ),
  );
}
