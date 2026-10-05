import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/tv/pages/main/tv_main_page.dart';
import 'package:kazumi/tv/pages/developer/tv_developer_page.dart';
import 'package:kazumi/tv/pages/settings/tv_settings_module.dart';
import 'package:kazumi/tv/pages/collect/tv_collect_module.dart';
import 'package:kazumi/tv/pages/info/tv_info_module.dart';
import 'package:kazumi/tv/pages/player/tv_player_module.dart';
import 'package:kazumi/tv/pages/popular/tv_popular_module.dart';
import 'package:kazumi/tv/pages/search/tv_search_module.dart';
import 'package:kazumi/tv/pages/timeline/tv_timeline_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';

/// TV 模块：注册所有单例服务。
///
/// `flutter_modular` 会自动解析构造函数参数（constructor injection）。
/// 当 singleton 工厂被调用时，库自动从 DI 容器解析依赖并传递给构造函数。
/// 所以不需要在工厂里手动调用 `inject<T>()`。
///
/// 注意：**路由不走 flutter_modular**（7.x 需要 `MaterialApp.router` +
/// `ModularApp.routerConfigOf`，否则 `route(...)` 完全是死代码）。
/// 真正的路由表在 `lib/tv/core/navigation/tv_routes.dart` 的 `tvOnGenerateRoute`，
/// 这里的 `route(...)` / `module(...)` 仅为兼容声明保留。
final tvModule = createModule(
  register: (c) {
    c
      // 根路由：应用启动时显示的页面
      ..route(
        '/',
        child: (context, state) => TVMainPage(),
        transition: TransitionType.none,
      )
      // 开发者菜单
      ..route(
        '/developer',
        child: (context, state) => TVDeveloperPage(),
        transition: TransitionType.none,
      )
      // 不需要依赖的 singleton
      ..addSingleton<ICollectRepository>(CollectRepository.new)
      ..addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new)
      ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
      ..addSingleton<IHistoryRepository>(HistoryRepository.new)
      ..addSingleton<IDownloadRepository>(DownloadRepository.new)
      ..addSingleton<IDownloadManager>(DownloadManager.new)
      ..addSingleton<IDanmakuShieldRepository>(DanmakuShieldRepository.new)
      ..addSingleton(PopularController.new)
      ..addSingleton(PluginsController.new)
      ..addSingleton(ShaderAssetService.new)
      // 需要依赖的 controller——库自动解析构造函数参数
      ..addSingleton(HistoryController.new)
      ..addSingleton(VideoPageController.new)
      ..addSingleton(TimelineController.new)
      ..addSingleton(CollectController.new)
      ..addSingleton(MyController.new)
      ..addSingleton(DownloadController.new)
      ..addSingleton(InfoController.new)
      // 播放相关：必须注册在**根模块**。
      // 若注册在 path: '/player' 这种 feature 子模块里，只有进入该路由后
      // 才会绑定，播放器页面初始化时拿不到实例。
      ..addSingleton(AudioController.new)
      ..addSingleton(PlayerController.new)
      // 子模块（仅保留路由声明，本应用的路由由 tvOnGenerateRoute 接管）
      ..module(tvPopularModule)
      ..module(tvTimelineModule)
      ..module(tvCollectModule)
      ..module(tvSearchModule)
      ..module(tvSettingsModule)
      ..module(tvInfoModule)
      ..module(tvPlayerModule);
  },
);
