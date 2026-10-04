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
import 'package:kazumi/tv/tv_app.dart';
import 'package:kazumi/tv/tv_module.dart';

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
    runApp(const MaterialApp(
      title: '初始化失败',
      builder: (context, child) => const TVApp(),
    ));
    return;
  }

  if (Platform.isAndroid) {
    await WebViewFeatureService.initialize();
  }
  await MeteredNetworkService.refresh();
  ProxyManager.applyProxy();

  runApp(
    ModularApp(
      module: TVModule(),
      child: const TVApp(),
    ),
  );
}
