import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

/// WebView 视频源解析服务
///
/// 使用 WebView 解析视频页面，提取视频源 URL。
/// WebView 实例在服务生命周期内复用，切换集数时调用 unloadPage 释放页面资源，
/// 仅在 [dispose] 时才真正销毁 WebView。
class WebViewVideoSourceService implements IVideoSourceService {
  VideoWebviewController? _webview;
  StreamSubscription? _logSubscription;

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
          'WebViewVideoSource: loadUrl=$episodeUrl | legacy=$useLegacyParser | offset=$offset | timeout=${timeout.inSeconds}s');
      await _webview!.loadUrl(
        episodeUrl,
        useLegacyParser,
        offset: offset,
      );

      request.throwIfNotCurrent(_activeRequest);

      final parserFuture = _webview!.onVideoURLParser.first.timeout(
        timeout,
        onTimeout: () {
          request.throwIfNotCurrent(_activeRequest);
          // 【诊断】超时是静默的（上层只改 UI 状态），这里补一条明确日志。
          KazumiLogger().e(
              'WebViewVideoSource: TIMEOUT ${timeout.inSeconds}s, no video source sniffed | url=$episodeUrl | legacy=$useLegacyParser');
          throw VideoSourceTimeoutException(timeout);
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

  @override
  void cancel() {
    _activeRequest?.cancel();
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
    await _webview?.dispose();
    _webview = null;
  }
}

class _ResolveRequest {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}
