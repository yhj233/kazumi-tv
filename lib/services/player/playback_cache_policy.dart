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

  /// 低于该内存的设备按「受限设备」处理，demuxer 缓存必须收紧。
  static const int _constrainedMemoryThresholdKb = 3 * 1024 * 1024;

  /// 受限设备单侧缓存上限（前向 + 回退都取该值）。
  ///
  /// media_kit 会把 bufferSize 同时写到 `demuxer-max-bytes` 和
  /// `demuxer-max-back-bytes`，所以实际预算是它的两倍。
  ///
  /// ⚠️ 历史教训（tv-build-45）：曾经把这里收到 **96 MB**，思路是「2 GB 盒子上
  /// 1500 MB×2 的预算过大」。实机（安卓 9 盒子 `MGV3201-ZG`）结果是**每一集都
  /// 完全不出画面**：mpv 起播后 `duration` 恒为 0，`demuxer` 一直读不到数据，
  /// 而同一个直链在盒子上用 curl 取（任何 UA / 有无 Range）都秒回 `206 video/mp4`。
  /// 说明瓶颈不在网络，而在 mpv 的 demuxer 缓存预算被压得太小 —— 与
  /// `cache-on-disk=yes` 叠加后 demuxer 无法正常预读。
  /// **因此这里不再压到 100 MB 量级**，改用 256 MB（=实际 512 MB 预算），
  /// 既远低于 2 GB 设备的物理上限，又足以让 demuxer 正常工作。
  static const int _constrainedBufferSize = 256 * 1024 * 1024;

  final bool Function() _isLocalPlayback;
  final Player? Function() _currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  int get bufferSize {
    if (LowMemoryMode.current.isEnabled(
      isMetered: MeteredNetworkService.isMetered,
      isLocalPlayback: _isLocalPlayback(),
    )) {
      return _lowMemoryBufferSize;
    }
    if (isConstrainedDevice) {
      return _constrainedBufferSize;
    }
    return _defaultBufferSize;
  }

  static int? _deviceMemTotalKbCache;

  /// `/proc/meminfo` 的 `MemTotal`（KB）。非 Linux/Android 平台返回 null。
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

  /// 内存不足以承担默认缓存预算的设备（典型：2 GB 的 Android TV 盒子）。
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
        final size = bufferSize.toString();
        await pp.setProperty('demuxer-max-bytes', size);
        await pp.setProperty('demuxer-max-back-bytes', size);
        // 受限设备（典型：2 GB 的安卓电视盒子）额外**关掉磁盘缓存**。
        //
        // media_kit 在 `_create()` 里无条件 `cache-on-disk=yes`，而 Kazumi 又把
        // `demuxer-cache-dir` 指到应用私有目录；这一组合在部分旧固件上会让
        // demuxer 无法正常预读（实机现象：起播后 `duration` 恒为 0、mpv 零流量，
        // 而同一 URL 用 curl 秒回 `206 video/mp4`）。关掉磁盘缓存后 mpv 只走
        // 内存缓存，配合上面的 256 MB 上限，内存占用可控。
        if (isConstrainedDevice) {
          await pp.setProperty('cache-on-disk', 'no');
        }
        // 老设备上 CDN 首包偶发偏慢，media_kit 默认 `network-timeout=5` 偏紧。
        await pp.setProperty('network-timeout', '60');
      });
      KazumiLogger().e(
          'PlaybackCachePolicy: demuxer 缓存上限 $bufferSize 字节 '
          '(MemTotal=${_deviceMemTotalKb() ?? -1} KB, '
          '受限设备=$isConstrainedDevice, cache-on-disk=${isConstrainedDevice ? 'no' : 'yes(media_kit 默认)'}, '
          'network-timeout=60)');
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
