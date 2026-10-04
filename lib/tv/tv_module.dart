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
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/tv/pages/main/tv_main_page.dart';
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

/// TV 模块：注册所有单例服务和路由。
///
/// `addSingleton` 是 lazy 的——工厂在 service 第一次被访问时调用，
/// 而不是在 bootstrap 期间。所以 `inject<T>()` 在工厂内部是安全的，
/// 因为此时 bootstrap 已完成。
final tvModule = createModule(
  register: (c) {
    c
      // 根路由：应用启动时显示的页面
      // child 工厂在 bootstrap 完成后调用，所以 inject<T>() 是安全的
      ..route(
        '/',
        child: (context, state) => TVMainPage(),
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
      // 需要依赖的 controller——工厂在第一次访问时调用，inject<T>() 是安全的
      ..addSingleton<HistoryController>(() => HistoryController(inject<IHistoryRepository>()))
      ..addSingleton<VideoPageController>(() => VideoPageController(
          inject<HistoryController>(),
          inject<IDownloadRepository>(),
          inject<IDownloadManager>(),
        ))
      ..addSingleton<TimelineController>(() => TimelineController(inject<ICollectRepository>()))
      ..addSingleton<CollectController>(() => CollectController(inject<ICollectCrudRepository>()))
      ..addSingleton<MyController>(() => MyController(
          inject<IHistoryRepository>(),
          inject<IDownloadRepository>(),
          inject<IDanmakuShieldRepository>(),
        ))
      ..addSingleton<DownloadController>(() => DownloadController(
          inject<IDownloadRepository>(),
          inject<IDownloadManager>(),
          inject<PluginsController>(),
        ))
      ..addSingleton<InfoController>(() => InfoController(inject<CollectController>()))
      // 子模块
      ..module(tvPopularModule)
      ..module(tvTimelineModule)
      ..module(tvCollectModule)
      ..module(tvSearchModule)
      ..module(tvSettingsModule)
      ..module(tvInfoModule)
      ..module(tvPlayerModule);
  },
);
