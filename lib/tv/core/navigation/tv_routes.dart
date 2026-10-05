import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/tv/core/utils/tv_constants.dart';
import 'package:kazumi/tv/pages/developer/tv_developer_page.dart';
import 'package:kazumi/tv/pages/info/tv_info_page.dart';
import 'package:kazumi/tv/pages/main/tv_main_page.dart';
import 'package:kazumi/tv/pages/player/tv_player_page.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_list_page.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_shop_page.dart';

/// TV 版本路由表。
///
/// 这里直接使用 Flutter 原生 [Navigator]（`MaterialApp.onGenerateRoute`），
/// 不使用 flutter_modular 7.x 的路由系统：
/// 7.x 要求写成 `MaterialApp.router(routerConfig: ModularApp.routerConfigOf(context))`，
/// 否则模块里 `route(...)` 注册的路由完全不会生效，`pushNamed` 必然失败。
///
/// 本应用需要完全掌控 TV 焦点与返回键（DPAD / BACK）行为，
/// 因此采用原生 `MaterialApp(home: ...)` + 显式路由表的方式；
/// flutter_modular 只保留依赖注入能力（`Modular.get<T>()` / `inject<T>()`）。
///
/// 路径统一为**不以 `/` 结尾**的形式，路由表内部会自动归一化，
/// 所以 `/info` 与 `/info/` 都能命中。
Route<dynamic>? tvOnGenerateRoute(RouteSettings settings) {
  final String name = _normalizeRouteName(settings.name);

  switch (name) {
    case '/developer':
      return _buildPage(const TVDeveloperPage(), settings);

    case '/info':
      final Object? args = settings.arguments;
      if (args is BangumiItem) {
        return _buildPage(TVInfoPage(bangumiItem: args), settings);
      }
      return _buildPage(
        const TvRouteErrorPage(message: '缺少番剧参数，无法打开详情页'),
        settings,
      );

    case '/player':
      return _buildPage(const TVPlayerPage(), settings);

    case '/settings/plugin':
      return _buildPage(const TVPluginListPage(), settings);

    case '/settings/plugin/shop':
      return _buildPage(const TVPluginShopPage(), settings);

    // 以下为主界面各 Tab 的独立入口，主要用于开发者菜单调试路由。
    case '/popular':
      return _buildPage(
        const TVMainPage(initialTab: 0, isRoot: false),
        settings,
      );

    case '/timeline':
      return _buildPage(
        const TVMainPage(initialTab: 1, isRoot: false),
        settings,
      );

    case '/collect':
      return _buildPage(
        const TVMainPage(initialTab: 2, isRoot: false),
        settings,
      );

    case '/search':
      return _buildPage(
        const TVMainPage(initialTab: 3, isRoot: false),
        settings,
      );

    case '/settings':
      return _buildPage(
        const TVMainPage(initialTab: 4, isRoot: false),
        settings,
      );

    default:
      return _buildPage(
        TvRouteErrorPage(message: '未知路由: $name'),
        settings,
      );
  }
}

/// 去掉结尾多余的 `/`，并把空路径归一化为 `/`。
String _normalizeRouteName(String? name) {
  String result = name ?? '/';
  while (result.length > 1 && result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result.isEmpty ? '/' : result;
}

MaterialPageRoute<dynamic> _buildPage(Widget child, RouteSettings settings) {
  return MaterialPageRoute<dynamic>(
    builder: (_) => child,
    settings: settings,
  );
}

/// 路由参数缺失 / 路径不存在时的占位页面。
class TvRouteErrorPage extends StatelessWidget {
  const TvRouteErrorPage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TVConstants.backgroundColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: TVConstants.textTertiaryColor,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: TVConstants.textPrimaryColor,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              autofocus: true,
              onPressed: () {
                final navigator = Navigator.of(context);
                if (navigator.canPop()) {
                  navigator.pop();
                }
              },
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
