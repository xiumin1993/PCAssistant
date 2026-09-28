import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PC Speaker'),
        centerTitle: true,
      ),
      body: Consumer<ConnectionProvider>(
        builder: (context, provider, child) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 连接状态图标
                  Icon(
                    provider.isConnected
                        ? Icons.speaker_phone
                        : Icons.speaker_phone_outlined,
                    size: 120,
                    color: provider.isConnected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 32),

                  // 连接状态文字
                  Text(
                    provider.isConnected ? '已连接' : '未连接',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: provider.isConnected
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    provider.connectionStatus,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),

                  // 服务器地址输入
                  SizedBox(
                    width: 300,
                    child: TextField(
                      controller: provider.serverAddressController,
                      decoration: const InputDecoration(
                        labelText: '电脑服务器地址',
                        hintText: '例如: 192.168.1.100:8080',
                        prefixIcon: Icon(Icons.computer),
                        border: OutlineInputBorder(),
                      ),
                      enabled: !provider.isConnected,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 连接/断开按钮
                  SizedBox(
                    width: 200,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: provider.isLoading
                          ? null
                          : () => provider.toggleConnection(),
                      icon: provider.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              provider.isConnected
                                  ? Icons.link_off
                                  : Icons.link,
                            ),
                      label: Text(
                        provider.isConnected ? '断开连接' : '连接',
                      ),
                    ),
                  ),

                  // 错误信息
                  if (provider.errorMessage != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      provider.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
