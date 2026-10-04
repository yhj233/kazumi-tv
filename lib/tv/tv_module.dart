import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/tv/pages/settings/tv_settings_module.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'pages/collect/tv_collect_module.dart';
import 'pages/info/tv_info_module.dart';
import 'pages/main/tv_main_module.dart';
import 'pages/player/tv_player_module.dart';
import 'pages/popular/tv_popular_module.dart';
import 'pages/search/tv_search_module.dart';
import 'pages/timeline/tv_timeline_module.dart';

class TVModule extends Module {
  @override
  void register(ModularContext c) {
    c.addSingleton<ICollectRepository>(CollectRepository.new);
    c.addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new);
    c.addSingleton<ICollectCrudRepository>(CollectCrudRepository.new);
    c.addSingleton<IHistoryRepository>(HistoryRepository.new);
    c.addSingleton<IDownloadRepository>(DownloadRepository.new);
    c.addSingleton<IDownloadManager>(DownloadManager.new);
    c.addSingleton<IDanmakuShieldRepository>(DanmakuShieldRepository.new);

    c.addSingleton(PopularController.new);
    c.addSingleton(PluginsController.new);
    c.addSingleton(
      (i) => VideoPageController(
        i.get<HistoryController>(),
        i.get<IDownloadRepository>(),
        i.get<IDownloadManager>(),
      ),
    );
    c.addSingleton((i) => TimelineController(i.get<ICollectRepository>()));
    c.addSingleton((i) => CollectController(i.get<ICollectCrudRepository>()));
    c.addSingleton((i) => HistoryController(i.get<IHistoryRepository>()));
    c.addSingleton(
      (i) => MyController(
        i.get<IHistoryRepository>(),
        i.get<IDownloadRepository>(),
        i.get<IDanmakuShieldRepository>(),
      ),
    );
    c.addSingleton(ShaderAssetService.new);
    c.addSingleton(
      (i) => DownloadController(
        i.get<IDownloadRepository>(),
        i.get<IDownloadManager>(),
        i.get<PluginsController>(),
      ),
    );
    c.addSingleton((i) => InfoController(i.get<CollectController>()));

    c.module("/", module: TVMainModule());
    c.module("/popular", module: TVPopularModule());
    c.module("/timeline", module: TVTimelineModule());
    c.module("/collect", module: TVCollectModule());
    c.module("/search", module: TVSearchModule());
    c.module("/settings", module: TVSettingsModule());
    c.module("/info", module: TVInfoModule());
    c.module("/player", module: TVPlayerModule());
  }
}
