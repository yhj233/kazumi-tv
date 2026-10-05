import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'tv_player_controls.dart';
import 'tv_episode_menu.dart';
import 'tv_progress_indicator.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/player/player_item_surface.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';
import 'package:kazumi/tv/core/focus/tv_key_handler.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';

/// TV 播放器主页面
///
/// 管理播放器状态、按键事件分发、控制面板和选集菜单显示
class TVPlayerPage extends StatefulWidget {
  const TVPlayerPage({super.key});

  @override
  State<TVPlayerPage> createState() => _TVPlayerPageState();
}

class _TVPlayerPageState extends State<TVPlayerPage> {
  final PlayerController playerController = Modular.get<PlayerController>();
  final VideoPageController videoPageController =
      Modular.get<VideoPageController>();
  final HistoryController _historyController = Modular.get<HistoryController>();
  final MyController _myController = Modular.get<MyController>();
  final FocusNode _pageFocusNode = FocusNode();
  final FocusNode _controlsFocusNode = FocusNode();
  final _danmuKey = GlobalKey();

  /// 每秒同步一次播放器状态 / 发射弹幕。
  /// 上游在 `player_item.dart` 的 `getPlayerTimer()` 里做同样的两件事。
  Timer? _playerStateTimer;

  late bool _border;
  late double _opacity;
  late double _fontSize;
  late double _danmakuArea;
  late bool _hideTop;
  late bool _hideBottom;
  late bool _hideScroll;
  late bool _massiveMode;
  late double _danmakuDuration;
  late double _danmakuLineHeight;
  late int _danmakuFontWeight;
  late bool _danmakuUseSystemFont;
  late double _danmakuBorderSize;
  late bool _danmakuColor;
  late bool _danmakuBiliBiliSource;
  late bool _danmakuGamerSource;
  late bool _danmakuDanDanSource;

  bool _isControlsVisible = false;
  Timer? _controlsHideTimer;
  bool _isEpisodeMenuOpen = false;
  ReactionDisposer? _completionReaction;

  bool _isSeeking = false;
  String _seekDirection = 'forward';
  Timer? _seekExecuteTimer;
  Timer? _seekAccumulateTimer;
  // Prevents double-pop from both key handler and system back gesture
  bool _isExiting = false;

  static const int _seekStep = 10;

  static const int _seekAccumulateInterval = 300;

  static const int _seekExecuteDelay = 500;

  static const int _controlsHideDelay = 10;

  @override
  void initState() {
    super.initState();
    _pageFocusNode.requestFocus();

    playerController.danmaku.danmakuOn =
        GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault);
    _border = GStorage.getSetting(SettingsKeys.danmakuBorder);
    _opacity = GStorage.getSetting(SettingsKeys.danmakuOpacity);
    _fontSize = GStorage.getSetting(SettingsKeys.danmakuFontSize);
    _danmakuArea = GStorage.getSetting(SettingsKeys.danmakuArea);
    _hideTop = !GStorage.getSetting(SettingsKeys.danmakuTop);
    _hideBottom = !GStorage.getSetting(SettingsKeys.danmakuBottom);
    _hideScroll = !GStorage.getSetting(SettingsKeys.danmakuScroll);
    _massiveMode = GStorage.getSetting(SettingsKeys.danmakuMassive);
    _danmakuDuration = GStorage.getSetting(SettingsKeys.danmakuDuration);
    _danmakuLineHeight = GStorage.getSetting(SettingsKeys.danmakuLineHeight);
    _danmakuFontWeight = GStorage.getSetting(SettingsKeys.danmakuFontWeight);
    _danmakuUseSystemFont =
        GStorage.getSetting(SettingsKeys.useSystemFont);
    _danmakuBorderSize = GStorage.getSetting(SettingsKeys.danmakuBorderSize);
    _danmakuColor = GStorage.getSetting(SettingsKeys.danmakuColor);
    _danmakuBiliBiliSource =
        GStorage.getSetting(SettingsKeys.danmakuBiliBiliSource);
    _danmakuGamerSource =
        GStorage.getSetting(SettingsKeys.danmakuGamerSource);
    _danmakuDanDanSource =
        GStorage.getSetting(SettingsKeys.danmakuDanDanSource);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startPlayback();
    });

    _completionReaction = reaction(
      (_) => playerController.playback.completed,
      (completed) {
        if (completed) {
          _autoPlayNextEpisode();
        }
      },
    );

    // 每秒驱动一次：同步播放进度/时长（进度条）并发射弹幕。
    // 缺了这一步会出现「进度条 0:00、无法拖动」和「弹幕不显示」。
    _playerStateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _syncPlayerStateAndDanmaku();
    });
  }

  /// 同步播放器状态 + 按当前播放位置发射弹幕。
  ///
  /// 对应上游 `player_item.dart` 的
  /// `getPlayerTimer()` → `syncPlaybackState()` + `_emitDanmakusForCurrentPosition()`。
  void _syncPlayerStateAndDanmaku() {
    try {
      // playback.duration / currentPosition 是 @observable 字段，
      // 只有这个调用会把 media_kit 的实时状态写进去。
      // TV 端原来从未调用过，所以总时长恒为 Duration.zero、seek 被 clamp 回 0。
      playerController.syncPlaybackState();
    } catch (e) {
      KazumiLogger().w('TVPlayerPage: failed to sync playback state', error: e);
    }
    _emitDanmakusForCurrentPosition();
  }

  bool _isDanmakuSourceEnabled(DanmakuEntry danmaku) {
    if (!_danmakuBiliBiliSource && danmaku.source.contains('BiliBili')) {
      return false;
    }
    if (!_danmakuGamerSource && danmaku.source.contains('Gamer')) {
      return false;
    }
    if (!_danmakuDanDanSource &&
        !(danmaku.source.contains('BiliBili') ||
            danmaku.source.contains('Gamer'))) {
      return false;
    }
    return true;
  }

  DanmakuItemType _danmakuItemType(DanmakuEntry danmaku) {
    if (danmaku.type == 4) {
      return DanmakuItemType.bottom;
    }
    if (danmaku.type == 5) {
      return DanmakuItemType.top;
    }
    return DanmakuItemType.scroll;
  }

  /// 把「当前播放秒数」对应的弹幕推到画布上。
  ///
  /// TV 端此前完全没有移植这段逻辑（`canvasController` 只被赋值、从没被写入），
  /// 所以即使弹幕数据拉取成功也不会显示。
  void _emitDanmakusForCurrentPosition() {
    if (playerController.playback.currentPosition.inMicroseconds == 0 ||
        playerController.playback.playerPlaying != true ||
        playerController.danmaku.danmakuOn != true) {
      return;
    }

    final List<DanmakuEntry> danmakus = playerController.danmaku
        .danmakusForPlaybackPosition(playerController.playback.currentPosition);
    final int danmakuCount = danmakus.length;
    for (final entry in danmakus.asMap().entries) {
      final int idx = entry.key;
      final DanmakuEntry danmaku = entry.value;
      if (!_isDanmakuSourceEnabled(danmaku)) {
        continue;
      }

      final Color color = _danmakuColor ? danmaku.color : Colors.white;
      final int delay = DanmakuTimeline.staggerDelayMilliseconds(
        index: idx,
        total: danmakuCount,
      );
      final int scheduledDanmakuGeneration =
          playerController.danmaku.scheduledDanmakuGeneration;
      Future.delayed(Duration(milliseconds: delay), () {
        if (!mounted ||
            !playerController.playback.playerPlaying ||
            playerController.playback.playerBuffering ||
            !playerController.danmaku.danmakuOn ||
            playerController.danmaku.scheduledDanmakuGeneration !=
                scheduledDanmakuGeneration ||
            _myController.isDanmakuBlocked(danmaku.message)) {
          return;
        }
        playerController.danmaku.canvasController.addDanmaku(
          DanmakuContentItem(
            danmaku.message,
            color: color,
            type: _danmakuItemType(danmaku),
          ),
        );
      });
    }
  }

  /// 开始播放。
  ///
  /// 与上游 `video_page._initOnlineMode()` 保持一致：
  /// 优先从观看历史恢复「上次看到第几集 / 第几个播放源 / 播放进度」。
  ///
  /// TV 版的 `VideoPageController` 是**根单例**（不随路由销毁），
  /// 所以必须先显式 `resetEpisodeState` 归零，否则会残留上一部番剧的集数。
  void _startPlayback() {
    final bool resume = GStorage.getSetting(SettingsKeys.playResume);
    videoPageController.historyOffset = 0;
    videoPageController.resetEpisodeState(episode: 1);

    if (!videoPageController.isOfflineMode &&
        videoPageController.roadList.isNotEmpty) {
      final progress = _historyController.lastWatching(
        videoPageController.bangumiItem,
        videoPageController.currentPlugin.name,
      );
      if (progress != null &&
          videoPageController.roadList.length > progress.road &&
          videoPageController.roadList[progress.road].data.length >=
              progress.episode) {
        videoPageController.resetEpisodeState(
          episode: progress.episode,
          road: progress.road,
        );
        if (resume) {
          videoPageController.historyOffset = progress.progress.inSeconds;
        }
        debugPrint(
          'TV: resume playback at road=${progress.road} episode=${progress.episode} offset=${videoPageController.historyOffset}',
        );
      }
    }

    videoPageController.changeEpisode(
      videoPageController.selectedEpisode.episode,
      currentRoad: videoPageController.selectedEpisode.road,
      offset: videoPageController.historyOffset,
      playerController: playerController,
    );
  }

  @override
  void dispose() {
    _playerStateTimer?.cancel();
    _playerStateTimer = null;
    _completionReaction?.call();
    _completionReaction = null;
    _controlsHideTimer?.cancel();
    _seekExecuteTimer?.cancel();
    _seekAccumulateTimer?.cancel();
    playerController.pause();
    _pageFocusNode.dispose();
    _controlsFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!(event is KeyDownEvent || event is KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }

    final logicalKey = event.logicalKey;

    if (_isEpisodeMenuOpen) {
      return KeyEventResult.ignored;
    }

    if (videoPageController.errorMessage != null) {
      if (logicalKey == LogicalKeyboardKey.select ||
          logicalKey == LogicalKeyboardKey.enter) {
        videoPageController.changeEpisode(
          videoPageController.selectedEpisode.episode,
          currentRoad: videoPageController.selectedEpisode.road,
          offset: 0,
          playerController: playerController,
        );
        return KeyEventResult.handled;
      }
      if (logicalKey == LogicalKeyboardKey.escape ||
          logicalKey == LogicalKeyboardKey.goBack) {
        _exitPlayer();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (_isControlsVisible) {
      if (logicalKey == LogicalKeyboardKey.escape ||
          logicalKey == LogicalKeyboardKey.goBack) {
        _hideControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return TvKeyHandler.handleNavigationWithRepeat(
      event,
      onSelect: () {
        _showControls();
        return KeyEventResult.handled;
      },
      onEnter: () {
        _showControls();
        return KeyEventResult.handled;
      },
      onUp: () {
        _showControls();
        return KeyEventResult.handled;
      },
      onDown: () {
        _showControls();
        return KeyEventResult.handled;
      },
      onLeft: () {
        _handleSeek('backward', event is KeyRepeatEvent);
        return KeyEventResult.handled;
      },
      onRight: () {
        _handleSeek('forward', event is KeyRepeatEvent);
        return KeyEventResult.handled;
      },
      onBack: () {
        _exitPlayer();
        return KeyEventResult.handled;
      },
    );
  }

  void _showControls() {
    setState(() {
      _isControlsVisible = true;
    });
    _startControlsHideTimer();
  }

  void _hideControls() {
    _controlsHideTimer?.cancel();
    setState(() {
      _isControlsVisible = false;
    });
  }

  void _startControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(
      Duration(seconds: _controlsHideDelay),
      () {
        if (!_isEpisodeMenuOpen) {
          _hideControls();
        }
      },
    );
  }

  void _handleSeek(String direction, bool isRepeat) {
    setState(() {
      _isSeeking = true;
      _seekDirection = direction;
    });

    if (isRepeat && _seekAccumulateTimer == null) {
      _doSeekStep();
      _seekAccumulateTimer = Timer.periodic(
        Duration(milliseconds: _seekAccumulateInterval),
        (_) => _doSeekStep(),
      );
    }

    _scheduleSeekStop();
  }

  void _scheduleSeekStop() {
    _seekExecuteTimer?.cancel();
    _seekExecuteTimer = Timer(
      Duration(milliseconds: _seekExecuteDelay),
      () {
        final wasContinuous = _seekAccumulateTimer != null;
        _seekAccumulateTimer?.cancel();
        _seekAccumulateTimer = null;

        if (!wasContinuous) {
          _doSeekStep();
        }

        setState(() {
          _isSeeking = false;
        });
      },
    );
  }

  void _doSeekStep() {
    final currentPosition = playerController.playback.playerPosition;
    // 用 playerDuration（实时读 media_kit 状态）而不是 @observable duration：
    // 后者依赖每秒一次的 syncPlaybackState，在首帧之前还是 zero，
    // 会导致「按前进反而跳回开头」。
    final duration = playerController.playback.playerDuration;
    final offset = Duration(seconds: _seekStep);

    Duration newPosition;
    if (_seekDirection == 'forward') {
      newPosition = currentPosition + offset;
      if (newPosition > duration) {
        newPosition = duration;
        KazumiDialog.showToast(message: '已在结尾');
      }
    } else {
      newPosition = currentPosition - offset;
      if (newPosition < Duration.zero) {
        newPosition = Duration.zero;
        KazumiDialog.showToast(message: '已在开头');
      }
    }

    playerController.seek(newPosition);
  }

  void _onPlayPause() {
    if (playerController.playback.playing) {
      playerController.pause();
    } else {
      playerController.play();
    }
    _startControlsHideTimer();
  }

  void _onChangeEpisode(int offset) {
    if (videoPageController.loading) return;

    final currentEpisode = videoPageController.selectedEpisode.episode;
    final roadList = videoPageController.roadList;
    final currentRoad = videoPageController.selectedEpisode.road;

    if (!videoPageController.roadList.isNotEmpty) {
      KazumiDialog.showToast(message: '播放列表加载中，请稍候');
      _startControlsHideTimer();
      return;
    }

    final totalEpisodes = roadList[currentRoad].identifier.length;
    final targetEpisode = currentEpisode + offset;

    if (targetEpisode <= 0) {
      KazumiDialog.showToast(message: '已经是第一集');
      _startControlsHideTimer();
      return;
    }
    if (targetEpisode > totalEpisodes) {
      KazumiDialog.showToast(message: '已经是最新一集');
      _startControlsHideTimer();
      return;
    }

    final identifier = roadList[currentRoad].identifier[targetEpisode - 1];
    KazumiDialog.showToast(message: '正在加载$identifier');
    videoPageController.changeEpisode(targetEpisode,
        currentRoad: currentRoad, playerController: playerController);
    _startControlsHideTimer();
  }

  void _onNextEpisode() => _onChangeEpisode(1);

  void _onPreviousEpisode() => _onChangeEpisode(-1);

  void _autoPlayNextEpisode() {
    if (videoPageController.loading) return;

    final roadList = videoPageController.roadList;
    final currentRoad = videoPageController.selectedEpisode.road;
    final currentEpisode = videoPageController.selectedEpisode.episode;

    if (!videoPageController.roadList.isNotEmpty) return;

    final totalEpisodes = roadList[currentRoad].identifier.length;
    final nextEpisode = currentEpisode + 1;

    if (nextEpisode > totalEpisodes) {
      KazumiDialog.showToast(message: '已经是最新一集');
      return;
    }

    final identifier = roadList[currentRoad].identifier[nextEpisode - 1];
    KazumiDialog.showToast(message: '正在加载$identifier');
    videoPageController.changeEpisode(nextEpisode,
        currentRoad: currentRoad, playerController: playerController);
  }

  void _onDanmakuToggle() {
    try {
      playerController.danmaku.canvasController.clear();
    } catch (e) {
      KazumiLogger().w('TVPlayerPage: failed to clear danmaku', error: e);
    }
    playerController.danmaku.danmakuOn =
        !playerController.danmaku.danmakuOn;
    _startControlsHideTimer();
  }

  void _openEpisodeMenu() {
    _controlsHideTimer?.cancel();
    setState(() {
      _isEpisodeMenuOpen = true;
      _isControlsVisible = false;
    });
  }

  void _closeEpisodeMenu() {
    setState(() {
      _isEpisodeMenuOpen = false;
    });
  }

  void _onEpisodeSelected(int episode) {
    videoPageController.changeEpisode(episode,
        playerController: playerController);
    _closeEpisodeMenu();
  }

  void _exitPlayer() {
    if (_isExiting) return;
    _isExiting = true;
    playerController.pause();
    Modular.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _exitPlayer();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
        focusNode: _pageFocusNode,
        onKeyEvent: _handleKeyEvent,
        child: Stack(
          children: [
            Center(
              child: PlayerItemSurface(playerController: playerController),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              child: DanmakuScreen(
                key: _danmuKey,
                createdController: (DanmakuController e) {
                  playerController.danmaku.canvasController = e;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    playerController.updateDanmakuSpeed();
                  });
                },
                option: DanmakuOption(
                  hideTop: _hideTop,
                  hideScroll: _hideScroll,
                  hideBottom: _hideBottom,
                  area: _danmakuArea,
                  opacity: _opacity,
                  fontSize: _fontSize,
                  duration: _danmakuDuration / playerController.playback.playerSpeed,
                  lineHeight: _danmakuLineHeight,
                  strokeWidth: _border ? _danmakuBorderSize : 0.0,
                  fontWeight: _danmakuFontWeight,
                  massiveMode: _massiveMode,
                  fontFamily:
                      _danmakuUseSystemFont ? null : customAppFontFamily,
                ),
              ),
            ),
            Observer(
              builder: (_) {
                final errorMsg = videoPageController.errorMessage;
                if (errorMsg == null) return const SizedBox.shrink();
                return Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          errorMsg,
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '按确认键重试',
                          style: TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            TVProgressIndicator(
              isVisible: _isSeeking,
              direction: _seekDirection,
              amount: _seekStep,
            ),
            TVPlayerControls(
              isVisible: _isControlsVisible,
              focusNode: _controlsFocusNode,
              playerController: playerController,
              videoPageController: videoPageController,
              onPlayPause: _onPlayPause,
              onPreviousEpisode: _onPreviousEpisode,
              onNextEpisode: _onNextEpisode,
              onDanmakuToggle: _onDanmakuToggle,
              onEpisodeMenuOpen: _openEpisodeMenu,
              onHide: _hideControls,
              danmakuColor: _danmakuColor,
              danmakuBiliBiliSource: _danmakuBiliBiliSource,
              danmakuGamerSource: _danmakuGamerSource,
              danmakuDanDanSource: _danmakuDanDanSource,
            ),
            TVEpisodeMenu(
              isOpen: _isEpisodeMenuOpen,
              videoPageController: videoPageController,
              onEpisodeSelected: _onEpisodeSelected,
              onClose: _closeEpisodeMenu,
            ),
          ],
        ),
      ),
    ),
  );
  }
}
