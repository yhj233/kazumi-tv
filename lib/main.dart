import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:kazumi/tv/pages/main/tv_main_page.dart';
import 'package:kazumi/tv/tv_module.dart';
import 'package:kazumi/tv/core/utils/tv_constants.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';

/// TV 导航器 GlobalKey
final tvNavigatorKey = GlobalKey<NavigatorState>();

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
    runApp(MaterialApp(
      title: '初始化失败',
      home: TVMainPage(),
    ));
    return;
  }

  if (Platform.isAndroid) {
    await WebViewFeatureService.initialize();
  }
  await MeteredNetworkService.refresh();
  ProxyManager.applyProxy();

  runApp(ModularApp(
    module: tvModule,
    navigatorKey: tvNavigatorKey,
    child: MaterialApp(
      title: 'Kazumi TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        primaryColor: TVConstants.focusColor,
        scaffoldBackgroundColor: TVConstants.backgroundColor,
        colorScheme: ColorScheme.dark(
          primary: TVConstants.focusColor,
          secondary: TVConstants.focusColor,
          surface: TVConstants.backgroundColor,
          onSurface: TVConstants.textPrimaryColor,
          surfaceContainerHighest: TVConstants.surfaceVariantColor,
        ),
      ),
      home: TVMainPage(),
    ),
  ));

  // ModularApp 的 navigator 才是用于路由导航的
  // 在 ModularApp 构建完成后设置 Modular.to
  scheduleMicrotask(() {
    final navState = tvNavigatorKey.currentState;
    if (navState != null) {
      Modular.setNavigator(navState);
      debugPrint('TV: main.dart set Modular.to to ModularApp navigator');
    } else {
      debugPrint('TV: main.dart tvNavigatorKey.currentState is null!');
    }
  });
}
