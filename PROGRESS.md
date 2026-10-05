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

## 🎯 规则仓库接入（解决"获取集数失败"）

### 结论：是**源的问题**，不是功能问题

`logcat.txt`（详情页 ID 622288）显示 3 条内置规则全部不可用：

| 规则 | 站点 | 结果 |
|------|------|------|
| `agedm` | www.agedm.io | HTTP 200 但无有效结果 |
| `DM84` | dmbus.cc | `connectionError ... Connection reset by peer`（站点已挂） |
| `aafun` | www.aafun.cc | HTTP 200 但 `no results for aafun` |

→ `VideoPageController: failed to resolve online episode. road=0, episode=1`

同时 `Rules mirror: https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/index.json`
返回 **200**，说明规则仓库本身是通的。

### 真正的缺口：TV 设置界面没有「规则仓库」入口

对比 `Kazumi-main` 与 `kazumi-tv-feature-android-tv`：
`lib/plugins`、`lib/services/plugin`、`lib/request`、`lib/pages` **文件完全相同**
（`Kazumi-main` 是上游，TV 分支只是多了一层 `lib/tv/`）。

也就是说 `TVPluginListPage`（已安装规则 + 更新全部 + 商店入口）和
`TVPluginShopPage`（规则目录 + 安装）**代码早就存在**，
但 grep 显示它们**只在开发者菜单里可达**：

```
lib/tv/core/navigation/tv_routes.dart:45   /settings/plugin
lib/tv/core/navigation/tv_routes.dart:48   /settings/plugin/shop
lib/tv/pages/developer/tv_developer_page.dart:87,91
```

`TVSettingsPage` 只有 播放设置 / 弹幕设置 / 关于 三个 Tab —— **用户无法安装社区规则**，
只能用那 3 条已失效的内置规则。

### 修复内容

| 文件 | 改动 |
|------|------|
| `lib/tv/pages/settings/tv_settings_page.dart` | 新增第 3 个 Tab **「规则仓库」**（播放设置 / 弹幕设置 / **规则仓库** / 关于），内容为 `TVPluginListPage` |
| `lib/tv/pages/settings/plugin/tv_plugin_list_page.dart` | `autofocus` 改为只在父级未接管焦点时生效（`_ownsUpdateAllNode`）。否则嵌入 `IndexedStack` 时 4 个子页会同时抢焦点 |
| `lib/tv/pages/settings/plugin/tv_plugin_shop_page.dart` | 重写为完整的规则仓库页 |

新的 `TVPluginShopPage`：

- **顶部工具行**：`刷新` / `全部 N` / `已安装 N` / `可更新 N` / `镜像 开·关`
- **列表**：规则名 + 版本标签 + `需验证` 标签 + 作者 + 更新时间 + `安装`/`更新`/`已安装`
- **状态**：加载中（转圈 / 线性进度）、加载失败（`重试` + `启用/关闭规则镜像`）、空列表
- 按 `lastUpdate` 倒序；复用 `updatePluginWithFeedback`，能正确提示
  「规则需要更高版本客户端」「远程规则版本不高于本地，已跳过更新」等
- 安装成功后提示：返回详情页**重新搜索**即可

**规则镜像开关很重要**：规则仓库有两个源——
`https://raw.githubusercontent.com/Predidit/KazumiRules/main/`（直连）
与 `https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/`（gitcode 镜像）。
`_RulesMirrorInterceptor` 在**每次请求**时读取 `SettingsKeys.enableGitProxy`，
所以页面里切换后立即重新拉取即可生效。国内直连 GitHub 常失败。

### 规则仓库当前内容（2026-10 实测）

`index.json` 返回 **16 条规则**：`7sefun` `aafun` `AGE` `akianime` `baimao` `dalvdm`
`DM84` `ezdmw` `giriGiriLove` `mgnacg` `moonci` `mutefun` `MXdm` `sorani`
`xfdmneo` `xfdmnext`（其中 `dalvdm`/`giriGiriLove`/`mgnacg`/`mutefun` 标记 `需验证`）。

### 关于 `useNativePlayer`

catalog 里 16 条规则**全部** `useNativePlayer: true`。已确认这条路径在 TV 版可用：
`lib/webview/video/` 下有完整的 `VideoWebviewController`（Android 用
`flutter_inappwebview` 无头 WebView 嗅探 m3u8），
`video_controller.dart:596` 的 `_resolveWithVideoSourceService` 会走它。
（`useNativePlayer` 字段本身在播放逻辑里没有被读取，仅用于列表展示/编辑器。）

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

### 3. ~~缺少"添加来源仓库"功能~~ ✅ 已实现
设置 → 规则仓库 已接入（见上文「规则仓库接入」）。
注意：目前只能**安装社区规则**，还不支持**自定义仓库地址**
（上游 `ApiEndpoints.pluginShop` 也是 `const`，所以要加需要改上游设计）。

### 4. 内置规则仍是 3 条失效规则
`assets` 里打包的 `agedm` / `DM84` / `aafun` 已不可用。
即使装了新规则，这 3 条仍然会出现在「更新全部」里并报错
（已安装列表可逐条删除）。可选优化：首次启动时自动清理失效规则，
或把默认打包规则换成仓库里可用的。

### 5. `lib/tv/tv_app.dart` 已成死代码
`TVApp` 类未被使用（`main.dart` 不再用它），但 `initTVEnvironment()` 仍在被
`TVMainPage.initState` 调用，所以文件必须保留。
另外 `initTVEnvironment()` 每次启动都会**强制写入** 7 项设置
（`autoPlayNext` / `playResume` / 3 个弹幕源 / `enableGitProxy` / `defaultStartupPage`），
会覆盖用户改动 —— 包括规则镜像开关，重启后会被重置为「开」。
如果要做规则镜像的持久化开关，需要先改掉这里。

### 6. `tvModule` 里的 `route(...)` / `module(...)` 是惰性声明
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

2. **打 tag 触发 CI 构建**（`tv-build-35` 若已用过就顺延）：
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

1. **设置 → 规则仓库 → 插件商店 → 安装 1~2 条规则**（本次新增，最核心）
   - 预期：列表出现 16 条规则，可聚焦，按 OK 能安装并提示「导入成功」
   - 若列表加载失败：点「启用规则镜像」再试（`raw.githubusercontent.com` 国内常不通）
   - 若点了没反应：检查 `TVPluginShopPage` 的 `_toolNodes` / `_RuleCard._actionFocusNode`
     的焦点链（左右键能否从卡片走到「安装」按钮）

2. **安装规则后 → 返回 → 重回详情页 → 能否搜到结果**
   - 路径必须先退出详情页（详情页 -> back -> 设置 -> 规则仓库 -> 安装 -> back -> 重进详情页），
     因为 `TVInfoPage.initState` 只在首次构建时跑一次 `queryAllSource`
   - 预期日志：`PluginSearchService: no results for xxx` 减少，
     出现 `VideoPageController: resolved video URL: ...`

3. **点番剧卡片 → 能否进入详情页**（上次已通过 ✅，回归确认）
   - 预期日志：`TV: _handleBangumiTap called for item <id>`

4. **详情页 → 选源播放 → 能否进入播放器**
   - 若报 "PlayerController not registered"，检查 `tvModule` 里
     `addSingleton(PlayerController.new)` 的位置与 `AudioController` 的注册顺序。

5. **按 `D` 键 / 设置→关于→开发者菜单 → 能否打开开发者菜单**

6. 返回键行为：主界面弹「退出应用」；详情页 / 播放器 / 规则仓库正常出栈
