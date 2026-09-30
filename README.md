# PC Assistant（手机端 App）

Flutter 应用，让手机成为 Windows 电脑的**外放音箱**、**麦克风**、**网络摄像头**。配合电脑端 [AudioServer](https://github.com/xiumin1993/AudioServer) 使用，全走局域网 WebSocket 实时传输。

三种模式（可同时按需启用）：

| 模式 | 数据方向 | 手机硬件 | 电脑侧出口 |
|------|----------|----------|-----------|
| 音箱 | 电脑系统声音 → 手机扬声器 | 播放 | 无需驱动 |
| 麦克风 | 手机话筒 → 电脑 | 录音（按需开） | VB-CABLE `CABLE Output` |
| 摄像头 | 手机相机 → 电脑 | 相机（按需开） | Unity Video Capture / OBS Virtual Camera |

**隐私模型**：相机/麦克风硬件默认彻底关闭，只有电脑端真的有应用在用的瞬间才开启（服务器通过驱动握手事件实时检测并推送状态）；手机红条 REC = 硬件真实开启中；一键冻结/强停双端生效。

---

## 1. 前置条件

### 编译 Android 版
1. Windows / macOS / Linux 任一；
2. [Flutter SDK](https://docs.flutter.cn/get-started/install) ≥ 3.35（国内建议配镜像环境变量 `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`）；
3. Android SDK（Android Studio 自带即可）+ JDK 17；
4. 手机开启"开发者选项 → USB 调试"（或无线调试 `adb connect 手机IP:5555`）。

### 编译 iOS 版（需 macOS）
1. macOS + Xcode 15+（App Store 安装）+ CocoaPods（`brew install cocoapods`）；
2. Flutter SDK（同上）；
3. iPhone 开"开发者模式"，数据线连 Mac 信任本机；
4. Apple ID（免费个人签名可真机调试 7 天；上架需开发者账号）。

### 运行时
- 手机与电脑同一局域网（建议 5GHz WiFi），或 USB 线 + `adb reverse`（见 §4）；
- 电脑端 AudioServer 已运行（驱动安装步骤见 AudioServer 仓库 README）。

## 2. 编译与安装

```bash
git clone git@github.com:xiumin1993/PCAssistant.git
cd PCAssistant
flutter pub get
```

### Android（推荐命令，arm64 + 调试符号分离，约 16.5MB）
```bash
flutter build apk --release --target-platform android-arm64 --split-debug-info=build/symbols
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
老机型（ armeabi-v7a）把 `android-arm64` 换成 `android-arm`；或去掉 `--target-platform` 出通用包（体积翻倍）。

### iOS（在 Mac 上）
```bash
cd ios && pod install && cd ..          # 首次需要
flutter build ios --release --no-codesign   # 先验证能编过
# 真机运行（Xcode 里选你的签名 Team 后）：
open ios/Runner.xcworkspace             # Xcode → 选 Team → 设备 → Run
# 或命令行：
flutter run --release                   # 需要已配置签名
```
> 原生层全部在 `ios/Runner/AppDelegate.swift`（无第三方 Swift 包），通道契约与 Android 完全一致，Dart 层零改动。
> **iOS 系统限制**：相机不允许后台采集——App 退后台/息屏时摄像头流暂停（回前台自动恢复）；麦克风+播放靠 `UIBackgroundModes=audio` 可持续后台工作。

> **iPhone + Windows 电脑端（推荐的跨平台组合）**：电脑端服务器**零改动**直接复用，三大功能全通。差异仅两点：① USB 有线模式不可用（`adb reverse` 是安卓专属），请走 WiFi；② 相机须停留在取景页亮屏使用。首页返回键在 iPhone 上无动作属正常（苹果禁止 App 自行回桌面，用系统上滑手势即可，麦克风后台不受影响）。

## 3. 使用流程

1. 电脑运行 AudioServer（默认监听 8080）；
2. 手机 App 首页填 `电脑IP:8080` → 点"连接"（IP 在电脑上 `ipconfig` 查 IPv4）；
3. **音箱**：连接后自动播放电脑声音；
4. **麦克风**：首页开"麦克风守护"→ 会议软件把输入设备选 `CABLE Output`，说话即自动开麦，说完 1 秒内自动关硬件；详情页可切 48k（直通）/44.1k（电脑重采样）；
5. **摄像头**：开"摄像头守护"→ 任意软件选 "Unity Video Capture"（浏览器选 "OBS Virtual Camera"）→ 手机收到"同意/忽略"确认 → 取景中；摄像头页可切换前后置、手动旋转 90°、下拉框选清晰度（列表=你手机真实能力）、点全屏获得视频播放器式全屏；
6. 任何时刻：手机"冻结/停止"或电脑 GUI"Force Stop"双端立即关闭硬件。

## 4. USB 有线模式（延迟最低）

数据线连接后在电脑执行：
```bash
adb reverse tcp:8080 tcp:8080
```
App 首页点"USB 有线直连"（自动填 `127.0.0.1:8080`）→ 连接。不占 WiFi、不受无线波动影响。
注意：`adb reverse` 依赖真实 USB 连接，无线 adb 下不可用。

## 5. 常见问题

| 症状 | 解法 |
|------|------|
| 连不上 | 同网段？防火墙放行 8080？电脑 IP 变了（路由器绑静态 DHCP） |
| 息屏掉线 | 开守护开关（常驻通知保活）+ 系统设置里对本 App 关闭电池优化（各品牌路径不同，一般"设置→电池→应用省电策略→无限制"） |
| 画面方向不对 | 全屏/横持会自动跟随；仍有偏差用"旋转90°"按钮微调 |
| 清晰度想换 | 摄像头页"清晰度"下拉框；"自动"= 手机能力清单里的最高档（≤1280×720@30） |
| iOS 编译报错 pod | 在 `ios/` 目录 `pod repo update` 后重跑 `pod install` |
| iOS 真机跑不起来 | Xcode 签名 Team 没选；或 iPhone 未信任本机/未开开发者模式 |

## 6. 项目结构（关键文件）

```
lib/main.dart                    Provider 装配入口
lib/screens/home_screen.dart     首页（连接/守护开关/USB 快捷键）
lib/screens/mic_screen.dart      麦克风页（电平/静音/采样率）
lib/screens/camera_screen.dart   摄像头页（取景/切镜头/旋转/清晰度/全屏）
lib/providers/                   状态机层（idle→standby→live 按需模型）
lib/services/                    MethodChannel/EventChannel + WebSocket 封装
android/app/.../MainActivity.kt  Android 原生：AudioTrack/AudioRecord/服务
android/app/.../CameraEngine.kt  Android 原生：Camera2→NV21→旋转→JPEG
ios/Runner/AppDelegate.swift     iOS 原生层（与 Android 契约 1:1）
design/                          UI 设计稿（HTML）
```

协议：文本 JSON 控制帧 + 二进制媒体帧；麦克风 PCM 无标记直传，摄像头 JPEG 带 4 字节魔术头 `[0x03,'C','A','M']`。

## 7. 界面语言（国际化，v3.7）

方案：**Flutter 官方 gen-l10n + ARB**（不引第三方包，跟 Flutter 版本一起升级）。
默认**跟随系统**：手机系统语言是中文进简体，其余一律英文。

- 文案表：`lib/l10n/app_en.arb` + `lib/l10n/app_zh.arb`（两份键必须一一对应）
- 配置：`l10n.yaml`；`pubspec.yaml` 里 `flutter: generate: true` + `flutter_localizations`
- 生成物：`lib/l10n/app_localizations*.dart`（由 `flutter gen-l10n` 生成，改完 arb 必须重跑）
- 入口：首页右上角  图标 → 语言弹层（跟随系统 / English / 简体中文），选择记在本地，
  实时生效，不用重启

**改动代码时要守的三条规则**（这是本版踩坑后定下的分工）：

1. 逻辑层（provider / service）**不存句子，只存"错误键 + 原始细节"**。
   例：`NetErrorEvent(kind, detail)`、`_errorKey/_errorDetail`。
2. 需要翻译成文案的方法一律以 `Of(l10n)` 结尾 —— `statusLabelOf(l10n)`、`errorOf(l10n)`、
   `gateHeadlineOf(l10n, device)`。看到 `Of` 就知道"这一步要拿文案表"。
3. 界面文件里不写硬编码中英文，全部走 `AppLocalizations.of(context)`；
   `const` 组件因为要插变量得去掉 `const`（这是转换时最常见的编译错误）。

原生层（Flutter 的 l10n 管不到的三处系统文案）：

| 位置 | 文件 | 说明 |
|------|------|------|
| 安卓通知栏（麦克风/摄像头待命）+ 桌面应用名 | `android/app/src/main/res/values/strings.xml`（英文默认）、`values-zh/strings.xml`（中文） | App 内切语言时通过 `com.pcspeaker/audio` 通道的 `setLocale` 同步给 `AppLocale.kt`，写进 SharedPreferences；`MainActivity.refreshGuardNotifications()` 随即把**正在挂着的那条常驻通知原地重发**一遍（服务已在跑时 `startService` 只回调 `onStartCommand`，`startForeground` 同 id 即"更新这条通知"，不影响录音/相机状态机），所以换语言**不需要断开重连**。已知限制：**通知渠道名**在渠道创建那刻被系统记住，换语言只改标题正文，渠道名要重装 App 才更新（安卓硬规则，删了的渠道名不能再建） |
| iOS 权限弹窗文案 | `ios/Runner/Info.plist` 的两条 `...UsageDescription` | 本版是**双语一行**写法。正式做法是拆成 `en.lproj / zh-Hans.lproj` 的 `InfoPlist.strings`，那需要在 Xcode 工程里建 variant group（改 `project.pbxproj`）；本仓库无 Mac/Xcode 无法验证，留待 Mac 侧再拆 |

**"系统语言"那一行说的是系统，不是用户的选择。** 语言弹层里"跟随系统"下面的小提示，
取的是 `LanguageProvider.systemCode`（只看设备语言），**不是** `effectiveCode`
（界面当前真正用的语言）。两者混用会写出"用户手动选了英文 → 提示却说
`System language detected: English`"这种谎话：手机明明是中文系统。
`_systemLocale` 之所以可信：安卓侧只在**构造通知**时用了 `localized()` 包装的 Context，
并没有重写 Activity 的 `attachBaseContext`，Flutter 拿到的仍是设备真实语言。

**不翻译的东西**（全球通用，两种语言写法完全一致）：WiFi / USB / IP / WebSocket /
PCM / Hz / kHz / kbps / fps / ms / kB / MB、数字与分辨率（`1280×720 @ 30fps`）、
品牌名 "PC Assistant / AudioServer"、以及语言名本身
（"简体中文"永远写作"简体中文"、"English"永远写作 "English" —— 全球软件通行惯例，
用户只有用自己的母语才认得出自己的语言）。

加第三种语言：复制 `app_en.arb` 为 `app_ja.arb` 逐条翻译，把 `supportedLocales` 加一档，
`LanguageProvider._resolveFromSystem()` 补一个分支，原生侧加 `values-ja/strings.xml`。
