import 'dart:async';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required bool Function() isLocalPlayback,
    required Player? Function() currentPlayer,
  })  : _isLocalPlayback = isLocalPlayback,
        _currentPlayer = currentPlayer;

  static const int _lowMemoryBufferSize = 2 * 1024 * 1024;
  static const int _defaultBufferSize = 1500 * 1024 * 1024;

  /// 低于该内存的设备会被标记为「受限设备」，**仅用于日志**。
  ///
  /// ⚠️ 警告：**不要**再拿这个标记去收缩 demuxer 缓存。见下。
  static const int _constrainedMemoryThresholdKb = 3 * 1024 * 1024;

  // ---------------------------------------------------------------------------
  // 反面教材：tv-build-45 曾在这里按 `isConstrainedDevice` 把 demuxer 缓存压到
  // 96 MB（tv-build-46 改成 256 MB），结果在安卓 9 盒子 `MGV3201-ZG` 上
  // **mpv 从此再也不打开媒体流**，每一集都只有黑屏 + 转圈。
  //
  // 实机对照（同一个番、同一个源、同一个直链路径 `.../video/tos/alisg/...`）：
  //
  //   tv-build-44 / commit b9b425e  → bufferSize = 1500 MB
  //       `MPV: PlayerLog(prefix: playlist, ... Reading plaintext playlist.)`
  //       `MPV: PlayerLog(prefix: cplayer, ... Playing: https://v16-...)`
  //       `PlayerController: video initialized`          ← 流被打开、视频参数就绪
  //       4 次播放 4 次成功（4 个不同 CDN 域名：bytepluscdn / capcutvod /
  //       akamaized / titok-inc 全部 `Playing:`）
  //
  //   tv-build-45 / commit 33ffd14  → bufferSize = 96 MB    → 0 次开流
  //   tv-build-46 / commit 79cc292  → bufferSize = 256 MB   → 0 次开流
  //       从不为 0 的是这一组 mpv 属性（只有流真正建立时才会出现）：
  //       `file-format=(empty)` `duration=(empty)`
  //       `paused-for-cache=(empty)` `cache-buffering-state=(empty)`
  //       即 mpv 只把 URL 放进了播放列表（`path` / `playlist-pos=0` 都有），
  //       却从未建立 stream / demuxer，也从未发起网络连接 —— 所以
  //       「在盒子上 curl 该 URL 秒回 206 video/mp4」这类网络侧证据全都无关。
  //
  // 同一时间段内 media_kit 未变（fork `Predidit/media-kit@main` 的 HEAD 是
  // `6b188ae9`，2026-10-13，早于两次构建），build45 对播放器创建路径的唯一
  // 改动就是这个 bufferSize。所以**恢复 1500 MB 是本设备上唯一被实机验证过
  // 能打开流的配置**。
  //
  // 代价说明：`demuxer-max-bytes` / `demuxer-max-back-bytes` 都是**上限**而非
  // 预分配，mpv 按需使用，因此 1500 MB 不会真的吃掉 2 GB 内存。
  // ---------------------------------------------------------------------------

  final bool Function() _isLocalPlayback;
  final Player? Function() _currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  int get bufferSize => LowMemoryMode.current.isEnabled(
        isMetered: MeteredNetworkService.isMetered,
        isLocalPlayback: _isLocalPlayback(),
      )
          ? _lowMemoryBufferSize
          : _defaultBufferSize;

  static int? _deviceMemTotalKbCache;

  /// `/proc/meminfo` 的 `MemTotal`（KB）。非 Linux/Android 平台返回 null。
  ///
  /// 只用于日志，方便日后对照「设备内存 ↔ 实测行为」。
  static int? _deviceMemTotalKb() {
    if (_deviceMemTotalKbCache != null) {
      return _deviceMemTotalKbCache;
    }
    int? total;
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        final file = File('/proc/meminfo');
        if (file.existsSync()) {
          for (final line in file.readAsLinesSync()) {
            if (!line.startsWith('MemTotal:')) {
              continue;
            }
            final match = RegExp(r'(\d+)').firstMatch(line);
            if (match != null) {
              total = int.tryParse(match.group(1)!);
            }
            break;
          }
        }
      } catch (_) {
        total = null;
      }
    }
    _deviceMemTotalKbCache = total;
    return total;
  }

  /// 内存偏小的设备（典型：2 GB 的 Android TV 盒子）。**仅用于日志**。
  static bool get isConstrainedDevice {
    final total = _deviceMemTotalKb();
    return total != null && total < _constrainedMemoryThresholdKb;
  }

  void startWatching() {
    if (_settingsSubscription != null) {
      return;
    }
    _settingsSubscription = LowMemoryMode.watch().listen((_) => _onChanged());
    MeteredNetworkService.listenable.addListener(_onChanged);
  }

  void stopWatching() {
    MeteredNetworkService.listenable.removeListener(_onChanged);
    unawaited(_settingsSubscription?.cancel());
    _settingsSubscription = null;
  }

  Future<void> apply() async {
    final player = _currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      // A stale player's initialization must not block its replacement's writes.
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(_currentPlayer(), player)) {
          return;
        }
        // ★ 只写这两项，与 tv-build-44 的配置保持一致。
        //
        // 这里**不要**再追加 `cache-on-disk` / `network-timeout` 之类的覆盖：
        // tv-build-46 加过 `cache-on-disk=no` 与 `network-timeout=60`，仍然
        // 0 次开流；而 b9b425e 的原始写法（只写这两项）能稳定开流。
        // 在没有实机证据支持之前，任何对 mpv 起播路径的额外改动都是风险。
        final size = bufferSize.toString();
        await pp.setProperty('demuxer-max-bytes', size);
        await pp.setProperty('demuxer-max-back-bytes', size);
      });
      KazumiLogger().e(
          'PlaybackCachePolicy: demuxer 缓存上限 $bufferSize 字节 '
          '(MemTotal=${_deviceMemTotalKb() ?? -1} KB, '
          '受限设备=$isConstrainedDevice[仅日志，不据此收缩缓存])');
    } catch (e) {
      KazumiLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _onChanged() {
    unawaited(apply());
  }
}
