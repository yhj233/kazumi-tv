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
  /// `demuxer-max-back-bytes`，所以实际预算是它的两倍。默认的 1500 MB 意味着
  /// 在 2 GB 内存的电视盒子上 mpv 会一路读到接近物理内存上限：实测该设备
  /// `MemTotal=2 GB / MemAvailable≈0.9 GB`，起播时正是长期无画面、零流量的
  /// 状态。收到 96 MB 后缓存行为正常，网络读取也不再被内存压力干扰。
  static const int _constrainedBufferSize = 96 * 1024 * 1024;

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
      });
      KazumiLogger().i(
          'PlaybackCachePolicy: demuxer 缓存上限 $bufferSize 字节 (MemTotal=${_deviceMemTotalKb() ?? -1} KB)');
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
