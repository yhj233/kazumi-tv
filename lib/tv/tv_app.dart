import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'core/utils/tv_constants.dart';
import 'utils/modular_compat.dart';
import 'pages/main/tv_main_page.dart';

/// TV 应用入口
class TVApp extends StatefulWidget {
  const TVApp({super.key});

  @override
  State<TVApp> createState() => _TVAppState();
}

class _TVAppState extends State<TVApp> {
  @override
  void initState() {
    super.initState();
    initTVEnvironment();
  }

  @override
  Widget build(BuildContext context) {
    // Set the navigator reference for the compat layer.
    final navigator = Navigator.of(context);
    Modular.setNavigator(navigator);

    // Render the root route directly from the module tree.
    // The ModularApp already provides a Navigator; we just need to
    // display the widget for the root route '/' (TVMainPage).
    return MaterialApp(
      title: 'Kazumi TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        primaryColor: TVConstants.focusColor,
        scaffoldBackgroundColor: TVConstants.backgroundColor,
        fontFamily: 'MI_Sans_Regular',
        colorScheme: const ColorScheme.dark(
          primary: TVConstants.focusColor,
          secondary: TVConstants.focusColor,
          surface: TVConstants.backgroundColor,
          onSurface: TVConstants.textPrimaryColor,
          surfaceContainerHighest: TVConstants.surfaceVariantColor,
        ),
        cardTheme: CardThemeData(
          color: TVConstants.surfaceVariantColor,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: TVConstants.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          titleTextStyle: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: TVConstants.textPrimaryColor,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: TVConstants.focusColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: TVConstants.textPrimaryColor,
          ),
          headlineMedium: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: TVConstants.textPrimaryColor,
          ),
          titleLarge: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: TVConstants.textPrimaryColor,
          ),
          titleMedium: TextStyle(
            fontSize: TVConstants.titleFontSize,
            fontWeight: FontWeight.w500,
            color: TVConstants.textSecondaryColor,
          ),
          bodyLarge: TextStyle(
            fontSize: TVConstants.titleFontSize,
            color: TVConstants.textSecondaryColor,
          ),
          bodyMedium: TextStyle(
            fontSize: TVConstants.subtitleFontSize,
            color: TVConstants.textTertiaryColor,
          ),
          labelLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TVConstants.textSecondaryColor,
          ),
          labelSmall: TextStyle(
            fontSize: 12,
            color: TVConstants.textDisabledColor,
          ),
        ),
      ),
      home: TVMainPage(),
    );
  }
}

/// 初始化 TV 环境
Future<void> initTVEnvironment() async {
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;

  PaintingBinding.instance.imageCache.maximumSize =
      TVConstants.maxImageCacheSize;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      TVConstants.maxImageCacheBytes;

  // 设置 TV 默认配置
  await GStorage.putSetting(SettingsKeys.autoPlayNext, true);
  await GStorage.putSetting(SettingsKeys.playResume, true);
  await GStorage.putSetting(SettingsKeys.danmakuBiliBiliSource, true);
  await GStorage.putSetting(SettingsKeys.danmakuGamerSource, true);
  await GStorage.putSetting(SettingsKeys.danmakuDanDanSource, true);
  await GStorage.putSetting(SettingsKeys.defaultStartupPage, '/tab/popular/');
  await GStorage.putSetting(SettingsKeys.enableGitProxy, true);

  final pluginsController = Modular.get<PluginsController>();
  try {
    await pluginsController.init();
    if (pluginsController.pluginList.isEmpty) {
      await pluginsController.copyPluginsToExternalDirectory();
    }
    await pluginsController.checkPluginUpdatesOnStartup(enabled: true);
  } catch (e) {
    KazumiLogger().e('TV: plugin init failed', error: e);
  }
}
