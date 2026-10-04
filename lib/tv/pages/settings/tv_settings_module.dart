import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/tv/pages/settings/tv_settings_page.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_module.dart';

/// 设置页面模块
final tvSettingsModule = createModule(
  path: '/settings',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => const TVSettingsPage(),
      )
      ..module(tvPluginModule);
  },
);
