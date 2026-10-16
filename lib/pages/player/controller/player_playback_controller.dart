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
import 'package:kazumi/services/player/local_media_proxy.dart';
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

  /// 本次会话是否已经因「解码器初始化失败」而立即切过软解（见
  /// [_recoverFromDecoderFailure]）。只做一次，避免和看门狗互相触发成环。
  bool _decoderRecoveryStarted = false;

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

  /// 解码器初始化失败的特征串。
  ///
  /// 本机（安卓 9 盒子 MGV3201-ZG）每次起播必现：
  ///   `h264_mediacodec: Both surface and native_window are NULL`
  ///   `h264_mediacodec: Output color format 0x2f (value=47) is not supported`
  ///   `h264_mediacodec: MediaCodec 0x... failed to start`
  ///   `vd: Could not open codec.`
  /// 即该 SoC 的 MediaCodec 硬解不可用。命中后**立即**切软解，不再等 18 秒看门狗。
  static const List<String> _decoderFailureMarkers = <String>[
    'Could not open codec',
    'mediacodec',
    'Failed to configure context',
    'Output color format',
    'native_window are NULL',
    'Failed to start',
  ];

  bool _looksLikeDecoderFailure(String text) {
    final lower = text.toLowerCase();
    for (final marker in _decoderFailureMarkers) {
      if (lower.contains(marker.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// 值得落盘的 mpv **非错误**日志前缀。
  ///
  /// mpv 在 `v` 级下输出极多（逐帧/逐包级别的噪声），全量落盘会淹没日志。
  /// 这里只保留能直接回答「起播为什么没画面」的几类：
  /// - `cplayer`：`Playing:`、`● Video/Audio ...`、`VO:`、`AO:`、缓冲/失同步告警
  /// - `vd` / `ao` / `vo`：解码器、音频输出、视频输出的初始化
  /// - `demuxer` / `stream` / `tls` / `http` / `ffmpeg`：网络与解复用
  /// - `playlist` / `opener` / `file` / `cache`：媒体加载链路
  static const List<String> _mpvInfoPrefixes = <String>[
    'cplayer',
    'vd',
    'ao',
    'vo',
    'demuxer',
    'stream',
    'tls',
    'http',
    'ffmpeg',
    'playlist',
    'opener',
    'file',
    'cache',
  ];

  bool _worthLoggingMpvInfo(String prefix) {
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) {
      return false;
    }
    for (final want in _mpvInfoPrefixes) {
      if (p.startsWith(want)) {
        return true;
      }
    }
    return false;
  }

  /// 返回真正交给 mpv 的地址：优先映射到 [LocalMediaProxy]，让 HTTPS 走系统
  /// TLS 栈，绕开 libmpv 自带 mbedtls 在部分 CDN 上握手卡死的问题。
  ///
  /// 代理不可用时**静默回退直连**，保证任何设备都不会因为这条链路而比改动前更差。
  /// 日志里继续使用 [videoUrl] 的原始地址，避免诊断信息被 `127.0.0.1` 掩盖。
  Future<String> _playbackUrl() async {
    final raw = videoUrl();
    if (raw.isEmpty) {
      return raw;
    }
    try {
      return await LocalMediaProxy.instance.map(raw);
    } catch (error) {
      KazumiLogger().w('PlayerController: 本地媒体代理不可用，回退直连 | $error');
      return raw;
    }
  }

  /// 解码器初始化失败 → 立即 `hwdec=no` 并重开媒体。
  ///
  /// 只做一次：软解若仍然失败，说明问题不在解码器，交给看门狗/页面兜底。
  Future<void> _recoverFromDecoderFailure(String text) async {
    if (_decoderRecoveryStarted) {
      return;
    }
    final player = mediaPlayer;
    if (player == null || !isCurrentPlayer(player)) {
      return;
    }
    _decoderRecoveryStarted = true;
    final uri = await _playbackUrl();
    if (uri.isEmpty) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      KazumiLogger()
          .e('PlayerController: 检测到解码器初始化失败，立即切换软解重开 | $text');
      await pp.setProperty('hwdec', 'no');
      if (!isCurrentPlayer(player)) {
        return;
      }
      final reopenFuture = player.open(
        Media(uri,
            start: Duration(seconds: startOffset),
            httpHeaders: _lastHttpHeaders),
        play: autoPlay,
      );
      await Future.any<bool>([
        reopenFuture.then((_) => true).catchError((Object _) => true),
        Future<bool>.delayed(const Duration(seconds: 30), () => false),
      ]);
      if (!isCurrentPlayer(player)) {
        return;
      }
      _startupRecoveryDone = false;
      _softDecodeRetried = true;
      _startStartupWatchdog(player);
    } catch (e) {
      KazumiLogger().w('PlayerController: 解码器失败后软解重开失败', error: e);
    }
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
    // 解码器初始化失败：**立即**切软解重开（不依赖 18 秒看门狗）。
    if (_looksLikeDecoderFailure(text)) {
      unawaited(_recoverFromDecoderFailure(text));
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
  /// 直接向 mpv **同步**查询内部状态（`mpv_get_property_string`），绕开事件泵。
  ///
  /// ⚠️ 教训（tv-build-45）：这里原先用 `print-text` 输出诊断，结果一条都没看到，
  /// 当时据此推断「media_kit 只转发 error 级日志」—— **这个推断是错的**。
  /// 真实情况见 media_kit `real.dart` 的 `MPV_EVENT_LOG_MESSAGE` 分支：它把
  /// **所有级别**的日志都无条件 `logController.add`，只有 `player.stream.error`
  /// 才是过滤过的（仅 file / `tcp:` 开头的 ffmpeg / vd / ad / cplayer / stream）。
  /// 也就是说我们**本来就能收到** `Playing:` / `VO:` / `AO:` 那些行，是
  /// `player.stream.log` 的订阅端自己把它们挡掉了（已在该处一并修掉）。
  ///
  /// 即便如此，诊断仍以本方法为准：`getProperty` 是同步 C API，既不依赖事件
  /// 通道、也不依赖日志级别，结果一定拿得到。
  ///
  /// 另外这里刻意用 **error** 级写日志：`KazumiLogOutput` 只在 WARNING 及以上
  /// 才落盘，否则一旦 `playerDebugMode` 关掉就又看不见了。
  ///
  /// `waitForInitialization: false` 是必须的 —— 诊断往往正是在「初始化/起播
  /// 卡住」时调用，若它自己去 await 初始化，就会连诊断一起卡住。
  Future<void> _dumpMpvDiagnostics(Player player, String tag) async {
    if (!isCurrentPlayer(player)) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      const keys = <String>[
        'idle-active',
        'playlist-count',
        'playlist-pos',
        'path',
        'stream-open-filename',
        'file-format',
        'duration',
        'width',
        'height',
        'vid',
        'aid',
        'vo-configured',
        'core-idle',
        'paused-for-cache',
        'cache-buffering-state',
        'eof-reached',
        'hwdec-current',
      ];
      final parts = <String>[];
      for (final key in keys) {
        String value;
        try {
          value = await pp.getProperty(key, waitForInitialization: false);
        } catch (_) {
          value = 'ERR';
        }
        parts.add('$key=${value.isEmpty ? '(empty)' : value}');
      }
      KazumiLogger().e('PlayerController: MPV 诊断[$tag] ${parts.join(' ')}');
    } catch (e) {
      KazumiLogger().w('PlayerController: mpv 诊断读取失败', error: e);
    }
  }

  /// 给「可能永久挂起」的 mpv 命令加软超时。
  ///
  /// media_kit 的 `command()` 实现是 `mpv_command_async` + `await
  /// MPV_EVENT_COMMAND_REPLY`：一旦事件泵或命令通道卡住，这个 Future **永远不会
  /// 完成**。恢复阶梯里若直接 `await` 它，整个自愈流程会跟着一起卡死 ——
  /// 这正是「卡死后完全没有自救」的另一半原因。
  ///
  /// 超时后把原 Future 的异常也消费掉，避免出现「未处理的 Future 错误」。
  Future<void> _commandWithTimeout(
    NativePlayer pp,
    List<String> command, {
    required String label,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final future = pp.command(command);
    try {
      await future.timeout(timeout);
    } on TimeoutException {
      unawaited(future.catchError((Object _) {}));
      KazumiLogger().w(
          'PlayerController: $label 命令 ${timeout.inSeconds}s 未返回（mpv 命令通道可能已卡住）');
    } catch (e) {
      KazumiLogger().w('PlayerController: $label 命令失败', error: e);
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
    // 阶段零：解复用阶段完全没有数据（`duration` 恒为 0）—— 先排除缓存/网络因素，
    // 再绕过 media_kit 的临时播放列表文件，直接让 mpv `loadfile`。
    //
    // 实机（安卓 9 盒子）已确证：此时直链本身完全可用 —— 在盒子上用 curl 取同一个
    // URL（任意 UA、有无 Range、HTTP/1.1）都秒回 `206 video/mp4`，甚至无 Range 时
    // 15 秒能拉 68 MB。所以瓶颈不在网络与 CDN，而在 mpv 的 demuxer 侧。
    // `cache-on-disk` + `demuxer-cache-dir` 的组合是老固件上最可疑的一环，先关掉。
    //
    // 请求头不受影响：media_kit 的 `on_load` 钩子是用 URI 回查 `Media` 的静态
    // 请求头表（见 media_kit real.dart 的 MPV_EVENT_HOOK 分支），与加载方式无关。
    if (!decodeStall && !_directLoadRetried) {
      _directLoadRetried = true;
      final uri = await _playbackUrl();
      if (uri.isNotEmpty) {
        try {
          final pp = player.platform as NativePlayer;
          // ★ tv-build-47：这里**不再**写 `cache-on-disk=no` / `network-timeout=60`。
          // tv-build-46 加过这两项，实测仍然 0 次开流；而 `bufferSize=1500MB`
          // 且不做任何额外覆盖的 b9b425e 能稳定开流。失败的形态是「URL 进了播放
          // 列表但 stream/demuxer 从未建立」（`file-format` / `cache-buffering-state`
          // 全为 empty），说明瓶颈就在起播路径本身，再叠属性只会增加变量。
          await _commandWithTimeout(pp, ['loadfile', uri], label: 'loadfile');
          if (!isCurrentPlayer(player)) {
            return;
          }
          await _commandWithTimeout(pp, ['set', 'pause', 'no'],
              label: 'pause-off');
          KazumiLogger().e(
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
    // 条件里**不再要求** `decodeStall`：`duration=0`（连解复用都没开始）时硬解
    // 也可能已经把 vod 管线卡住，同样值得换软解重开一次。
    if (!_softDecodeRetried) {
      _softDecodeRetried = true;
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('hwdec', 'no');
        if (!isCurrentPlayer(player)) {
          return;
        }
        KazumiLogger().e('PlayerController: 已切换为软解并重新打开');
        final reopenUri = await _playbackUrl();
        final reopenFuture = player.open(
          Media(reopenUri,
              start: Duration(seconds: startOffset),
              httpHeaders: _lastHttpHeaders),
          play: autoPlay,
        );
        // 与主流程一致：软超时 + 消费异常，避免自愈阶梯自己被卡住。
        await Future.any<bool>([
          reopenFuture.then((_) => true).catchError((Object _) => true),
          Future<bool>.delayed(const Duration(seconds: 30), () => false),
        ]);
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
    _decoderRecoveryStarted = false;
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
      // ★ media_kit 的 `logController` 对**所有级别**的 mpv 日志都转发
      // （real.dart 的 MPV_EVENT_LOG_MESSAGE 分支只是无条件 `logController.add`），
      // 只有 `player.stream.error` 才是被过滤过的（仅 file / tcp: 开头的 ffmpeg /
      // vd / ad / cplayer / stream）。因此这里必须自己决定哪些级别值得落盘：
      //
      // tv-build-45 只留了 error/fatal，结果把 `Playing:`、`● Video --vid=1 ...`、
      // `VO: [gpu] ...`、`AO: [...]`、`tcp:` 这些**真正能定位问题**的行**全部丢掉**，
      // 现场只剩下一串 `h264_mediacodec` 报错，完全看不出「媒体到底有没有被打开」。
      player.stream.log.listen((log) {
        if (!isCurrentPlayer(player)) {
          return;
        }
        final level = log.level;
        final text = log.text;

        if (level != 'error' && level != 'fatal') {
          // 非错误日志：只保留高价值前缀，且用 WARNING 级写出，
          // 保证 `KazumiLogOutput`（只在 WARNING 及以上落盘）一定会写进
          // `files/logs/kazumi_logs.log`，用户无需打开 playerDebugMode 也能查。
          if (_worthLoggingMpvInfo(log.prefix)) {
            KazumiLogger()
                .w('PlayerController: MPV[$level][${log.prefix}] $text');
          }
          return;
        }

        KazumiLogger().e(
            'PlayerController: MPV 错误 [${log.prefix}] $text | url=${videoUrl()}');
        // 同一条错误可能同时出现在两个流里（例如 `vd: Could not open codec.`），
        // _handlePlayerError 内部会去重，避免弹两条提示。
        _handlePlayerError(text, showRawWhenUnmapped: false);
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

      // ★ 看门狗必须在 `open()` **之前**启动。
      //
      // tv-build-45 把它挂在 `open()` 之后：一旦 `open()` 在 mpv 侧卡住不返回
      // （实机确实观察到过 `open` 之后整段代码再也不执行），看门狗、诊断、
      // 自愈阶梯**全都不会启动** —— 这正是「卡死后毫无自救、只能无限转圈」的
      // 直接原因。先起看门狗，再给 `open` 加一个软超时，即使它永不返回，
      // 18 秒后照样会走恢复阶梯。
      _startStartupWatchdog(player);
      unawaited(_dumpMpvDiagnostics(player, 'before-open'));

      final openStopwatch = Stopwatch()..start();
      // ★ 交给 mpv 的是**本地代理地址**（若代理可用）。这样 mpv 只跟
      // 127.0.0.1 说明文 HTTP，真正的 HTTPS 由 Dart 的 HttpClient 完成 ——
      // 即系统 TLS 栈。实机已证明同一个 URL 走系统 TLS 能跑到 2~6 MB/s，
      // 而 libmpv 自带的 mbedtls 会握手 217 秒后 `CONN_EOF` 失败。
      final mediaUri = await _playbackUrl();
      if (mediaUri != videoUrl()) {
        KazumiLogger().e(
            'PlayerController: 已切换到本地媒体代理（TLS 交给系统栈）| $mediaUri');
      }
      final openFuture = player.open(
        Media(mediaUri,
            start: Duration(seconds: offset), httpHeaders: httpHeaders),
        play: autoPlay,
      );
      // `Future.any` + `catchError` 组合：超时后不再 await `open` 的后续结果，
      // 同时消费掉它可能抛出的异常，避免「未处理的 Future 错误」。
      final openSettled = await Future.any<bool>([
        openFuture.then((_) => true).catchError((Object _) => true),
        Future<bool>.delayed(const Duration(seconds: 30), () => false),
      ]);
      openStopwatch.stop();
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      if (!openSettled) {
        KazumiLogger().e(
            'PlayerController: open 超过 30s 未返回，交给看门狗接管 | url=${videoUrl()}');
        unawaited(_dumpMpvDiagnostics(player, 'open-timeout'));
        return player;
      }

      // `open` 返回只表示命令被接受，这里开始校验是否真的出画面。
      unawaited(_dumpMpvDiagnostics(player, 'open-returned'));
      KazumiLogger().e(
          'PlayerController: open 已返回（${openStopwatch.elapsedMilliseconds}ms）'
          ' | 播放列表 ${player.state.playlist.medias.length} 项'
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
