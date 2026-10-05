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

## 🎯 修复「集数解析失败」与「搜索无结果(401)」

> ⚠️ **修正上一节的结论**：之前判定「集数解析失败 = 源失效」只对了一半。
> 内置源确实失效了，但**同时还有一个真正的功能 bug**，
> 而且这个 bug 会让**任何**源都失败。

### 问题 1：集数解析失败（功能 bug，与源无关）

**证据**：`logcat.txt` 里 `VideoPageController: failed to resolve online episode.
road=0, episode=1` 之前，**完全没有获取剧集页面的 HTTP 请求**。
说明代码在发请求之前就退出了。

**根因**：`TVInfoPage._playSearchResult` 直接调用 `changeEpisode`，
**漏了 `plugin.queryChapterRoads(src)` 这一步**：

```dart
// lib/pages/video/video_controller.dart
final resolvedEpisode = _resolveOnlineEpisode(episode, road: currentRoad);
if (resolvedEpisode == null) {
  KazumiLogger().e('...failed to resolve online episode...');
  _failLoading('集数解析失败');   // ← 用户看到的就是这句
  return;
}
// _resolveOnlineEpisode: roadList.isEmpty → return null
```

`roadList` 只能由 `applyPlaybackArgs(OnlineVideoPlaybackArgs(roads: ...))`
写入。TV 详情页从来没走过这条路径 → `roadList` 恒为空 → 必然「集数解析失败」。

**上游的正确流程**（`lib/pages/info/source_sheet.dart:_openSearchItem`）：

```dart
final roads = await plugin.queryChapterRoads(searchItem.src, cancelToken: token);
if (roads.isEmpty) throw ChapterErrorException(plugin.name);
task.withContext((context) => context.pushNamed('/video/',
    arguments: OnlineVideoPlaybackArgs(..., roads: roads)));
```

再由 `video_page.initState` 调 `applyPlaybackArgs(widget.args)` 把
`roadList` 写进 controller，最后 `changeEpisode` 开始播放。

**修复**：`tv_info_page.dart._playSearchResult` 改为
「先 `queryChapterRoads` → 空则提示 → `applyPlaybackArgs(...)` → push /player」。

这同时解释了日志里的一个怪现象：**每次按键会出现两条完全相同的 error**——
详情页调了一次 `changeEpisode`（失败），push 到播放器后
`TVPlayerPage.initState` 又调了一次（再失败）。

### 问题 2：搜索输入任何都无结果（401）

**证据**：

```
Bangumi mirror: https://api.kazumi.fyi/v0/search/subjects?limit=20&offset=0
HTTP: <-- 401 POST https://api.kazumi.fyi/v0/search/subjects...
ERROR Network: unknown search problem | badResponse (401)
```

**根因**：镜像后端对 `POST /v0/search/subjects`（以及评论接口）要求
`X-AppId` + `X-Timestamp` + `X-Signature` 签名
（`lib/request/clients/bangumi_client.dart:_shouldSignProtectedMirrorRequest`）。
密钥来自：

```dart
// lib/utils/bangumi_mirror_credentials.dart
// Release/PR CI injects them via --dart-define=KAZUMI_APPID / KAZUMI_KEY.
const Map<String, String> bangumiMirrorCredentials = {
  'id': String.fromEnvironment('KAZUMI_APPID'),
  'value': String.fromEnvironment('KAZUMI_KEY'),
};
```

而**本仓库的 CI 漏传了这两个 define**：

| workflow | DANDANAPI_* | KAZUMI_* |
|----------|-------------|----------|
| `Kazumi-main/.github/workflows/release.yaml` | ✅ | ✅ |
| `kazumi-tv-feature-android-tv/.github/workflows/release.yaml` | ✅ | ❌ **缺失** |

→ 密钥是空字符串 → 签名必然校验失败 → **401**。

而 `SettingsKeys.enableBangumiProxy` 默认 `true`、`bangumiAcceleration` 默认 `''`
→ `BangumiAcceleration.current == mirror` → 所有 Bangumi 请求（含搜索）都走镜像。

**修复（两层）**：

1. **CI**：`release.yaml` 补上
   `--dart-define=KAZUMI_APPID=${{ secrets.KAZUMI_APPID }}` 与
   `--dart-define=KAZUMI_KEY=${{ secrets.KAZUMI_KEY }}`。
   （secret 未配置时展开为空串，无副作用；配了就能正常用镜像搜索。）
2. **代码兜底**：`BangumiAccelerationInterceptor` 中，当处于镜像模式、
   目标是受保护接口、且 `hasMirrorCredentials == false` 时，
   **不改写为镜像**，改用 ECH 路径（`BangumiEchAdapter`，DoH + ECH 直连
   `api.bgm.tv`）。这样即使没有密钥也不会拿到 401。
   - 新增 `BangumiAcceleration.hasMirrorCredentials`
     与 `BangumiAcceleration.isProtectedMirrorEndpoint()`，
     `BangumiClient` 与 interceptor 共用同一份判定。
3. **TV 设置**新增「网络 → 番剧数据源」下拉：`自动 / ECH / 直连 / 镜像`，
   用户可自行切换（ECH 不通时切直连）。

### 顺带修复：观看历史恢复

`TVPlayerPage.initState` 原来直接 `changeEpisode(selectedEpisode...)`，
既没有历史恢复，又因为 **TV 版 `VideoPageController` 是根单例**
（上游是路由级、随路由销毁）而可能残留上一部番剧的集数。

新增 `_startPlayback()`，对齐上游 `video_page._initOnlineMode()`：

```dart
videoPageController.historyOffset = 0;
videoPageController.resetEpisodeState(episode: 1);   // 先归零
final progress = _historyController.lastWatching(bangumiItem, currentPlugin.name);
if (progress != null && road 与 episode 均在范围内) {
  videoPageController.resetEpisodeState(episode: progress.episode, road: progress.road);
  if (playResume) videoPageController.historyOffset = progress.progress.inSeconds;
}
videoPageController.changeEpisode(...);
```

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

## 🎯 修复「进度条 0:00 / 无法拖动」「弹幕不显示」「Toast 全失效」

### 问题 1：进度条 0:00，且前进会跳回开头

**根因**：`playback.duration` 是 `@observable` 字段，**只有 `syncPlaybackState()` 会写入它**
（`player_playback_controller.dart:576`）。而全仓库只有**移动端**的
`player_item.dart:1174` 那个每秒定时器调用它：

```dart
Timer getPlayerTimer() {
  return Timer.periodic(const Duration(seconds: 1), (timer) {
    playerController.syncPlaybackState();   // ← 全靠这一句
    ...
```

TV 端的 1 秒定时器（`tv_player_controls.dart:89`）只做了个空转，
从不调用 `syncPlaybackState()` → `duration` 恒为 `Duration.zero`：

- `ProgressBar(total: playback.duration)` → 总时长 **0:00**
- `_doSeekStep()` 里 `if (newPosition > duration) newPosition = duration;`
  → 任何 seek 都被 clamp 回 **0** → 「前进就回到开头」

**修复**：
- `tv_player_page` 新增每秒定时器，调用 `playerController.syncPlaybackState()`
- `ProgressBar.total` 与 `_doSeekStep` 改用**实时 getter** `playerDuration`
  （直接读 `mediaPlayer.state`，不依赖定时器，双保险）

### 问题 2：弹幕功能无效 —— **两个独立原因叠加**

**(a) 数据拉不到：`403`**

```
403 GET https://api.dandanplay.net/api/v2/bangumi/bgmtv/622206
PlayerController: failed to get danmaku [BgmBangumiID] 622206 | badResponse (403)
```

DanDanPlay 与 Bangumi 镜像是同一套机制：需要 `X-AppId` + `X-Signature` 签名，
密钥来自 `--dart-define=DANDANAPI_APPID / DANDANAPI_KEY`
（`lib/utils/dandan_credentials.dart`）。

⚠️ **需要你操作**：在 GitHub 仓库 `yhj233/kazumi-tv` 的
**Settings → Secrets and variables → Actions** 里添加：

| Secret | 用途 | 从哪来 |
|--------|------|--------|
| `DANDANAPI_APPID` | 弹幕（必需） | https://doc.dandanplay.com/ 申请开发者应用 |
| `DANDANAPI_KEY` | 弹幕（必需） | 同上 |
| `KAZUMI_APPID` | Bangumi 镜像搜索（可选） | 上游私有，拿不到也行（已有 ECH 兜底） |
| `KAZUMI_KEY` | 同上 | 同上 |

workflow 里已经写好了 `--dart-define`，**只要 secrets 存在就会自动生效**，
不需要改代码。缺 DaneDanPlay 密钥时日志现在会明确提示
「构建时缺少 DANDANAPI_APPID/DANDANAPI_KEY」。

**(b) 即使拿到数据也不显示：发射逻辑从未移植**

把弹幕推到画布上的 `_emitDanmakusForCurrentPosition()`
（`player_item.dart:1129`）**只在移动端**被那个每秒定时器调用。
TV 端 `playerController.danmaku.canvasController` 只被**赋值**
（`tv_player_page.dart` 的 `DanmakuScreen.createdController`），
**从来没有 `addDanmaku()` 被调用过** → 画布永远是空的。

**修复**：把 `_emitDanmakusForCurrentPosition()` +
`_isDanmakuSourceEnabled()` + `_danmakuItemType()` 移植到 `tv_player_page`，
并随每秒定时器驱动。
（其实 `_danmakuColor` / `_danmakuBiliBiliSource` / `_danmakuGamerSource` /
`_danmakuDanDanSource` 这几个字段早就读进 State 了却从未被使用 —— 正是缺了这段。）

### 问题 3：所有 Toast 都失败

```
Kazumi Dialog Error: No ScaffoldMessenger available to show Toast
```

`KazumiDialog.showToast` 在没有 context 时会回退到
`rootScaffoldMessengerKey.currentState`（`dialog.dart:215`），
而 `main.dart` 的 `MaterialApp` **没有挂 `scaffoldMessengerKey`**
（上游 `app_widget.dart:316` 是挂了的）。

→ 所有错误提示被静默丢弃，等于**完全看不到反馈**。
已补 `scaffoldMessengerKey: rootScaffoldMessengerKey`。

### 问题 4：详情页加载完后选中的条目位置不确定

`TVSearchResultSection` 原来是「**哪个源先搜完就锁定哪个源的第一条**」
（`_firstFocusNodeSet` 只认第一次回调），而各源完成顺序不定
→ 选中的条目位置飘忽，经常落在靠后的位置。

**修复**：按列表展示顺序挑「**最靠前分组的第一条**」
（新增 `_firstNodeByPlugin` + `_visiblePlugins` 顺序匹配），
并在 `TVInfoPage` 里去掉 `_firstFocusNodeSet` 锁，允许更新为更靠前的候选。

---

## 下一次构建要重点验证的内容

按优先级：

1. **详情页 → 选源 → 播放 → 拖进度条**（本轮核心）
   - 进度条应显示真实总时长（不再是 `0:00`）
   - 左右方向键快进/快退应生效，**不再跳回开头**
   - 预期日志：视频起播后每秒都在跑 `syncPlaybackState`（无日志，但进度条会动）

2. **弹幕**
   - 配好 `DANDANAPI_APPID/KEY` 后：日志应出现
     `PlayerController: attempting to get danmaku [BgmBangumiID] ...` 且**不再 403**，
     并在播放 1~2 秒后看到弹幕飘过
   - 未配密钥时：日志会明确提示「构建时缺少 DANDANAPI_APPID/DANDANAPI_KEY」

3. **任意错误提示（Toast）应能正常弹出**（不再有 No ScaffoldMessenger 日志）

4. **详情页加载完后，选中的应是「最靠前分组的第一条」**

5. **详情页 → 选源 → 能否播放**（上轮已修复，回归）
   - 预期：`VideoPageController: changed to 第1集` → `resolved video URL: ...`

6. **搜索页输入关键词 → 能否出结果**
   - 预期：`Bangumi mirror: skip protected endpoint /v0/search/subjects ... fallback to ECH`
   - 不应再出现 `401`

7. **设置 → 规则仓库 → 插件商店 → 安装规则**；装完重进详情页看是否多出源

8. **观看历史恢复**：播到第 2 集 → 返回 → 重进 → 应从第 2 集续播
   - 预期日志：`TV: resume playback at road=0 episode=2 offset=...`

9. **按 `D` 键 / 设置→关于→开发者菜单**

10. 返回键行为：主界面弹「退出应用」；详情页 / 播放器 / 规则仓库正常出栈

> 关于「从播放界面返回会显示『正在获取播放列表』转圈」：
> 该 loading 来自 `TVInfoPage._playSearchResult` 的 `KazumiDialog.showLoading`。
> 若出现「转圈不消失／需手动返回」，多半是**同一次点击触发了两次** `_playSearchResult`
> （两次 showLoading 只 dismiss 了一次）。排查方向：
> `TVSearchResultSection` 里 `TvGridItem.onSelect` 与 `TVSearchResultCard.onSelect`
> 是否都被绑定、以及 `TvKeyHandler` 的 `onEnter`/`onSelect` 是否会重复触发。
> 本轮未改（用户标注「可能不需要修」）。

---

## 关键教训（给后续接手的人）

**TV 移植最容易漏的是「移动端 widget 里的每秒定时器」**。
上游把「同步播放状态」「发射弹幕」「写观看历史」「自动连播」全部塞在
`player_item.dart` 的 `getPlayerTimer()` 里 —— 那是移动端特有的 widget，
TV 版重写成自己的播放器页面时，这些副作用**全都没有被带过来**。

排查同类问题的姿势：在移动端找到对应的 widget，看它的 `initState` /
`Timer.periodic` / 各种 `reaction` 里做了什么，逐条对照 TV 版有没有。

---

## 如果播放仍然失败的排查顺序

1. 看日志有没有取剧集页面的请求 → 没有就是 `queryChapterRoads` 之前就挂了
2. 有请求但 `roads.isEmpty` → 该规则对该番剧没有匹配结果，换源
3. 拿到剧集但仍失败 → 看 `_resolveWithVideoSourceService`（无头 WebView 嗅探）
   - 相关代码：`lib/webview/video/impl/video_webview_android_impl.dart`
   - Android 需 `WebViewFeatureService.initialize()`（`main.dart` 已调用）
   - 相关日志前缀：`[WebView]`、`WebView:`
4. 模拟器（x86_64）上 WebView 嗅探可能不稳定，**真机（arm64）更可信**
