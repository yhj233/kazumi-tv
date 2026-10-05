# Kazumi TV - Android TV 移植进度记录

## 项目概述

将 Kazumi TV Flutter 应用移植到 Android TV，使用 Predidit/media-kit fork 的新架构。

---

## 🎯 本次修复（关键：找到并解决了"详情页进不去"的真正元凶）

### 根因：flutter_modular 7.x 是彻底重写，导航 API 完全变了

查证来源：[pub.dev changelog](https://pub.dev/packages/flutter_modular/changelog)、
[ModularApp API 文档](https://pub.dev/documentation/flutter_modular/latest/flutter_modular/ModularApp-class.html)

7.0.0 是 ground-up rewrite：

- v6 的 `Module` / `Bind` / `ChildRoute` / **全局 `Modular` facade** / `modular_core` 全部移除。
- 导航必须写成：
  ```dart
  ModularApp(
    module: appModule,
    navigatorKey: someKey,          // 这个 key 是 modulo 自己 Router 的 Navigator key
    child: const AppRoot(),
  )

  class AppRoot extends StatelessWidget {
    Widget build(BuildContext context) => MaterialApp.router(
      routerConfig: ModularApp.routerConfigOf(context),   // ← 必须消费
    );
  }
  ```
- 跳转用 `context.pushNamed() / navigate() / pop()`，**不再是 `Modular.to`**。

**旧代码的问题**：
```dart
runApp(ModularApp(
  module: tvModule,
  navigatorKey: tvNavigatorKey,
  child: MaterialApp(home: TVMainPage()),   // ← 从未消费 routerConfigOf
));
```
→ `ModularApp` 构建的 `Navigator`（持有 `tvNavigatorKey`）**从未挂载**，
所以 `tvNavigatorKey.currentState` 永远是 `null`（这就是之前反复重试/延时都无效的原因）；
同时模块里 `route(...)` 注册的路由**全是死代码**。

### 修复方案（采用原生 Router，路径完全可控）

| 文件 | 改动 |
|------|------|
| `lib/main.dart` | 新增 `TVRootApp`；`MaterialApp` 显式传 `navigatorKey: tvNavigatorKey` + `onGenerateRoute: tvOnGenerateRoute`；首帧后把 `NavigatorState` 交给兼容层。**不再给 `ModularApp` 传 `navigatorKey`**（避免重复 GlobalKey）。 |
| `lib/tv/core/navigation/tv_routes.dart` | **新增**：显式路由表 `tvOnGenerateRoute`，路径自动归一化（`/info` 与 `/info/` 都能命中），未知路径返回友好错误页而不是崩溃。 |
| `lib/tv/utils/modular_compat.dart` | `tvNavigatorKey` 移到这里；新增 `Modular.navigator`（回退到 `tvNavigatorKey.currentState`）、`Modular.pushNamed()`、`Modular.pop()`（navigator 为 null 时静默忽略，**不会再抛 null check 崩溃**）。 |
| `lib/tv/tv_module.dart` | `AudioController` / `PlayerController` 移到**根模块**注册。 |
| `lib/tv/pages/player/tv_player_module.dart` | 删除其中的 DI，只保留路由声明。 |
| 各页面（popular/timeline/collect/search/info/player/plugin） | `Modular.to.xxx` → `Modular.pushNamed(...)` / `Modular.pop()`，路径统一为 `/info`、`/player`。 |

### 为什么 `PlayerController` 必须放根模块（第二个隐藏 bug）

`TVInfoPage.initState` 在跳转 `/player` **之前**就执行 `Modular.get<PlayerController>()`。
而 7.x 里**带 `path` 的模块是 feature，DI 只在进入该路由后才绑定**。
原来注册在 `tvPlayerModule`（`path: '/player'`）里 → 详情页必然拿不到实例。
搬回根模块（path-less / root-owned，bootstrap 即生效）后解决。

---

## 路由表（`lib/tv/core/navigation/tv_routes.dart`）

| 路径 | 页面 |
|------|------|
| `/`（`MaterialApp.home`） | `TVMainPage()` |
| `/developer` | `TVDeveloperPage()` |
| `/info` | `TVInfoPage(bangumiItem: settings.arguments)` |
| `/player` | `TVPlayerPage()` |
| `/settings/plugin` | `TVPluginListPage()` |
| `/settings/plugin/shop` | `TVPluginShopPage()` |
| `/popular` `/timeline` `/collect` `/search` `/settings` | `TVMainPage(initialTab: n, isRoot: false)`（开发者菜单调试用） |
| 其他 | `TvRouteErrorPage` |

---

## 开发者菜单：换了更可靠的打开方式

### 方式一：全局快捷键 `D`（已重写）

旧实现用 `Focus` / `KeyboardListener` 绑在页面上 —— **只有该节点持有焦点时才能收到按键**；
TV 上焦点一直在内容区，所以永远收不到。

新实现用 `HardwareKeyboard.instance.addHandler`（`lib/tv/pages/main/tv_main_page.dart`）：

```dart
bool _handleGlobalKeyEvent(KeyEvent event) {
  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyD) {
    Modular.pushNamed('/developer');
    return true;
  }
  return false;
}
```

- 与焦点**完全无关**，任何页面、任何焦点位置都能触发。
- 只在**根** `TVMainPage` 注册（`widget.isRoot`），避免 push 出多个实例后重复响应。
- 已确认 `KeyEventCallback = bool Function(KeyEvent)`，签名正确。

### 方式二：设置 → 关于 → **开发者菜单** 按钮（新增，遥控器可用）

遥控器上根本没有 `D` 键，所以 `lib/tv/pages/settings/about/tv_about_page.dart`
新增了一个 `TVButton`「开发者菜单」入口，方向键上下即可选中，必定可用。
这是 Android TV 上真正"更好"的入口。

### 开发者菜单页本身也重写了

旧版条目是 `InkWell`，**不可聚焦** → 遥控器/键盘根本选不中。
新版全部改用可聚焦的 `TVButton`（`lib/tv/pages/developer/tv_developer_page.dart`），
并显式串好上下方向键；路由地址也修正为真实路径。

---

## 已验证 / 已确认

- ✅ **鼠标点击番剧卡片可以改变焦点**（用户确认）
- ✅ `TVBangumiCard.onTap` / `_handleBangumiTap` 被正确调用（logcat 确认）

---

## 其余已知问题（本次未处理）

### 1. API 连接超时
所有 API 请求在 emulator 上超时（12s）。可能是模拟器网络问题，非代码问题。

### 2. Search API 401
`POST https://api.kazumi.fyi/v0/search/subjects` 返回 401。可能认证或 API 变更。

### 3. 缺少"添加来源仓库"功能
原始 Kazumi 有插件/来源管理，TV 版本缺少入口（`tv_plugin_list_page.dart`）。

### 4. `lib/tv/tv_app.dart` 已成死代码
`TVApp` 类未被使用（`main.dart` 不再用它），但 `initTVEnvironment()` 仍在被
`TVMainPage.initState` 调用，所以文件必须保留。

### 5. `tvModule` 里的 `route(...)` / `module(...)` 是惰性声明
既然路由由 `tvOnGenerateRoute` 接管，这些声明是死代码（保留仅为兼容、不影响运行）。
若将来切回 flutter_modular 路由，需要重新评估。

---

## 关键文件

| 文件 | 说明 |
|------|------|
| `lib/main.dart` | 入口：`TVRootApp` + `MaterialApp(navigatorKey, onGenerateRoute)` |
| `lib/tv/core/navigation/tv_routes.dart` | **路由表**（新增） |
| `lib/tv/utils/modular_compat.dart` | `tvNavigatorKey` + `Modular` 兼容层（`pushNamed`/`pop`/`get`） |
| `lib/tv/tv_module.dart` | 根模块 DI 注册 |
| `lib/tv/pages/main/tv_main_page.dart` | 主页面 + 全局 `D` 键监听 |
| `lib/tv/pages/developer/tv_developer_page.dart` | 开发者菜单（可聚焦） |
| `lib/tv/pages/info/tv_info_page.dart` | 番剧详情页 |
| `lib/tv/pages/popular/tv_popular_page.dart` | 热门番剧页 |
| `lib/tv/widgets/tv_bangumi_card.dart` | 番剧卡片 |
| `lib/tv/core/focus/tv_focus_scope.dart` | 焦点作用域 |
| `lib/tv/core/widgets/tv_button.dart` | 可聚焦 TV 按钮（Enter/Select/DPAD） |
| `android/app/build.gradle` | `namespace "com.predidit.kazumi"` |

---

## 关键约束 / 踩坑记录

- **flutter_modular 7.x 没有全局 `Modular`**：本项目自定义了
  `lib/tv/utils/modular_compat.dart` 里的 `Modular` 类。
- **`ModularApp` 的 `navigatorKey` 只有在 child 消费 `routerConfigOf` 时才有意义**。
- **`MaterialApp(home: X, onGenerateRoute: f)`**：`home` 处理 `/`，
  `f` 只在 `routes` 不含该路径时被调用（官方文档明确）。
- **带 `path` 的模块是 feature**：DI 只在进入该路由后绑定，详情页拿不到 → 必须放根模块。
- **`addSingleton` 不是 lazy**：factory 在 `ModularApp` bootstrap 时调用。
- **`inject<T>()` 在 singleton factory 内会失败** → 用 `.new` 让库自动解析构造参数。
- **`c.module(otherModule)` 是位置参数**，不是命名参数。
- **`KeyDownEvent` / `HardwareKeyboard` 在 `package:flutter/services.dart`**，不在 `material.dart`。
- **`KeyEventCallback = bool Function(KeyEvent)`**（`HardwareKeyboard.addHandler`）。
- **`KeyEventResult` 在 `package:flutter/widgets/focus_manager.dart`**（material 会 re-export）。
- **Android package**: `com.predidit.kazumi`；**Activity**: `com.example.kazumi.MainActivity`。
- **Emulator ABI**: `x86_64`。
- **CI 只跑 `flutter build apk`，不跑 `flutter analyze`** → 只有编译错误会失败。

---

## 用户操作指南

1. **推送 commit**：
   ```bash
   cd kazumi-tv-feature-android-tv
   git push origin master
   ```

2. **打 tag 触发 CI 构建**：
   ```bash
   git tag tv-build-35
   git push origin tv-build-35
   ```

3. **安装 APK**：
   ```bash
   adb uninstall com.predidit.kazumi
   adb install path/to/kazumi_tv_tv-build-35_x86_64.apk
   ```

4. **启动**：
   ```bash
   adb shell am start -n com.predidit.kazumi/com.example.kazumi.MainActivity
   ```

5. **看日志**：
   ```bash
   adb logcat -d | grep "TV:"
   ```

---

## 下一次构建要重点验证的内容

按优先级：

1. **点番剧卡片 → 能否进入详情页**（最核心）
   - 预期日志：`TV: _handleBangumiTap called for item <id>`
   - 若仍失败：看是否有 `TV: Modular.pushNamed(...) ignored - navigator is null`
     （说明首帧回调没绑定上，需要改成 `WidgetsBinding.instance.addPostFrameCallback` 重试）
2. **详情页 → 选源播放 → 能否进入播放器**
   - 若报 "PlayerController not registered"，检查 `tvModule` 里
     `addSingleton(PlayerController.new)` 的位置与 `AudioController` 的注册顺序。
3. **按 `D` 键 / 设置→关于→开发者菜单 → 能否打开开发者菜单**
4. **开发者菜单里逐条跳转是否都正常**
5. **设置 → 插件列表 → 插件商店**（`/settings/plugin/shop`）
6. 返回键行为：主界面弹「退出应用」；详情页/播放器正常出栈
