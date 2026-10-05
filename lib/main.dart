import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/network/ech_http_licenses.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/platform/webview_feature_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/tv/core/navigation/tv_routes.dart';
import 'package:kazumi/tv/core/utils/tv_constants.dart';
import 'package:kazumi/tv/pages/main/tv_main_page.dart';
import 'package:kazumi/tv/tv_module.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';

/// Kazumi TV 入口：本仓库为 Android TV 专用分支，直接启动 TV 应用。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerEchHttpLicenses();
  MediaKit.ensureInitialized();

  try {
    final hivePath = '${(await getApplicationSupportDirectory()).path}/hive';
    await Hive.initFlutter(hivePath);
    await GStorage.init();
  } catch (e) {
    KazumiLogger().e('Kazumi TV: failed to init storage', error: e);
    runApp(const TVRootApp(storageFailed: true));
    return;
  }

  if (Platform.isAndroid) {
    await WebViewFeatureService.initialize();
  }
  await MeteredNetworkService.refresh();
  ProxyManager.applyProxy();

  runApp(
    ModularApp(
      module: tvModule,
      child: const TVRootApp(),
    ),
  );
}

/// TV 应用根 Widget。
///
/// 位于 `ModularApp` 之下（用于依赖注入），负责构建 `MaterialApp`。
///
/// 这里刻意使用原生 `MaterialApp(home:, onGenerateRoute:)` 而不是
/// `MaterialApp.router(routerConfig: ModularApp.routerConfigOf(context))`：
/// 路由表集中在 [tvOnGenerateRoute]，路径完全可控，
/// 也便于处理 TV 的 DPAD / 返回键行为。
class TVRootApp extends StatefulWidget {
  const TVRootApp({super.key, this.storageFailed = false});

  /// 存储初始化失败时展示提示页面。
  final bool storageFailed;

  @override
  State<TVRootApp> createState() => _TVRootAppState();
}

class _TVRootAppState extends State<TVRootApp> {
  @override
  void initState() {
    super.initState();
    // 首帧之后 MaterialApp 的 Navigator 一定已经挂载，
    // 此时把 NavigatorState 交给兼容层，后续 `Modular.pushNamed` 必定可用。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bindNavigator());
  }

  void _bindNavigator() {
    final NavigatorState? navigator = tvNavigatorKey.currentState;
    if (navigator != null) {
      Modular.setNavigator(navigator);
      debugPrint('TV: root navigator bound to Modular compat layer');
    } else {
      debugPrint('TV: root navigator is not ready yet');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.storageFailed) {
      return MaterialApp(
        title: '初始化失败',
        debugShowCheckedModeBanner: false,
        navigatorKey: tvNavigatorKey,
        onGenerateRoute: tvOnGenerateRoute,
        home: const TVMainPage(),
      );
    }

    return MaterialApp(
      title: 'Kazumi TV',
      debugShowCheckedModeBanner: false,
      navigatorKey: tvNavigatorKey,
      onGenerateRoute: tvOnGenerateRoute,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        primaryColor: TVConstants.focusColor,
        scaffoldBackgroundColor: TVConstants.backgroundColor,
        colorScheme: const ColorScheme.dark(
          primary: TVConstants.focusColor,
          secondary: TVConstants.focusColor,
          surface: TVConstants.backgroundColor,
          onSurface: TVConstants.textPrimaryColor,
          surfaceContainerHighest: TVConstants.surfaceVariantColor,
        ),
      ),
      home: const TVMainPage(),
    );
  }
}
