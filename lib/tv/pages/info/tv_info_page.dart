import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'widgets/tv_info_left_panel.dart';
import 'widgets/tv_search_result_section.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/tv/core/focus/tv_key_handler.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';

class TVInfoPage extends StatefulWidget {
  final BangumiItem bangumiItem;

  const TVInfoPage({
    super.key,
    required this.bangumiItem,
  });

  @override
  State<TVInfoPage> createState() => _TVInfoPageState();
}

class _TVInfoPageState extends State<TVInfoPage> with TickerProviderStateMixin {
  late InfoController _infoController;
  late VideoPageController _videoPageController;
  late PluginSearchService _queryManager;

  final ScrollController _leftPanelScrollController = ScrollController();
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'info_page');
  final FocusNode _collectFocusNode = FocusNode(debugLabel: 'collect_btn');
  FocusNode? _rightPanelFirstFocusNode;
  bool _firstFocusNodeSet = false;

  static const double _scrollStep = 100.0;

  bool _searchCompleted = false;

  @override
  void initState() {
    super.initState();
    debugPrint('TV: TVInfoPage.initState, bangumiItem=${widget.bangumiItem.id}');

    _infoController = Modular.get<InfoController>();
    _infoController.bangumiItem = widget.bangumiItem;
    _infoController.characterList.clear();
    _infoController.commentsList.clear();
    _infoController.staffList.clear();
    _infoController.pluginSearchResponseList.clear();
    _videoPageController = Modular.get<VideoPageController>();
    _videoPageController.resetEpisodeState(episode: 1);

    if (_infoController.bangumiItem.summary == '' ||
        _infoController.bangumiItem.votesCount.isEmpty) {
      _queryBangumiInfoByID(_infoController.bangumiItem.id, type: 'attach');
    }

    final keyword = widget.bangumiItem.nameCn.isNotEmpty
        ? widget.bangumiItem.nameCn
        : widget.bangumiItem.name;
    _queryManager = PluginSearchService(
      infoController: _infoController,
      pluginsController: Modular.get<PluginsController>(),
    );

    _queryManager.queryAllSource(keyword);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _collectFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _infoController.characterList.clear();
    _infoController.commentsList.clear();
    _infoController.staffList.clear();
    _infoController.pluginSearchResponseList.clear();
    _videoPageController.resetEpisodeState(episode: 1);
    _queryManager.cancel();
    _leftPanelScrollController.dispose();
    _collectFocusNode.dispose();
    _pageFocusNode.dispose();
    super.dispose();
  }

  Future<void> _queryBangumiInfoByID(int id, {String type = 'init'}) async {
    try {
      await _infoController.queryBangumiInfoByID(id, type: type);
      setState(() {});
    } catch (e) {
      KazumiLogger()
          .e('TVInfoPage: failed to query bangumi info by ID', error: e);
    }
  }

  void _scrollLeftPanel(double offset) {
    if (!_leftPanelScrollController.hasClients) return;
    final maxScroll = _leftPanelScrollController.position.maxScrollExtent;
    final current = _leftPanelScrollController.offset;
    final target = (current + offset).clamp(0.0, maxScroll);
    _leftPanelScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _moveFocusToRightPanel() {
    if (_rightPanelFirstFocusNode != null) {
      _rightPanelFirstFocusNode!.requestFocus();
    }
  }

  void _onFirstFocusNodeReady(FocusNode node) {
    if (!_firstFocusNodeSet) {
      _rightPanelFirstFocusNode = node;
      _firstFocusNodeSet = true;
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    return TvKeyHandler.handleNavigation(
      event,
      onBack: () {
        Modular.pop();
        return KeyEventResult.handled;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _pageFocusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Observer(
          builder: (_) {
            if (!_searchCompleted &&
                _infoController.pluginSearchResponseList.isNotEmpty) {
              _searchCompleted = true;
            }

            return Row(
              children: [
                SizedBox(
                  width: screenWidth * 0.4,
                  child: SingleChildScrollView(
                    controller: _leftPanelScrollController,
                    child: TVInfoLeftPanel(
                      bangumiItem: _infoController.bangumiItem,
                      collectFocusNode: _collectFocusNode,
                      onExitRight: _moveFocusToRightPanel,
                      onExitUp: () => _scrollLeftPanel(-_scrollStep),
                      onExitDown: () => _scrollLeftPanel(_scrollStep),
                    ),
                  ),
                ),
                Expanded(
                  child: TVSearchResultSection(
                    infoController: _infoController,
                    onPlayResult: _playSearchResult,
                    exitLeftFocusNode: _collectFocusNode,
                    onFirstFocusNodeReady: _onFirstFocusNodeReady,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _playSearchResult(String src, Plugin plugin) async {
    if (!mounted) return;

    KazumiDialog.showLoading(
      context: context,
      msg: '正在获取播放列表',
      barrierDismissible: false,
      onDismiss: () {},
    );

    final RuleCancelToken cancelToken = RuleCancelToken();

    try {
      // 关键一步：必须先用插件规则把「搜索结果详情页」解析成**剧集列表**。
      // 缺少这一步 roadList 是空的，changeEpisode 会立刻报「集数解析失败」，
      // 而且不会发出任何网络请求（日志里能看到这个特征）。
      final roads = await plugin.queryChapterRoads(
        src,
        cancelToken: cancelToken,
      );

      if (!mounted) return;

      if (roads.isEmpty) {
        KazumiDialog.dismiss();
        KazumiDialog.showToast(
          message: '未能获取播放列表，请重试或选择其他结果',
          context: context,
        );
        return;
      }

      String title = widget.bangumiItem.nameCn.isNotEmpty
          ? widget.bangumiItem.nameCn
          : widget.bangumiItem.name;

      for (var response in _infoController.pluginSearchResponseList) {
        if (response.pluginName == plugin.name) {
          for (var searchItem in response.data) {
            if (searchItem.src == src) {
              title = searchItem.name;
              break;
            }
          }
          break;
        }
      }

      // 与上游 `video_page` 保持一致：先把参数（含 roadList）写进 controller，
      // 再由 `TVPlayerPage.initState` 调用 changeEpisode 开始播放。
      // 之前这里直接调 changeEpisode，既漏了 roads，又会和播放器重复触发一次。
      _videoPageController.applyPlaybackArgs(
        OnlineVideoPlaybackArgs(
          bangumiItem: widget.bangumiItem,
          plugin: plugin,
          title: title,
          src: src,
          roads: roads,
        ),
      );

      KazumiDialog.dismiss();
      Modular.pushNamed('/player');
    } catch (e) {
      if (!mounted) return;
      KazumiLogger()
          .w('TVInfoPage: failed to query video playlist', error: e);
      KazumiDialog.dismiss();
      KazumiDialog.showToast(message: '播放失败，请重试', context: context);
    }
  }
}
