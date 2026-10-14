import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/direct_video_source_resolver.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

/// 直取失败后，WebView 嗅探窗口的保留下限。
///
/// 直取会先消耗一部分时间，若不回收这部分时间，慢站点的总等待时间会变成
/// 「直取耗时 + 完整嗅探超时」，比改动前更差。
const Duration _minSniffTimeout = Duration(seconds: 8);

/// WebView 视频源解析服务
///
/// 使用 WebView 解析视频页面，提取视频源 URL。
/// WebView 实例在服务生命周期内复用，切换集数时调用 unloadPage 释放页面资源，
/// 仅在 [dispose] 时才真正销毁 WebView。
///
/// 解析策略为「原生直取优先，WebView 嗅探兜底」：
///
/// 1. 先由 [DirectVideoSourceResolver] 直接 HTTP 拉取播放页并提取媒体地址，
///    不依赖 WebView 与页面 JS。这既是旧 WebView 设备（现代播放器脚本无法
///    执行、嗅探必然超时）的唯一可行路径，也让新设备上的解析从秒级降到
///    1~3 秒。
/// 2. 直取未命中时，回退到原有的 WebView 嗅探流程，行为与改动前完全一致。
class WebViewVideoSourceService implements IVideoSourceService {
  VideoWebviewController? _webview;
  StreamSubscription? _logSubscription;
  final DirectVideoSourceResolver _directResolver = DirectVideoSourceResolver();

  // 单个服务实例持有一个 WebView，因此解析任务按实例串行执行。
  // 下载并行通过多个服务实例实现。
  Future<void>? _resolveTail = Future<void>.value();
  _ResolveRequest? _activeRequest;

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final resolveTail = _resolveTail;
    if (resolveTail == null) {
      throw const VideoSourceCancelledException();
    }

    _activeRequest?.cancel();
    final request = _ResolveRequest();
    _activeRequest = request;

    final resolveFuture = resolveTail.then(
      (_) => _runResolve(
        request,
        episodeUrl,
        useLegacyParser: useLegacyParser,
        offset: offset,
        timeout: timeout,
      ),
    );

    _resolveTail = resolveFuture.then<void>((_) {}, onError: (_) {});
    return resolveFuture;
  }

  Future<VideoSource> _runResolve(
    _ResolveRequest request,
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
  }) async {
    request.throwIfNotCurrent(_activeRequest);

    // ① 原生直取：直接拉取播放页 HTML 提取媒体地址，不依赖 WebView / JS。
    //    旧 WebView 设备（如 Android 9 的 Chrome 66）执行现代播放器脚本会抛
    //    SyntaxError，页面永不发出 m3u8 请求，嗅探必然超时；直取不受影响。
    final directStopwatch = Stopwatch()..start();
    request.addCancelHook(_directResolver.cancel);
    final directSource = await _directResolver.tryResolve(
      episodeUrl,
      useLegacyParser: useLegacyParser,
      offset: offset,
      timeout: timeout,
    );
    directStopwatch.stop();

    request.throwIfNotCurrent(_activeRequest);
    if (directSource != null) {
      KazumiLogger().i(
          'WebViewVideoSource: resolved by DIRECT fetch in ${directStopwatch.elapsedMilliseconds}ms | url=$episodeUrl');
      return directSource;
    }

    // ② 回退 WebView 嗅探；嗅探窗口扣除直取已消耗的时间（保留 8s 下限）。
    final sniffTimeout =
        _remainingSniffTimeout(timeout, directStopwatch.elapsed);
    KazumiLogger().d(
        'WebViewVideoSource: direct fetch missed (${directStopwatch.elapsedMilliseconds}ms), '
        'falling back to WebView sniff (window=${sniffTimeout.inSeconds}s)');

    if (_webview == null) {
      KazumiLogger().i('WebViewVideoSource: creating webview controller');
      _webview = VideoWebviewControllerFactory.getController();
      await _webview!.init();
      KazumiLogger().i('WebViewVideoSource: webview initialized');

      _logSubscription = _webview!.onLog.listen((log) {
        // 【诊断】TV 端没有任何 logStream 消费者（消费者只有移动端
        // lib/pages/video/video_page.dart），所以 WebView 内部日志在 TV 上
        // 会被整体丢弃。这里额外打到 KazumiLogger，保证能进 logcat。
        KazumiLogger().d('WebView: $log');
        if (!_logController.isClosed) {
          _logController.add(log);
        }
      });
    }

    var didStartLoad = false;
    try {
      request.throwIfNotCurrent(_activeRequest);
      didStartLoad = true;
      KazumiLogger().i(
          'WebViewVideoSource: loadUrl=$episodeUrl | legacy=$useLegacyParser | offset=$offset | timeout=${sniffTimeout.inSeconds}s');
      await _webview!.loadUrl(
        episodeUrl,
        useLegacyParser,
        offset: offset,
      );

      request.throwIfNotCurrent(_activeRequest);

      final parserFuture = _webview!.onVideoURLParser.first.timeout(
        sniffTimeout,
        onTimeout: () {
          request.throwIfNotCurrent(_activeRequest);
          // 【诊断】超时是静默的（上层只改 UI 状态），这里补一条明确日志。
          KazumiLogger().e(
              'WebViewVideoSource: TIMEOUT ${sniffTimeout.inSeconds}s, no video source sniffed | url=$episodeUrl | legacy=$useLegacyParser');
          throw VideoSourceTimeoutException(sniffTimeout);
        },
      );
      final cancelFuture = request.cancelled.then<VideoParserEvent>((_) {
        throw const VideoSourceCancelledException();
      });
      final event = await Future.any([parserFuture, cancelFuture]);

      request.throwIfNotCurrent(_activeRequest);

      KazumiLogger().i('WebViewVideoSource: sniffed video source ${event.url}');

      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: event.format,
      );
    } catch (e) {
      if (e is VideoSourceCancelledException) {
        rethrow;
      }
      request.throwIfNotCurrent(_activeRequest);
      rethrow;
    } finally {
      if (didStartLoad) {
        await _webview?.unloadPage();
      }
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
      }
    }
  }

  /// 直取已经消耗了一部分时间，WebView 嗅探窗口相应缩短，同时保留
  /// [_minSniffTimeout] 下限，避免慢站点因窗口过短而误判超时。
  Duration _remainingSniffTimeout(Duration timeout, Duration spent) {
    final left = timeout - spent;
    return left < _minSniffTimeout ? _minSniffTimeout : left;
  }

  @override
  void cancel() {
    _activeRequest?.cancel();
    _directResolver.cancel();
  }

  @override
  Future<void> dispose() async {
    final resolveTail = _resolveTail;
    _resolveTail = null;
    cancel();
    await resolveTail;
    _activeRequest = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    if (!_logController.isClosed) {
      await _logController.close();
    }
    await _directResolver.dispose();
    await _webview?.dispose();
    _webview = null;
  }
}

class _ResolveRequest {
  final Completer<void> _cancelled = Completer<void>();
  final List<void Function()> _cancelHooks = [];

  Future<void> get cancelled => _cancelled.future;

  /// 注册取消回调（例如中断直取阶段正在进行的 HTTP 请求）。
  void addCancelHook(void Function() hook) {
    if (_cancelled.isCompleted) {
      hook();
      return;
    }
    _cancelHooks.add(hook);
  }

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
    for (final hook in _cancelHooks) {
      hook();
    }
    _cancelHooks.clear();
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}
