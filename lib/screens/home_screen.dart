// ============================================================================
// home_screen.dart —— 首页界面（用户看到的唯一页面）
// ----------------------------------------------------------------------------
// 本文件只负责"画界面"：把 ConnectionProvider 里的状态显示出来，
// 把用户的点击交还给 Provider 处理。界面本身不含任何业务逻辑，
// 这是 Flutter 开发的基本分工：Widget 管显示，Provider 管思考。
//
// Flutter 画界面的基本思路：一切皆 Widget，界面 = 层层嵌套的 Widget 树。
// 阅读嵌套结构的技巧：从最外层往里剥 ——
//   Scaffold（页面骨架）
//     ├─ AppBar（顶部标题栏）
//     └─ body（页面主体）
//         └─ Consumer（数据订阅器：Provider 一变就重建里面的内容）
//             └─ Center（把内容居中）
//                 └─ Padding（四周留白）
//                     └─ Column（垂直排列一组组件：图标/文字/输入框/按钮）
// ============================================================================

import 'package:flutter/material.dart';   // UI 组件库
import 'package:provider/provider.dart';  // Consumer 数据订阅

// 导入状态管理器（界面与逻辑之间的桥梁）
import '../providers/connection_provider.dart';

/// 首页。
/// 用 StatelessWidget 就够：所有会变的都住在 Provider 里，
/// 本 Widget 只负责"根据 Provider 当前状态生成界面"。
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Scaffold：页面"脚手架"，提供 Material 页面的标准结构——
    // 顶部栏(appBar)、主体(body)、底部栏、浮动按钮等插槽。
    return Scaffold(
      // ---------------- 顶部标题栏 ----------------
      appBar: AppBar(
        title: const Text('PC Speaker'), // App 名称
        centerTitle: true,               // 标题居中（默认靠左，iOS 风格差异）
      ),

      // ---------------- 页面主体 ----------------
      // Consumer<ConnectionProvider>：核心！
      // 它做两件事：
      //   1. 从 Provider 仓库中取出 ConnectionProvider 实例；
      //   2. 订阅它的变化 —— 每当逻辑层调用 notifyListeners()，
      //      Consumer 就重新执行下面的 builder，界面自动刷新。
      // 也就是说：这个 builder 会被反复调用很多次（每次状态变化一次），
      // 每次都用"当时最新的数据"重新生成界面。
      body: Consumer<ConnectionProvider>(
        // builder 是构建回调：
        //   context —— 当前构建上下文（Widget 在树中的位置）
        //   provider —— 取到的 ConnectionProvider 实例（后面直接用
        //                provider.xxx 读状态，见下方）
        //   child —— 可选的"缓存子树"，这里没用到（不传即为 null）
        builder: (context, provider, child) {
          // Center：把唯一子节点在主轴/交叉轴上都居中
          return Center(
            // Padding：给内容四周加 24 逻辑像素的留白，
            // 避免贴着屏幕边缘。const 让"边距对象"复用，省性能
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              // Column：垂直方向排列children。
              // mainAxisAlignment 控制"主轴(纵向)对齐"——
              //   center = 整组内容在可用空间里垂直居中。
              // children 是 Widget 列表，从上到下依次排。
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ==========================================================
                  // ① 连接状态大图标（喇叭）
                  // ==========================================================
                  // 三元表达式做"状态 → 资源"的映射：
                  //   已连接：实心喇叭 + 主题主色（蓝）
                  //   未连接：空心喇叭 + 灰色描边色
                  // Icons.xxx 是 Flutter 内置的 Material 图标常量库。
                  Icon(
                    provider.isConnected
                        ? Icons.speaker_phone
                        : Icons.speaker_phone_outlined,
                    size: 120, // 字号/尺寸单位是逻辑像素（自动适配屏幕密度）
                    // Theme.of(context)：沿 Widget 树向上找到
                    // MaterialApp 配置的主题对象。
                    // colorScheme：主题配色方案，primary=主色，
                    // outline=次要描边灰。用主题色而非写死颜色，
                    // 亮/暗模式自动切换才不用改这里。
                    color: provider.isConnected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),

                  // SizedBox：占位/间隔组件，制造垂直方向 32 像素的空隙。
                  // Flutter 布局靠组件本身撑开，没有 CSS 的 margin 概念
                  const SizedBox(height: 32),

                  // ==========================================================
                  // ② 主状态文字（大字："已连接" / "未连接"）
                  // ==========================================================
                  Text(
                    provider.isConnected ? '已连接' : '未连接',
                    // textTheme 是主题的"文字样式表"：headlineMedium =
                    // 页面级大标题样式（字号、字重、行高都成套）。
                    // ?. 是因为样式字段可空；copyWith 只覆盖颜色，
                    // 其余字号等属性保持主题原样 —— 局部定制的规范做法。
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: provider.isConnected
                              ? Theme.of(context).colorScheme.primary
                              : null, // null = 不改，用主题默认色
                        ),
                  ),
                  const SizedBox(height: 8),

                  // 副标题：显示更细的状态文案，
                  // 比如"正在连接..." / "正在接收音频流"。
                  // provider.connectionStatus 是 Provider 里的
                  // switch 枚举翻译好的中文，界面拿现成的用。
                  Text(
                    provider.connectionStatus,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline, // 弱化次要信息
                        ),
                    textAlign: TextAlign.center, // 文字过长换行时保持居中
                  ),
                  const SizedBox(height: 48),

                  // ==========================================================
                  // ③ 服务器地址输入框
                  // ==========================================================
                  // SizedBox 固定宽度 300：大屏上 TextField 会被拉到
                  // 全宽，限宽后视觉更聚焦。
                  SizedBox(
                    width: 300,
                    child: TextField(
                      // controller 连接 Provider 持有的文本控制器：
                      //   用户每敲一个字 → 自动存进 controller.text；
                      //   Provider 启动时回填的历史地址 → 立刻显示。
                      // 界面不需要自己管理"输入了什么"。
                      controller: provider.serverAddressController,
                      // InputDecoration：输入框的外观配置（Material 规范）
                      decoration: const InputDecoration(
                        labelText: '电脑服务器地址',       // 悬浮标签
                        hintText: '例如: 192.168.1.100:8080', // 占位提示
                        prefixIcon: Icon(Icons.computer),   // 左侧图标
                        // 带圆角边框的样式（默认是下划线样式）
                        border: OutlineInputBorder(),
                      ),
                      // 已连接时禁止编辑地址（防止改了一半误导）。
                      // enabled=false 会让输入框自动变灰，无需额外样式。
                      enabled: !provider.isConnected,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ==========================================================
                  // ④ 连接 / 断开 按钮
                  // ==========================================================
                  // SizedBox 固定按钮尺寸 200x50，让点击区域够大、
                  // 视觉稳定（文字变化不会把按钮撑大缩小）。
                  SizedBox(
                    width: 200,
                    height: 50,
                    // FilledButton.icon：Material 3 的实心按钮 + 图标+文字。
                    child: FilledButton.icon(
                      // onPressed 是点击回调。
                      // 传 null 是 Flutter 的"禁用按钮"协议：
                      // 只要 onPressed == null，按钮自动置灰且不可点。
                      // 连接过程中（isLoading）就该禁用，防重复提交。
                      onPressed: provider.isLoading
                          ? null
                          : () => provider.toggleConnection(),
                      // 箭头函数 () => xxx 等价于 () { return xxx; }
                      // 这里点击后调用 Provider 的切换方法，
                      // 界面不做任何判断，逻辑全部在 Provider。

                      // 按钮图标：三态
                      //   加载中 → 转圈进度条（小尺寸 CircularProgressIndicator）
                      //   已连接 → "断链"图标
                      //   未连接 → "链接"图标
                      icon: provider.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,     // 圆环线宽
                                color: Colors.white, // 在蓝色按钮上保持白色
                              ),
                            )
                          : Icon(
                              provider.isConnected
                                  ? Icons.link_off
                                  : Icons.link,
                            ),
                      // 按钮文字同样跟随状态
                      label: Text(
                        provider.isConnected ? '断开连接' : '连接',
                      ),
                    ),
                  ),

                  // ==========================================================
                  // ⑤ 错误提示（仅出错时出现）
                  // ==========================================================
                  // if (...) ...[ ... ] 是 Flutter 列表里的标准写法：
                  //   if 条件成立 → 把 ...[ ] 里的组件们展开塞进 children；
                  //   不成立 → 什么都不加。
                  // 替代了"隐藏组件"的思路：不显示就根本不存在，
                  // 不会占位，也不需要 Visibility。
                  if (provider.errorMessage != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      // errorMessage! 的 !：上面已判过非空，
                      // 这里"断言不可能为 null"，让编译器闭嘴
                      provider.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error, // 主题错误色（红）
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
