// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/player/playback_cache_policy.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

final class _OwnedPlayer {
  _OwnedPlayer(this.player);

  final Player player;
  Future<void>? _disposeFuture;

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerPlaybackController: failed to dispose media player',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.isLocalPlayback,
  });

  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final bool Function() isLocalPlayback;
  late final PlaybackCachePolicy cachePolicy = PlaybackCachePolicy(
    isLocalPlayback: isLocalPlayback,
    currentPlayer: () => mediaPlayer,
  );

  _OwnedPlayer? _ownedPlayer;
  Player? get mediaPlayer => _ownedPlayer?.player;
  VideoController? videoController;

  final AsyncSerialQueue _prefetchWrites = AsyncSerialQueue();
  bool _prefetchSuspendWanted = false;

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 历史记录传入的 offset
  int startOffset = 0;

  /// 起播看门狗相关状态（见 [_startStartupWatchdog]）。
  Timer? _startupWatchdog;
  bool _startupRecoveryDone = false;

  /// 本次会话是否已经试过「切软解重开」。
  bool _softDecodeRetried = false;

  /// 本次会话是否已经试过「绕过 media_kit 的临时播放列表文件，直接 loadfile」。
  ///
  /// media_kit 的 `Player.open` 会把 URL 写进 `files/<uuid>` 再让 mpv
  /// `loadlist`，并在 5 秒后删除该文件。实机（安卓 9 盒子）上出现过
  /// 「`open` 正常返回、界面进入播放中，但 mpv 的 opener 线程从未运行、
  /// 也没有 demux 线程」＝ 播放列表里根本没有可用条目。此时改用 `loadfile`
  /// 直接投喂 URL 是唯一能绕开这条链路的办法。
  bool _directLoadRetried = false;

  /// 已上报过的 mpv 错误文本，避免同一错误重复弹提示。
  final Set<String> _reportedPlayerErrors = <String>{};

  /// 最近一次打开使用的请求头，自动恢复重开时需要复用。
  Map<String, String> _lastHttpHeaders = const {};

  /// 起播长时间无进展时的兜底回调，由页面注入（重新解析视频源）。
  ///
  /// 直链来自 CDN 的签名地址，每次解析可能落到不同边缘节点；播放阶段卡死时
  /// 重新解析往往比原样重试更有效。
  Future<void> Function()? onPlaybackStartupStalled;

  /// media_kit 的 [Player.open] 只保证 `loadfile` 命令被接受，**不代表起播成功**。
  /// 直链被 CDN 拒绝、或解码器初始化失败时，mpv 会安静地停在「已加载、无画面」
  /// 状态，界面只会一直转圈，且不产生任何错误事件（历史问题）。
  ///
  /// 分两个阶段校验：
  /// - [startupDemuxTimeout] 内 `duration` 仍为 0 → 解复用无数据（多为网络/直链）
  /// - 已解复出但 [startupDecodeTimeout] 内仍无画面 → 解码链未能启动
  ///
  /// 阈值取得偏宽松：本机（2 GB 盒子）实测「硬解失败 → mpv 回退软解 → 出首帧」
  /// 需要约 11 秒，若过短会把「慢但能成功」的起播误判为卡死。
  static const Duration startupDemuxTimeout = Duration(seconds: 18);
  static const Duration startupDecodeTimeout = Duration(seconds: 28);
  static const Duration _startupWatchdogInterval = Duration(seconds: 1);

  /// 当前超分辨率模式
  @observable
  SuperResolutionMode superResolutionMode = SuperResolutionMode.off;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(_OwnedPlayer candidate) async {
    if (identical(_ownedPlayer, candidate)) {
      return candidate.player;
    }
    await candidate.dispose();
    return null;
  }

  Future<void> _cancelDebugInfo() async {
    try {
      await debug.cancel();
    } catch (_) {}
  }

  void _stopStartupWatchdog() {
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
  }

  /// mpv 错误的统一出口：去重 → 映射为可读提示 → 弹提示。
  ///
  /// 过去只有在 [PlayerErrorMapper] 命中时才会提示，而它不识别
  /// `Could not open codec.` 这类解码初始化失败，`showPlayerError` 又默认关闭，
  /// 于是播放失败在界面上完全静默（用户只看到一直转圈）。
  void _handlePlayerError(String text, {required bool showRawWhenUnmapped}) {
    if (text.isEmpty) {
      return;
    }
    final bool firstTime = _reportedPlayerErrors.add(text);
    if (!firstTime) {
      return;
    }
    final actionableMessage = PlayerErrorMapper.toActionableMessage(
      text,
      isBuffering: playerBuffering,
    );
    if (actionableMessage != null) {
      KazumiDialog.showToast(
          message: actionableMessage, showActionButton: true);
    } else if (showRawWhenUnmapped) {
      KazumiDialog.showToast(
        message: '播放器内部错误 $text ${videoUrl()}',
        duration: const Duration(seconds: 5),
        showActionButton: true,
      );
    }
  }

  /// 打开媒体后启动看门狗，确认「真的出画面」而不是「命令被接受」。
  void _startStartupWatchdog(Player player) {
    _stopStartupWatchdog();
    final startedAt = DateTime.now();
    _startupWatchdog = Timer.periodic(_startupWatchdogInterval, (timer) {
      if (!isCurrentPlayer(player)) {
        timer.cancel();
        _startupWatchdog = null;
        return;
      }
      final state = player.state;
      final bool hasPicture =
          (state.width ?? 0) > 0 || state.position > Duration.zero;
      if (hasPicture) {
        timer.cancel();
        _startupWatchdog = null;
        if (DateTime.now().difference(startedAt) >
            const Duration(seconds: 3)) {
          KazumiLogger().i(
              'PlayerController: 起播完成 ${DateTime.now().difference(startedAt).inMilliseconds}ms');
        }
        return;
      }
      final elapsed = DateTime.now().difference(startedAt);
      final bool demuxed = state.duration > Duration.zero;
      if (!demuxed && elapsed >= startupDemuxTimeout) {
        timer.cancel();
        _startupWatchdog = null;
        // 解复用阶段毫无数据：问题在直链/CDN 侧，换软解没有意义，直接请页面重解析。
        unawaited(_recoverFromStartupStall(player,
            reason: '解复用无数据 (duration=0, ${elapsed.inSeconds}s)',
            decodeStall: false));
        return;
      }
      if (demuxed && elapsed >= startupDecodeTimeout) {
        timer.cancel();
        _startupWatchdog = null;
        unawaited(_recoverFromStartupStall(player,
            reason:
                '解码无画面 (duration=${state.duration.inSeconds}s, width=${state.width}, ${elapsed.inSeconds}s)',
            decodeStall: true));
      }
    });
  }

  /// 直接问 mpv「你看到了什么」。
  ///
  /// media_kit 只把 `file` / `ffmpeg`(须以 `tcp:` 开头) / `vd` / `ad` /
  /// `cplayer` / `stream` 这 6 种日志转成错误事件，`[ffmpeg/video]` 这类
  /// 解码错误完全落在盲区；而 `Player.open` 返回只代表命令被接受。
  /// 出问题时单看 Dart 侧状态（duration/width 全是 0）无法区分
  /// 「播放列表为空」「解码器起不来」「CDN 拒绝直链」。
  ///
  /// `print-text` 会做属性展开，输出走 mpv 的 info 级日志 → 被媒体的日志流
  /// 收到（见 `player.stream.log` 的 KAZUMI-DIAG 分支），因此在真机上能
  /// 直接把 mpv 的内部状态写进 logcat。
  Future<void> _dumpMpvDiagnostics(Player player, String tag) async {
    if (!isCurrentPlayer(player)) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      await pp.command([
        'print-text',
        'KAZUMI-DIAG[$tag] '
            r'idle-active=${idle-active} '
            r'playlist-pos=${playlist-pos} '
            r'playlist-count=${playlist-count} '
            r'pause=${pause} '
            r'duration=${duration} '
            r'width=${width} '
            r'vo=${vo} '
            r'vid=${vid} '
            r'path=${path}',
      ]);
    } catch (e) {
      KazumiLogger().w('PlayerController: mpv 诊断输出失败', error: e);
    }
  }

  /// 起播卡死后的自动恢复阶梯，最后必须给出可见反馈（不再静默转圈）。
  ///
  /// - 解码链卡住 → 先就地切软解重开（本机 MediaCodec 初始化失败的常见后果）
  /// - 仍无进展 / 解复用就取不到数据 → 交回页面重新解析视频源
  Future<void> _recoverFromStartupStall(
    Player player, {
    required String reason,
    required bool decodeStall,
  }) async {
    if (_startupRecoveryDone) {
      return;
    }
    _startupRecoveryDone = true;
    KazumiLogger().e(
        'PlayerController: 起播无进展，开始自动恢复 | $reason | url=${videoUrl()}');
    if (!isCurrentPlayer(player)) {
      return;
    }
    // 卡死瞬间再问一次 mpv 的内部状态（同样不 await）。
    unawaited(_dumpMpvDiagnostics(player, 'stalled'));

    // 阶段零：解复用阶段完全没有数据 —— 先绕过 media_kit 的临时播放列表文件，
    // 直接让 mpv `loadfile`。实机（安卓 9 盒子）复现到的情况是：`open` 正常返回、
    // 界面进入播放中，但 mpv 的 `opener` 线程累计 CPU 恒为 0、也不存在 `demux`
    // 线程，即「播放列表里没有任何可用条目」。此时再重开同一条路径没有意义。
    //
    // 请求头不受影响：media_kit 的 `on_load` 钩子是用 URI 回查 `Media` 的静态
    // 请求头表（见 media_kit real.dart 的 MPV_EVENT_HOOK 分支），与加载方式无关。
    if (!decodeStall && !_directLoadRetried) {
      _directLoadRetried = true;
      final uri = videoUrl();
      if (uri.isNotEmpty) {
        try {
          final pp = player.platform as NativePlayer;
          await pp.command(['loadfile', uri]);
          if (!isCurrentPlayer(player)) {
            return;
          }
          await pp.command(['set', 'pause', 'no']);
          KazumiLogger().i(
              'PlayerController: 已改用 loadfile 直接打开媒体（绕过播放列表文件）');
          // 允许这一次重开后的第二轮看门狗继续升级到「重新解析视频源」。
          _startupRecoveryDone = false;
          _startStartupWatchdog(player);
          return;
        } catch (e) {
          KazumiLogger().w('PlayerController: loadfile 直开失败', error: e);
        }
      }
    }

    // 阶段一：切换为软解后重开。
    // 本机实测 MediaCodec 初始化失败（surface/native_window 为 NULL、P010 输出
    // 不受支持）后 mpv 可能长时间没有任何输出，软解是唯一能出画面的路径。
    if (decodeStall && !_softDecodeRetried) {
      _softDecodeRetried = true;
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('hwdec', 'no');
        if (!isCurrentPlayer(player)) {
          return;
        }
        KazumiLogger().i('PlayerController: 已切换为软解并重新打开');
        await player.open(
          Media(videoUrl(),
              start: Duration(seconds: startOffset),
              httpHeaders: _lastHttpHeaders),
          play: autoPlay,
        );
        if (!isCurrentPlayer(player)) {
          return;
        }
        // 允许这一次重开后的第二轮看门狗继续升级到「重新解析视频源」。
        _startupRecoveryDone = false;
        _startStartupWatchdog(player);
        return;
      } catch (e) {
        KazumiLogger().w('PlayerController: 软解重开失败', error: e);
      }
    }

    // 阶段二：交回页面重新解析视频源（换边缘节点 / 换签名直链）。
    // 页面在重试次数用尽时会直接切到「暂时无法播放」错误界面。
    final retry = onPlaybackStartupStalled;
    if (retry != null && isCurrentPlayer(player)) {
      try {
        await retry();
        return;
      } catch (e) {
        KazumiLogger().w('PlayerController: 重新解析视频源失败', error: e);
      }
    }

    // 阶段三：没有页面兜底时至少把失败暴露出来，避免无限转圈。
    loading = false;
    KazumiDialog.showToast(
      message: '播放卡住：已自动重试仍无画面，请更换其他视频来源',
      duration: const Duration(seconds: 6),
      showActionButton: true,
    );
  }

  @action
  void resetForInit() {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    startOffset = 0;
  }

  /// 本次会话是否从距结尾 [nearEndWatchedThreshold] 以内的位置起播。
  /// 这样的"播放完成"并非真正看完，应从头重播而非切下一集
  bool get resumedNearEnd {
    if (startOffset <= 0 || duration <= Duration.zero) {
      return false;
    }
    return Duration(seconds: startOffset) >= duration - nearEndWatchedThreshold;
  }

  /// 从头重播当前视频。[startOffset] 在重播落地后才归零，
  /// 避免自动连播在此期间抢先触发
  Future<void> restartFromBeginning() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.seek(Duration.zero);
      if (!isCurrentPlayer(player)) {
        return;
      }
      await player.play();
      startOffset = 0;
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to restart from beginning', error: e);
    }
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  /// Android blocks network access for backgrounded apps; a prefetching
  /// demuxer then burns through ffmpeg's reconnect/segment retries and marks
  /// the stream EOF, leaving playback permanently stuck once foregrounded.
  /// Suspending zeroes the readahead window so no new requests are issued
  /// while buffered data stays available; restore values are mpv defaults,
  /// which media_kit leaves untouched. Writes are serialized and apply the
  /// latest requested state, so rapid lifecycle flips cannot reorder.
  Future<void> setPrefetchSuspended(bool suspended) async {
    if (!Platform.isAndroid) {
      return;
    }
    _prefetchSuspendWanted = suspended;
    await _prefetchWrites.run(() async {
      final wanted = _prefetchSuspendWanted;
      final player = mediaPlayer;
      if (player == null) {
        return;
      }
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('cache-secs', wanted ? '0' : '36000');
        if (!isCurrentPlayer(player)) {
          return;
        }
        await pp.setProperty('demuxer-readahead-secs', wanted ? '0' : '1');
      } catch (e) {
        KazumiLogger().w(
          'PlayerController: failed to ${wanted ? 'suspend' : 'resume'} demuxer prefetch',
          error: e,
        );
      }
    });
  }

  Future<Player?> createVideoController(
    Map<String, String> httpHeaders,
    bool adBlockerEnabled, {
    required bool Function() canInstall,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
  }) async {
    startOffset = offset;
    _lastHttpHeaders = httpHeaders;
    _startupRecoveryDone = false;
    _softDecodeRetried = false;
    _directLoadRetried = false;
    _reportedPlayerErrors.clear();
    _stopStartupWatchdog();
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultSuperResolutionMode),
    );
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting(SettingsKeys.androidEnableOpenSLES);
    hardwareDecoder = GStorage.getSetting(SettingsKeys.hardwareDecoder);
    autoPlay = GStorage.getSetting(SettingsKeys.autoPlay);
    playerDebugMode = GStorage.getSetting(SettingsKeys.playerDebugMode);

    if (!canInstall()) {
      return null;
    }
    final candidate = _OwnedPlayer(
      Player(
        configuration: PlayerConfiguration(
          bufferSize: cachePolicy.bufferSize,
          osc: false,
          logLevel: MPVLogLevel.values[debug.playerLogLevel],
          adBlocker: adBlockerEnabled,
        ),
      ),
    );
    final player = candidate.player;
    if (!canInstall()) {
      await candidate.dispose();
      return null;
    }
    _ownedPlayer = candidate;
    cachePolicy.startWatching();

    try {
      debug.playerLog.clear();
      await debug.setup(
        player,
        isCurrentPlayer: isCurrentPlayer,
        playerDebugMode: playerDebugMode,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      var pp = player.platform as NativePlayer;
      // media-kit 默认启用硬盘作为双重缓存，这可以维持大缓存的前提下减轻内存压力
      // media-kit 内部硬盘缓存目录按照 Linux 配置，这导致该功能在其他平台上被损坏
      // 该设置可以在所有平台上正确启用双重缓存
      await pp.setProperty("demuxer-cache-dir", await getPlayerTempPath());
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await cachePolicy.apply();
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await pp.setProperty("af", "scaletempo2=max-speed=8");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      if (Platform.isAndroid) {
        await pp.setProperty("volume-max", "100");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
        if (androidEnableOpenSLES) {
          await pp.setProperty("ao", "opensles");
        } else {
          await pp.setProperty("ao", "audiotrack");
        }
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
      if (proxyEnable) {
        final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
        final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
        if (formattedProxy != null) {
          await pp.setProperty("http-proxy", formattedProxy);
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
        }
      } else if (SystemProxyService.isActive) {
        final proxy = SystemProxyService.proxyFor('https');
        if (proxy != null) {
          await pp.setProperty("http-proxy", 'http://${proxy.$1}:${proxy.$2}');
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: 跟随系统代理 http://${proxy.$1}:${proxy.$2}');
        }
      }

      await player.setAudioTrack(
        AudioTrack.auto(),
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      String? videoRenderer;
      if (Platform.isAndroid) {
        final String androidVideoRenderer =
            GStorage.getSetting(SettingsKeys.androidVideoRenderer);

        if (androidVideoRenderer == 'auto') {
          // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
          // GPU-NEXT 需要 Vulkan 1.2 支持
          // 避免 Android 13 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
          final int androidSdkVersion =
              await PlatformEnvironmentService.getAndroidSdkVersion();
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          if (androidSdkVersion >= 34) {
            videoRenderer = 'gpu-next';
          } else {
            videoRenderer = 'gpu';
          }
        } else {
          videoRenderer = androidVideoRenderer;
        }
      }

      if (videoRenderer == 'mediacodec_embed') {
        hAenable = true;
        hardwareDecoder = 'mediacodec';
        superResolutionMode = SuperResolutionMode.off;
      }

      videoController ??= VideoController(
        player,
        configuration: VideoControllerConfiguration(
          vo: videoRenderer,
          enableHardwareAcceleration: hAenable,
          enableAndroidSurfaceProducer: false,
          hwdec: hAenable ? hardwareDecoder : 'no',
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      player.setPlaylistMode(PlaylistMode.none);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      bool showPlayerError = GStorage.getSetting(SettingsKeys.showPlayerError);
      player.stream.error.listen((event) {
        if (isCurrentPlayer(player)) {
          _handlePlayerError(event.toString(),
              showRawWhenUnmapped: showPlayerError);
        }
        KazumiLogger().e('PlayerController: Player intent error ${videoUrl()}',
            error: event);
      });

      // media_kit 只把少数几种 mpv 错误转发到 `player.stream.error`：
      // 仅 file / ffmpeg(且文本以 "tcp:" 开头) / vd / ad / cplayer / stream。
      // 因此直链被 CDN 拒绝（`HTTP error 403`、`tls:` 握手失败、ffmpeg 的
      // `[ffmpeg/video]` 解码错误等）不会进入 error 流 —— 应用完全看不到，
      // 界面就只剩下无限转圈。这里补听日志流里的 error/fatal，保证失败可见。
      player.stream.log.listen((log) {
        if (!isCurrentPlayer(player)) {
          return;
        }
        // 自诊断通道：`_dumpMpvDiagnostics` 用 `print-text` 问到的 mpv 内部状态
        // 走 info 级日志回来，这里无条件转成可见日志，避免像过去那样
        // 「界面一直转圈、日志里却什么都看不到」。
        if (log.text.contains('KAZUMI-DIAG')) {
          KazumiLogger().i('PlayerController: MPV 诊断 ${log.text}');
          return;
        }
        final level = log.level;
        if (level != 'error' && level != 'fatal') {
          return;
        }
        KazumiLogger().e(
            'PlayerController: MPV 错误 [${log.prefix}] ${log.text} | url=${videoUrl()}');
        // 同一条错误可能同时出现在两个流里（例如 `vd: Could not open codec.`），
        // _handlePlayerError 内部会去重，避免弹两条提示。
        _handlePlayerError(log.text, showRawWhenUnmapped: false);
      });

      if (superResolutionMode != SuperResolutionMode.off) {
        await setShader(superResolutionMode, player: player);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      if (videoSourceFormat == VideoSourceFormat.hls) {
        await pp.setProperty('demuxer-lavf-format', 'hls');
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      await player.open(
        Media(videoUrl(),
            start: Duration(seconds: offset), httpHeaders: httpHeaders),
        play: autoPlay,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // `open` 返回只表示命令被接受，这里开始校验是否真的出画面。
      _startStartupWatchdog(player);

      // 让 mpv 自己把内部状态打出来。不 await：mpv 若没在处理命令，
      // `mpv_command_async` 的回复永远不会到，await 会把起播流程一起拖死。
      unawaited(_dumpMpvDiagnostics(player, 'opened'));
      KazumiLogger().i(
          'PlayerController: open 已返回 | 播放列表 ${player.state.playlist.medias.length} 项'
          ' | autoPlay=$autoPlay | 请求头 ${httpHeaders.keys.join(",")}');

      if (cachePolicy.networkAutomatic) {
        KazumiDialog.showToast(message: '移动数据下已自动开启低内存模式，可在播放设置中改为始终关闭');
      }

      return player;
    } catch (error, stackTrace) {
      if (identical(_ownedPlayer, candidate)) {
        cachePolicy.stopWatching();
        _ownedPlayer = null;
        videoController = null;
      }
      await candidate.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      switch (mode) {
        case SuperResolutionMode.efficiency:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShadersLite,
            ),
          ]);
          break;
        case SuperResolutionMode.quality:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShaders,
            ),
          ]);
          break;
        case SuperResolutionMode.off:
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
          break;
      }
      superResolutionMode = mode;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to set shader', error: e);
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger()
          .e('PlayerController: failed to set playback speed', error: e);
    }
  }

  Future<void> setVolume(double value) async {
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    _stopStartupWatchdog();
    cachePolicy.stopWatching();
    final ownedPlayer = _ownedPlayer;
    _ownedPlayer = null;
    videoController = null;
    playing = false;
    loading = true;
    // media_kit stops playback as part of disposal before releasing native
    // resources. Debug subscriptions can be cancelled concurrently.
    await Future.wait([
      ownedPlayer?.dispose() ?? Future<void>.value(),
      _cancelDebugInfo(),
    ]);
  }

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    // Encode the captured frame natively; PlayerState dimensions may be stale.
    return player.safeScreenshot(format: 'image/png');
  }
}
