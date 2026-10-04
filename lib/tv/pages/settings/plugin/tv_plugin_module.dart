import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_list_page.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_shop_page.dart';

/// 插件设置模块
final tvPluginModule = createModule(
  path: '/plugin',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => const TVPluginListPage(),
      )
      ..route(
        '/shop',
        child: (context, state) => const TVPluginShopPage(),
      );
  },
);
