// ============================================================================
// preview_home.dart —— Flutter Widget Preview 专用入口
// ----------------------------------------------------------------------------
// 为什么需要这个文件？
//   Android Studio 的 "Flutter Widget Preview" 面板需要一个能独立渲染的
//   入口。而真正的首页 HomeScreen 依赖 Provider 仓库里的
//   ConnectionProvider（见 home_screen.dart 的 Consumer），
//   直接预览会因"找不到 Provider"而失败。
//   本文件把 Provider 包裹补上，并打上 @Preview 标签，
//   预览面板就能在画廊里找到并渲染它。
//
//   这个文件只服务于预览工具，不影响正式运行（main.dart 才是入口）。
//
// 初学者要不要管它？—— 不用。它不参与正式 App 的编译产物，改首页 UI 时
// 也不需要动这里；只有当你在 Android Studio 右侧打开 Flutter Widget
// Preview 面板、想可视化预览首页时才和它打交道。若将来 HomeScreen 新增
// 了 Provider 依赖、预览报"找不到 Provider"，来这个文件的 providers
// 列表里补同款注册即可（与 main.dart 保持一致）。
// ============================================================================

import 'package:flutter/material.dart';
// @Preview 注解由 Flutter 3.32+ 的 widget_previews 库提供
import 'package:flutter/widget_previews.dart';
import 'package:provider/provider.dart';

import 'providers/connection_provider.dart';
import 'screens/home_screen.dart';
import 'services/audio_service.dart';
import 'services/network_service.dart';

/// 预览锚点函数：加 @Preview 注解后，Widget Preview 面板
/// 会自动扫描并收录这个函数返回的界面。
/// 函数体复用与 main.dart 相同的多 Provider 包裹结构，
/// 让 HomeScreen 在预览环境里也能拿到它依赖的服务。
@Preview(name: 'Home 未连接')
Widget homePreview() => MultiProvider(
      providers: [
        Provider<NetworkService>(create: (_) => NetworkService()),
        Provider<AudioService>(create: (_) => AudioService()),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (context) => ConnectionProvider(
            networkService: context.read<NetworkService>(),
            audioService: context.read<AudioService>(),
          ),
        ),
      ],
      // 预览时套一层 MaterialApp，提供主题和方向等运行环境
      child: const MaterialApp(home: HomeScreen()),
    );

/// 兜底入口：如果预览面板选择"直接运行本文件"，也能正常启动。
void main() => runApp(homePreview());
