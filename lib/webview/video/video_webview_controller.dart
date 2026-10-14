import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/webview/video/impl/video_webview_android_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_windows_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_linux_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_apple_impl.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/webview_feature_service.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

typedef VideoParserEvent = ({
  String url,
  int offset,
  VideoSourceFormat format,
});

abstract class VideoWebviewController<T> {
  // WebView controller.
  T? webviewController;

  // Retry count
  int count = 0;
  // Last watched position
  int offset = 0;
  bool isIframeLoaded = false;
  bool isVideoSourceLoaded = false;

  /// WebView initialization method.
  Future<void> init();

  final StreamController<bool> initEventController =
      StreamController<bool>.broadcast();

  // Stream to notify when the webview is initialized
  Stream<bool> get onInitialized => initEventController.stream;

  final StreamController<String> logEventController =
      StreamController<String>.broadcast();

  // Stream to subscribe to webview logs
  Stream<String> get onLog => logEventController.stream;

  final StreamController<bool> videoLoadingEventController =
      StreamController<bool>.broadcast();

  // Stream to notify when the video source is loaded
  Stream<bool> get onVideoLoading => videoLoadingEventController.stream;

  // Stream to notify when a video source URL is resolved, including its
  // playback offset and any format information confirmed by the parser.
  final StreamController<VideoParserEvent> _videoParserEventController =
      StreamController<VideoParserEvent>.broadcast();

  Stream<VideoParserEvent> get onVideoURLParser =>
      _videoParserEventController.stream;

  @protected
  void notifyVideoSourceResolved(
    String url, {
    VideoSourceFormat format = VideoSourceFormat.auto,
  }) {
    _videoParserEventController.add((
      url: url,
      offset: offset,
      format: format,
    ));
  }

  void disposeEventControllers() {
    if (!initEventController.isClosed) {
      initEventController.close();
    }
    if (!logEventController.isClosed) {
      logEventController.close();
    }
    if (!videoLoadingEventController.isClosed) {
      videoLoadingEventController.close();
    }
    if (!_videoParserEventController.isClosed) {
      _videoParserEventController.close();
    }
  }

  /// WebView load URL method.
  Future<void> loadUrl(String url, bool useLegacyParser, {int offset = 0});

  /// WebView unload page method.
  Future<void> unloadPage();

  /// WebView dispose method.
  Future<void> dispose();
}

class VideoWebviewControllerFactory {
  static VideoWebviewController getController() {
    // 【诊断】记录实际选中的实现，用于区分两条嗅探路径：
    // - VideoWebviewAndroidImpl → AT_DOCUMENT_START 预注入（安卓15 正常的那条）
    // - VideoWebviewImpl        → fallback（安卓9 上看不到 [WebView] Created 之外的信息）
    final VideoWebviewController controller;
    if (Platform.isWindows) {
      controller = VideoWebviewWindowsImpl();
    } else if (Platform.isLinux) {
      controller = VideoWebviewLinuxImpl();
    } else if (Platform.isMacOS || Platform.isIOS) {
      controller = VideoWebviewAppleImpl();
    } else if (Platform.isAndroid &&
        WebViewFeatureService.isDocumentStartScriptSupported) {
      controller = VideoWebviewAndroidImpl();
    } else {
      controller = VideoWebviewImpl();
    }

    KazumiLogger().i(
        'VideoWebviewControllerFactory: selected=${controller.runtimeType} '
        '| android=${Platform.isAndroid} '
        '| documentStartScriptSupported=${WebViewFeatureService.isDocumentStartScriptSupported}');
    return controller;
  }
}
