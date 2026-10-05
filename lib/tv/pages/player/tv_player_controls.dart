import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'widgets/tv_player_button.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import '../../core/utils/tv_constants.dart';

/// TV 播放器控制面板
///
/// 底部控制栏，包含播放/暂停、上一集、下一集、弹幕开关、选集按钮和进度条
class TVPlayerControls extends StatefulWidget {
  const TVPlayerControls({
    super.key,
    required this.isVisible,
    this.focusNode,
    required this.playerController,
    required this.videoPageController,
    required this.onPlayPause,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onDanmakuToggle,
    required this.onEpisodeMenuOpen,
    required this.onHide,
    this.danmakuColor = true,
    this.danmakuBiliBiliSource = true,
    this.danmakuGamerSource = true,
    this.danmakuDanDanSource = true,
  });

  final bool isVisible;
  final FocusNode? focusNode;
  final PlayerController playerController;
  final VideoPageController videoPageController;
  final VoidCallback onPlayPause;
  final VoidCallback onPreviousEpisode;
  final VoidCallback onNextEpisode;
  final VoidCallback onDanmakuToggle;
  final VoidCallback onEpisodeMenuOpen;
  final VoidCallback onHide;
  final bool danmakuColor;
  final bool danmakuBiliBiliSource;
  final bool danmakuGamerSource;
  final bool danmakuDanDanSource;

  @override
  State<TVPlayerControls> createState() => _TVPlayerControlsState();
}

class _TVPlayerControlsState extends State<TVPlayerControls>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  late FocusNode _controlsFocusNode;
  bool _ownsFocusNode = false;

  final FocusNode _playButtonFocusNode = FocusNode();
  Timer? _playerStateTimer;
  int? _lastDanmakuSecond;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    ));

    if (widget.focusNode != null) {
      _controlsFocusNode = widget.focusNode!;
      _ownsFocusNode = false;
    } else {
      _controlsFocusNode = FocusNode();
      _ownsFocusNode = true;
    }

    _playerStateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      try {
        final currentPosition = widget.playerController.playback.playerPosition;
        final currentSecond = currentPosition.inSeconds;
        if (widget.playerController.playback.playing == true &&
            widget.playerController.danmaku.danmakuOn == true &&
            currentSecond != _lastDanmakuSecond) {
          _lastDanmakuSecond = currentSecond;
        }
      } catch (e) {
        KazumiLogger().w('TVPlayerControls: state sync error', error: e);
      }
    });
  }

  @override
  void didUpdateWidget(TVPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible && !oldWidget.isVisible) {
      _controller.forward();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _playButtonFocusNode.requestFocus();
      });
    } else if (!widget.isVisible && oldWidget.isVisible) {
      _controller.reverse();
    }

    if (widget.focusNode != oldWidget.focusNode) {
      if (_ownsFocusNode) {
        _controlsFocusNode.dispose();
      }
      if (widget.focusNode != null) {
        _controlsFocusNode = widget.focusNode!;
        _ownsFocusNode = false;
      } else {
        _controlsFocusNode = FocusNode();
        _ownsFocusNode = true;
      }
    }
  }

  @override
  void dispose() {
    _playerStateTimer?.cancel();
    _controller.dispose();
    _playButtonFocusNode.dispose();
    if (_ownsFocusNode) {
      _controlsFocusNode.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.goBack ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        widget.onHide();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible && _controller.status == AnimationStatus.dismissed) {
      return const SizedBox.shrink();
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final controlsHeight = 100.0;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Focus(
          focusNode: _controlsFocusNode,
          onKeyEvent: _handleKeyEvent,
          child: Container(
            width: screenWidth,
            height: controlsHeight,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.85),
                ],
              ),
            ),
            child: Column(
              children: [
                Container(
                  height: 60,
                  padding: const EdgeInsets.only(left: 24),
                  child: Row(
                    children: _buildButtons(),
                  ),
                ),
                Observer(
                  builder: (_) => Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ProgressBar(
                      progress: widget.playerController.playback.playerPosition,
                      // 实时 getter：@observable duration 只有 syncPlaybackState()
                      // 才会更新，用错会一直显示 0:00
                      total: widget.playerController.playback.playerDuration,
                      progressBarColor: TVConstants.focusColor,
                      baseBarColor: Colors.white24,
                      thumbColor: TVConstants.focusColor,
                      thumbRadius: 8,
                      barHeight: 4,
                      timeLabelTextStyle: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      onSeek: (position) {
                        widget.playerController.seek(position);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildButtons() {
    final buttons = <Widget>[];
    final currentEpisode = widget.videoPageController.selectedEpisode.episode;

    bool showPrevious = false;
    bool showNext = false;

    if (widget.videoPageController.roadList.isNotEmpty) {
      final roadList = widget.videoPageController.roadList;
      final currentRoad = widget.videoPageController.selectedEpisode.road;
      final totalEpisodes = roadList[currentRoad].identifier.length;
      showPrevious = currentEpisode > 1;
      showNext = currentEpisode < totalEpisodes;
    }

    if (showPrevious) {
      buttons.add(
        TVPlayerButton(
          icon: Icons.skip_previous,
          onTap: widget.onPreviousEpisode,
          autofocus: false,
        ),
      );
      buttons.add(const SizedBox(width: 16));
    }

    buttons.add(
      Observer(
        builder: (_) => TVPlayerButton(
          icon: widget.playerController.playback.playing
              ? Icons.pause
              : Icons.play_arrow,
          onTap: widget.onPlayPause,
          focusNode: _playButtonFocusNode,
          autofocus: true,
        ),
      ),
    );
    buttons.add(const SizedBox(width: 16));

    if (showNext) {
      buttons.add(
        TVPlayerButton(
          icon: Icons.skip_next,
          onTap: widget.onNextEpisode,
          autofocus: false,
        ),
      );
      buttons.add(const SizedBox(width: 16));
    }

    buttons.add(
      Observer(
        builder: (_) => TVPlayerButton(
          icon: widget.playerController.danmaku.danmakuOn
              ? Icons.comment
              : Icons.comments_disabled,
          onTap: widget.onDanmakuToggle,
          autofocus: false,
        ),
      ),
    );
    buttons.add(const SizedBox(width: 16));

    buttons.add(
      TVPlayerButton(
        icon: Icons.list,
        onTap: widget.onEpisodeMenuOpen,
        autofocus: false,
        onRight: () {},
      ),
    );

    return buttons;
  }
}
