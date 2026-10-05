# Kazumi TV - Android TV 移植进度记录

## 项目概述

将 Kazumi TV Flutter 应用移植到 Android TV，使用 Predidit/media-kit fork 的新架构。

## 当前状态

### 分支与提交

- **分支**: `feature/android-tv`（远程）/ `master`（本地）
- **最新本地提交**: `8f49b22`（fix: correct KeyboardListener callback signature）
- **最新已推送提交**: `26d8194`（tag `tv-build-13`，已删除）
- **本地待推送提交**: `74db4bb`, `6a894e1`, `318005b`, `83158b3`, `40c34c2`, `96e62b9`, `a02517b`, `7b42848`, `cc606af`, `57e026c`, `6bfbcf3`, `acac506`, `7042ec3`, `189a5e1`, `5afccf8`, `cec2d45`, `f2c58bb`, `a6b46c0`, `144c4a6`, `1dfba9d`, `1933b82`, `4cba769`, `44c70ba`, `c46e224`, `f24e811`, `8f49b22`
- **本地剩余 tags**: `tv-build-15` 到 `tv-build-26`
- **已删除的远程 tags**: `tv-build-4` 到 `tv-build-14`（用户需手动删除）

### CI/CD

- **Workflow**: `.github/workflows/release.yaml` — 按 tag push 触发，构建 3 个 ABI（armeabi-v7a, arm64-v8a, x86_64）的独立 APK
- **Flutter 版本**: 3.47.6 stable（CI）
- **Gradle**: 8.14.5, AGP 8.11.1, Kotlin 2.2.21, Android SDK Platform 33
- **用户操作**: 用户手动推送 commit 和 tag，手动粘贴 CI 日志

## 已完成的功能

1. **TV 架构**: 使用 `flutter_modular` 7.1.1 新 API 构建 TV 版本
   - 所有 controller 使用 `.new` factory 注册（非 lazy）
   - 子模块: `tvPopularModule`, `tvTimelineModule`, `tvCollectModule`, `tvSearchModule`, `tvSettingsModule`, `tvInfoModule`, `tvPlayerModule`
   - 路由: `/developer` → `TVDeveloperPage`

2. **TV 焦点系统**:
   - `TvFocusScope`: 包裹 grid 项，处理键盘导航
   - `TVCard`: `Focus` + `GestureDetector(behavior: HitTestBehavior.opaque)`
   - `TVBangumiCard`: 两条 build 路径，focused 和 unfocused
   - `TvKeyHandler`: 处理 Enter/Select/Space 键
   - `TvHorizontalListItem`: 水平列表项，带 `GestureDetector`

3. **开发者菜单**:
   - `TVDeveloperPage`: 可导航到所有页面（popular, timeline, collect, search, settings, plugin list, info pages）
   - 使用 `_createTestBangumiItem` 创建测试 BangumiItem（14 个必填参数）
   - 使用 `Focus` + `onKeyEvent` 处理 Back 键

4. **BangumiItem 构造**:
   - 14 个必填参数: `id`, `type`, `name`, `nameCn`, `summary`, `airDate`, `airWeekday`, `rank`, `images`, `tags`, `alias`, `ratingScore`, `votes`, `votesCount`, `info`
   - 2 个可选参数: `metaTags`, `interest`

5. **D 键打开开发者菜单**:
   - 使用 `KeyboardListener`（替代已弃用的 `RawKeyboardListener`）
   - 回调签名: `void Function(KeyEvent)`
   - **注意**: `KeyboardListener` 的 `focusNode` 需要获得焦点才能接收事件

## 主要未解决问题

### 1. `Modular.to` 为 null（核心问题）

**现象**: 点击番剧卡片时，`Modular.to` 抛出 `Null check operator used on a null value`。

**已尝试的方案（全部失败）**:
- `scheduleMicrotask` after `runApp` → `tvNavigatorKey.currentState` 为 null
- `PostFrameCallback` in `TVMainPage.initState` → `tvNavigatorKey.currentState` 为 null
- `Future.delayed(200ms)` in `TVMainPage.initState` → `tvNavigatorKey.currentState` 为 null
- `Future.delayed(1000ms)` in `TVMainPage.initState` → `tvNavigatorKey.currentState` 为 null
- 重试机制（500ms x 10 attempts）→ `tvNavigatorKey.currentState` 始终为 null

**当前方案（commit `1933b82`）**:
```dart
// 在 TVMainPage.build 中
final navState = Navigator.of(context);
Modular.setNavigator(navState);
```

**分析**:
- `ModularApp` 创建了一个 `Navigator`（使用 `tvNavigatorKey`），但 `tvNavigatorKey.currentState` 始终为 null
- `MaterialApp` 在 `ModularApp` 内部创建了自己的 `Navigator`
- `Navigator.of(context)` 返回的是 `MaterialApp` 的 `Navigator`，不是 `ModularApp` 的 `Navigator`
- 需要确认 `Modular.to` 应该指向哪个 `Navigator`

**`Modular.to` 使用位置（8 处）**:
- `tv_timeline_page.dart:249`
- `tv_search_results.dart:126`
- `tv_plugin_list_page.dart:134`
- `tv_popular_page.dart:115`
- `tv_player_page.dart:401`
- `tv_info_page.dart:136`
- `tv_info_page.dart:232`
- `tv_collect_page.dart:107`

### 2. D 键打开开发者菜单

**现象**: 按 D 键无法打开开发者菜单。

**已尝试的方案**:
- `Focus` + `onKeyEvent` → 只在 focus 时接收事件
- `RawKeyboardListener` + `focusNode` → 需要 focus
- `RawKeyboardListener` 无 `focusNode` → 编译错误（`focusNode` 是必填参数）
- `KeyboardListener` + `focusNode` → 编译通过，但 `focusNode` 需要获得焦点

**当前方案（commit `8f49b22`）**:
```dart
return KeyboardListener(
  focusNode: _menuFocusNode,
  onKeyEvent: _handleDeveloperMenuKey,
  child: PopScope(...),
);
```

**问题**: `_menuFocusNode` 可能没有焦点，导致 D 键事件不被接收。

**可能的解决方案**:
- 使用 `Focus` + `autofocus: true` 确保 `_menuFocusNode` 获得焦点
- 使用 `FocusTraversalGroup` 确保 wrapper 有焦点
- 使用 `HardwareKeyboard` 全局监听（不需要 focus）

### 3. 鼠标点击不改变焦点（框选）

**现象**: 鼠标点击番剧卡片不改变焦点（框选）。

**已确认**:
- `TVBangumiCard` 的 `onTap` 被调用（logcat 确认）
- `_handleBangumiTap` 被触发（logcat 确认）
- `HitTestBehavior.opaque` 已设置
- `focusNode?.requestFocus()` 在 `onTap` 中调用

**可能原因**:
- `focusNode` 可能为 null（在 unfocused 分支中）
- 焦点系统可能有其他问题

### 4. 键盘 Enter/Select/Space 无法进入详情页

**现象**: 键盘 Enter/Select/Space 可以触发 `_handleBangumiTap`，但无法进入详情页。

**原因**: `Modular.to` 为 null（问题 1）

### 5. API 连接超时

**现象**: 所有 3 个 API 请求在 emulator 上超时（12s）

**可能原因**:
- Emulator 网络问题
- API 服务器问题

### 6. Search API 401

**现象**: `POST https://api.kazumi.fyi/v0/search/subjects` 返回 401

**可能原因**:
- 认证问题
- API 变更

### 7. 缺少"添加来源仓库"功能

**现象**: 原始 Kazumi 有插件/来源管理，TV 版本缺少

**位置**: `tv_plugin_list_page.dart:134` 使用 `Modular.to` — 可能是添加来源仓库功能的位置

## 关键文件

| 文件 | 说明 |
|------|------|
| `lib/main.dart` | 入口，`ModularApp` + `tvNavigatorKey` |
| `lib/tv/utils/modular_compat.dart` | `Modular` 兼容类（`setNavigator`, `to`, `get<T>()`） |
| `lib/tv/pages/main/tv_main_page.dart` | 主页面，`KeyboardListener` + `D` 键处理 |
| `lib/tv/tv_module.dart` | TV 模块注册（所有 controller + 子模块） |
| `lib/tv/pages/popular/tv_popular_page.dart` | 热门番剧页面 |
| `lib/tv/widgets/tv_bangumi_card.dart` | 番剧卡片（两条 build 路径） |
| `lib/tv/core/widgets/tv_card.dart` | TV 卡片组件 |
| `lib/tv/core/focus/tv_focus_scope.dart` | 焦点作用域 |
| `lib/tv/core/focus/tv_key_handler.dart` | 键盘处理器 |
| `lib/tv/pages/developer/tv_developer_page.dart` | 开发者菜单 |
| `lib/tv/pages/info/tv_info_page.dart` | 番剧详情页 |
| `android/app/build.gradle` | Android 构建配置（`namespace "com.predidit.kazumi"`） |
| `android/app/src/main/AndroidManifest.xml` | Activity: `com.example.kazumi.MainActivity` |

## 关键约束

- **`addSingleton` 不是 lazy**: factory 在 `ModularApp` bootstrap 时调用
- **`inject<T>()` 在 singleton factory 内失败**: 使用 `.new` factory 代替
- **`c.module(otherModule)` 是位置参数**: 不是命名参数
- **`KeyDownEvent` 在 `package:flutter/services.dart`**: 不在 `material.dart`
- **`KeyEventResult` 在 `package:flutter/widgets/focus_manager.dart`**
- **Android package name**: `com.predidit.kazumi`（从 `build.gradle` namespace）
- **Android activity name**: `com.example.kazumi.MainActivity`（NOT `com.predidit.kazumi.MainActivity`）
- **Emulator ABI**: `x86_64`
- **`MediaKit.ensureInitialized()` 是 void**: 不是 Future
- **Dart build hook** 自动下载平台二进制（mpv, FFmpeg）
- **`PluginSearchStatus`** enum: `{ pending, success, error, noResult, captcha }`
- **`aspectRatioTypeMap`** top-level const: `{ 0: '自动', 1: '16:9', 2: '4:3', 3: '1:1' }`

## 用户操作指南

1. **推送 commit**:
   ```bash
   cd kazumi-tv-feature-android-tv
   git push origin master
   ```

2. **创建 tag 并推送**:
   ```bash
   git tag tv-build-XX
   git push origin tv-build-XX
   ```

3. **删除远程 tag**（用户需手动）:
   ```bash
   git push origin :tv-build-4 :tv-build-5 :tv-build-6 :tv-build-7 :tv-build-8 :tv-build-9 :tv-build-10 :tv-build-11 :tv-build-12 :tv-build-13 :tv-build-14
   ```

4. **安装 APK**:
   ```bash
   adb uninstall com.predidit.kazumi
   adb install path/to/apk
   ```

5. **启动应用**:
   ```bash
   adb shell am start -n com.predidit.kazumi/com.example.kazumi.MainActivity
   ```

6. **查看 logcat**:
   ```bash
   adb logcat -d | grep "TV:"
   ```

## 下一步优先级

1. **解决 `Modular.to` 为 null 的问题**（最高优先级）
   - 确认 `Modular.to` 应该指向哪个 `Navigator`
   - 可能需要重新设计导航架构

2. **解决 D 键打开开发者菜单的问题**
   - 确保 `_menuFocusNode` 获得焦点
   - 或使用全局键盘监听

3. **验证鼠标点击改变焦点**
   - 检查 `focusNode` 是否正确传递

4. **验证键盘 Enter/Select/Space 进入详情页**
   - 依赖问题 1 解决

5. **API 连接问题**
   - 检查 emulator 网络

6. **添加"来源仓库"功能**
   - 参考原始 Kazumi 实现
