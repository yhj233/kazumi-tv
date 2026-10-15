import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/webview/video/js_downlevel.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    as android_webview;
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/http_headers.dart';

class VideoWebviewImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;
  bool hasRegisteredHandlers = false;
  bool useLegacyParser = false;
  Timer? videoParserTimer;

  /// ---- 原生资源代理：修复老 WebView（安卓9 / Chrome 66）子资源随机失败 ----
  ///
  /// 实机证据（Android 9 盒子）：同一域名下 `app.js`、`foot.js` 能加载成功，
  /// 而 `template-web.js` / `emojis.js` / `main.css` / `play.min.js` /
  /// `jx.wuzhoupai.com.wasm` 随机报 `net::ERR_CONNECTION_RESET` → 播放器起不来
  /// → 15s 超时。老 WebView 对每个子资源各开一条连接（无 HTTP/2 复用），
  /// 且加载失败后不会重试，于是「部分失败」必然拖垮整页。
  ///
  /// 方案：一旦某个 host 出现过加载失败，就把它标记为「不稳定」，此后该 host
  /// 的子资源改由 Dio 原生取回（自带重试、并自动走应用内代理设置），再回填给
  /// WebView。对现代 WebView 无影响（它们本来就很少失败）。
  static const int _maxResourceRetries = 6;
  static const int _maxAutoReloads = 3;
  static const Duration _resourceTimeout = Duration(seconds: 10);

  final Set<String> _flakyHosts = <String>{};
  bool _reloadScheduled = false;
  int _autoReloadCount = 0;
  Timer? _autoReloadTimer;
  Dio? _resourceDio;

  /// ---- ES2020 JS 降级（老 WebView 的第二道坎）----
  ///
  /// 第一道坎（上面的原生取回）解决后，实机日志仍然超时，但这次拿到了决定性证据：
  ///
  ///   I chromium: [INFO:CONSOLE(7)] "Uncaught SyntaxError: Unexpected token .",
  ///               source: .../jx/20230723ver/Play/artplayer.min.js (7)
  ///
  /// 用 acorn 按 ES2018（Chrome 66 的能力上限）解析该文件，报错位置完全一致：
  ///   Unexpected token (7:147582)
  ///   ...const r=t.$parentItem?.selector||this.option;...
  ///
  /// 整个 165KB 的 artplayer.min.js 里**只有这 1 处** optional chaining，但 V8 的
  /// 解析是整文件失败 → `ArtPlayer` 从未被定义 → 播放器起不来 → 页面上永远没有
  /// `<video>` → 嗅探 13s 超时。同一站点另外 7 个 JS 全部是 Chrome 66 兼容的。
  ///
  /// 所以：一旦控制台报出 `SyntaxError`，就打开降级开关并重载一次，
  /// 此后该页面的 JS 子资源都走原生取回并做 ES2020→ES5 改写
  /// （见 `lib/webview/video/js_downlevel.dart`，算法已用 acorn + node
  /// 运行等价性测试验证过）。对现代 WebView 完全无影响——它根本走不到这里。
  bool _downlevelJs = false;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSize: const Size(360, 640),
        initialSettings: InAppWebViewSettings(
          userAgent: getRandomUA(),
          mediaPlaybackRequiresUserGesture: true,
          upgradeKnownHostsToHTTPS: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        ),
        onWebViewCreated: (controller) {
          print('[WebView] Created (legacy fallback)');
          webviewController = controller;
          initEventController.add(true);
        },
        shouldInterceptRequest: (controller, request) async {
          final url = request.url.toString();
          final lower = url.toLowerCase();

          // A. 视频地址原生嗅探（保持原有行为）
          if (!useLegacyParser && !isVideoSourceLoaded) {
            if (!_isAdUrl(lower) &&
                (_isM3U8Url(lower) ||
                    _isRangeVideoRequest(lower, request.headers))) {
              logEventController.add('Native intercepted video URL: $url');
              isIframeLoaded = true;
              isVideoSourceLoaded = true;
              videoLoadingEventController.add(false);
              unloadPage();
              notifyVideoSourceResolved(url);
              return null;
            }
          }

          // B. 「不稳定 host」的子资源改由原生取回（带重试），再回填给 WebView；
          //    打开 JS 降级后，脚本资源无论 host 是否不稳定都走这条路
          final bool scriptNeedsDownlevel =
              _downlevelJs && JsDownlevel.urlLooksLikeScript(url);
          if (!isVideoSourceLoaded &&
              (request.method ?? 'GET').toUpperCase() == 'GET' &&
              request.isForMainFrame != true &&
              !_isMediaStreamRequest(lower, request.headers) &&
              (_flakyHosts.contains(request.url.host) ||
                  scriptNeedsDownlevel)) {
            return _fetchResourceNatively(url, request.headers);
          }
          return null;
        },
        onLoadStart: (controller, url) async {
          logEventController.add('started loading: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStart();
          }
        },
        onLoadStop: (controller, url) async {
          logEventController.add('loading completed: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStop();
          }
        },
        onConsoleMessage: (controller, consoleMessage) {
          final String message = consoleMessage.message;
          logEventController.add(
              'Console [${consoleMessage.messageLevel}]: $message');
          // 老 WebView 解析不了现代语法时，控制台会报 SyntaxError。
          // 这是「页面脚本被整体丢弃」的唯一可靠信号，用它来开启降级并重载一次。
          if (!_downlevelJs && message.contains('SyntaxError')) {
            _downlevelJs = true;
            logEventController.add(
                'WebView: 检测到脚本语法错误（老 WebView 不支持 ES2020），已开启 JS 降级');
            _scheduleAutoReload();
          }
        },
        onReceivedError: (controller, request, error) {
          logEventController
              .add('Error: ${error.description} - ${request.url}');
          _markFlakyHost(request.url.host, error.description ?? 'load error');
        },
      ),
    );
    await headlessWebView?.run();
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    if (!hasRegisteredHandlers) {
      _addJavaScriptHandlers(useLegacyParser);
      hasRegisteredHandlers = true;
    }
    count = 0;
    this.offset = offset;
    this.useLegacyParser = useLegacyParser;
    // 每次新的解析从头开始计重载预算；_flakyHosts 故意保留，
    // 这样同一来源的下一集可以直接走原生取回，不再付首次失败的代价。
    _autoReloadCount = 0;
    _reloadScheduled = false;
    _autoReloadTimer?.cancel();
    _autoReloadTimer = null;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _addJavaScriptHandlers(bool useLegacyParser) {
    logEventController.add('Adding LogBridge handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'LogBridge',
        callback: (args) {
          String message = args[0].toString();
          if (message.contains('about:blank')) {
            return;
          }
          logEventController.add(message);
        });

    if (useLegacyParser) {
      logEventController.add('Adding JSBridgeDebug handler');
      webviewController?.addJavaScriptHandler(
          handlerName: 'JSBridgeDebug',
          callback: (args) {
            String message = args[0].toString();
            logEventController.add('Callback received: $message');
            logEventController.add(
                'If there is audio but no video, please report it to the rule developer.');
            if ((message.contains('http') || message.startsWith('//')) &&
                !message.contains('googleads') &&
                !message.contains('googlesyndication.com') &&
                !message.contains('prestrain.html') &&
                !message.contains('prestrain%2Ehtml') &&
                !message.contains('adtrafficquality')) {
              logEventController.add('Parsing video source $message');
              String encodedUrl = Uri.encodeFull(message);
              if (decodeVideoSource(encodedUrl) != encodedUrl) {
                isIframeLoaded = true;
                isVideoSourceLoaded = true;
                videoLoadingEventController.add(false);
                logEventController.add(
                    'Loading video source ${decodeVideoSource(encodedUrl)}');
                unloadPage();
                final videoUrl = decodeVideoSource(encodedUrl);
                notifyVideoSourceResolved(videoUrl);
              }
            }
          });
    } else {
      logEventController.add('Adding VideoBridgeDebug handler');
      webviewController?.addJavaScriptHandler(
          handlerName: 'VideoBridgeDebug',
          callback: (args) {
            String message = args[0].toString();
            logEventController.add('Callback received: $message');
            if (message.contains('http') && !isVideoSourceLoaded) {
              logEventController.add('Loading video source: $message');
              isIframeLoaded = true;
              isVideoSourceLoaded = true;
              videoLoadingEventController.add(false);
              unloadPage();
              notifyVideoSourceResolved(message);
            }
          });
    }
  }

  Future<void> _onLoadStart() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting blob parser script (onLoadStart)');
      // 用 IIFE + 幂等守卫包起来：onLoadStart/onLoadStop 会因子 iframe 加载完成
      // 而在同一文档里重复触发，顶层 `const` 二次声明会抛
      // "SyntaxError: Identifier '...' has already been declared"，
      // 导致整段注入脚本被丢弃（实机日志里确实出现过）。
      await webviewController?.evaluateJavascript(source: """
        (function() {
        if (window.__kazumiBlobParserInstalled) return;
        window.__kazumiBlobParserInstalled = true;
        try { window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href); } catch(e) {}
        const _r_text = window.Response.prototype.text;
        window.Response.prototype.text = function () {
            return new Promise((resolve, reject) => {
                _r_text.call(this).then((text) => {
                    resolve(text);
                    if (text.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + this.url);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                    }
                }).catch(reject);
            });
        }

        const _open = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function (...args) {
            this.addEventListener("load", () => {
                try {
                    let content = this.responseText;
                    if (content.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + args[1]);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                    };
                } catch {}
            });
            return _open.apply(this, args);
        };

        function injectIntoIframe(iframe) {
          try {
            const iframeWindow = iframe.contentWindow;
            if (!iframeWindow) return;

            const iframe_r_text = iframeWindow.Response.prototype.text;
            iframeWindow.Response.prototype.text = function () {
              return new Promise((resolve, reject) => {
                iframe_r_text.call(this).then((text) => {
                  resolve(text);
                  if (text.trim().startsWith("#EXTM3U")) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + this.url);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                  }
                }).catch(reject);
              });
            }

            const iframe_open = iframeWindow.XMLHttpRequest.prototype.open;
            iframeWindow.XMLHttpRequest.prototype.open = function (...args) {
              this.addEventListener("load", () => {
                try {
                  let content = this.responseText;
                  if (content.trim().startsWith("#EXTM3U") && args[1] !== null && args[1] !== undefined) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + args[1]);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                  };
                } catch {}
              });
              return iframe_open.apply(this, args);
            }
          } catch (e) {
            console.error('iframe inject failed:', e);
          }
        }

        function setupIframeListeners() {
          document.querySelectorAll('iframe').forEach(iframe => {
            if (iframe.contentDocument) {
              injectIntoIframe(iframe);
            }
            iframe.addEventListener('load', () => injectIntoIframe(iframe));
          });

          const observer = new MutationObserver(mutations => {
            mutations.forEach(mutation => {
              if (mutation.type === 'childList') {
                mutation.addedNodes.forEach(node => {
                  if (node.nodeName === 'IFRAME') {
                    node.addEventListener('load', () => injectIntoIframe(node));
                  }
                  if (node.querySelectorAll) {
                    node.querySelectorAll('iframe').forEach(iframe => {
                      iframe.addEventListener('load', () => injectIntoIframe(iframe));
                    });
                  }
                });
              }
            });
          });

          if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true });
          } else {
            document.addEventListener('DOMContentLoaded', () => {
              observer.observe(document.body, { childList: true, subtree: true });
            });
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupIframeListeners);
        } else {
          setupIframeListeners();
        }
        })();
      """);
    }
  }

  Future<void> _onLoadStop() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting video tag parser script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
        (function() {
        if (window.__kazumiVideoTagParserInstalled) return;
        window.__kazumiVideoTagParserInstalled = true;
        window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);
        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for video elements...');
          for (const mutation of mutations) {
            if (mutation.type === "attributes" && mutation.target.nodeName === "VIDEO") {
              if (processVideoElement(mutation.target)) return;
              continue;
            }
            for (const node of mutation.addedNodes) {
              if (node.nodeName === "VIDEO") {
                if (processVideoElement(node)) return;
              }
              if (node.querySelectorAll) {
                for (const video of node.querySelectorAll("video")) {
                  if (processVideoElement(video)) return;
                }
              }
            }
          }
        });
        function processVideoElement(video) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
          let src = video.getAttribute('src');
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
            _observer.disconnect();
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
            return true;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              _observer.disconnect();
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return true;
            }
          }
        }

        function setupVideoProcessing() {
          for (const video of document.querySelectorAll("video")) {
            if (processVideoElement(video)) return;
          }
          _observer.observe(document.body, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['src']
          });
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupVideoProcessing);
        } else {
          setupVideoProcessing();
        }
        })();
      """);
    }

    if (useLegacyParser) {
      logEventController.add('Injecting JSBridgeDebug script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
        (function() {
        if (window.__kazumiIframeParserInstalled) return;
        window.__kazumiIframeParserInstalled = true;
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        function processIframeElement(iframe) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Processing iframe element');
          let src = iframe.getAttribute('src');
          if (src) {
            window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
          }
        }

        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for iframes...');
          mutations.forEach(mutation => {
            if (mutation.type === 'attributes' && mutation.target.nodeName === 'IFRAME') {
              processIframeElement(mutation.target);
            } else {
              mutation.addedNodes.forEach(node => {
                if (node.nodeName === 'IFRAME') processIframeElement(node);
                if (node.querySelectorAll) {
                  node.querySelectorAll('iframe').forEach(processIframeElement);
                }
              });
            }
          });
        });

        _observer.observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src']
        });
        })();
      """);
    }

    _startVideoParserTimer();
  }

  void _startVideoParserTimer() {
    videoParserTimer?.cancel();
    logEventController.add('Starting video parser timer');
    videoParserTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (isVideoSourceLoaded) {
        timer.cancel();
        return;
      }
      _pollVideoSource();
    });
  }

  Future<void> _pollVideoSource() async {
    if (isVideoSourceLoaded) return;

    if (useLegacyParser) {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          var iframes = document.querySelectorAll('iframe');
          window.flutter_inappwebview.callHandler('LogBridge', 'Timer scan: found ' + iframes.length + ' iframe(s)');
          for (var i = 0; i < iframes.length; i++) {
            var src = iframes[i].getAttribute('src');
            if (src) {
              window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
            }
          }
        })();
      """);
    } else {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          var videos = document.querySelectorAll('video');
          window.flutter_inappwebview.callHandler('LogBridge', 'Timer scan: found ' + videos.length + ' video element(s)');
          for (var i = 0; i < videos.length; i++) {
            var src = videos[i].getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return;
            }
            var sources = videos[i].getElementsByTagName('source');
            for (var j = 0; j < sources.length; j++) {
              src = sources[j].getAttribute('src');
              if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
                window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
                return;
              }
            }
          }
        })();
      """);
    }
  }

  @override
  Future<void> unloadPage() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    _autoReloadTimer?.cancel();
    _autoReloadTimer = null;
    _reloadScheduled = false;
    await webviewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri("about:blank")));
  }

  @override
  Future<void> dispose() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    _autoReloadTimer?.cancel();
    _autoReloadTimer = null;
    await headlessWebView?.dispose();
    headlessWebView = null;
    webviewController = null;
    _resourceDio?.close(force: false);
    _resourceDio = null;
    disposeEventControllers();
  }

  // ---------------------------------------------------------------------------
  // 原生资源代理
  // ---------------------------------------------------------------------------

  Dio _ensureResourceDio() => _resourceDio ??= DioFactory.createForConfig(
        NetworkConfig.fromSettings(
          connectTimeout: _resourceTimeout,
          receiveTimeout: _resourceTimeout,
        ).copyWith(enableLog: false),
      );

  /// 原生取回单个子资源，失败自动重试。全部失败返回 null（交回 WebView 自己加载）。
  Future<WebResourceResponse?> _fetchResourceNatively(
      String url, Map<String, String>? requestHeaders) async {
    final dio = _ensureResourceDio();
    final accept = requestHeaders?['Accept'] ?? requestHeaders?['accept'];
    final referer = requestHeaders?['Referer'] ?? requestHeaders?['referer'];

    for (var attempt = 0; attempt < _maxResourceRetries; attempt++) {
      if (isVideoSourceLoaded) return null;
      try {
        final resp = await dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
            headers: {
              'user-agent': getRandomUA(),
              if (accept != null) 'accept': accept,
              if (referer != null) 'referer': referer,
            },
          ),
        );
        final data = resp.data;
        if (data == null || data.isEmpty) {
          continue;
        }
        var bytes = data is Uint8List ? data : Uint8List.fromList(data);
        if (_downlevelJs && JsDownlevel.urlLooksLikeScript(url)) {
          bytes = _downlevelScript(url, bytes);
        }
        logEventController.add(
            'Native resource proxy OK: $url (${bytes.length}B, try ${attempt + 1})');
        return WebResourceResponse(
          contentType:
              _contentTypeFor(url, resp.headers.map['content-type']?.first),
          contentEncoding: 'utf-8',
          statusCode: 200,
          reasonPhrase: 'OK',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-cache',
          },
          data: bytes,
        );
      } catch (e) {
        if (attempt >= _maxResourceRetries - 1) {
          logEventController.add('Native resource proxy FAILED: $url ($e)');
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
      }
    }
    return null;
  }

  /// 对脚本做 ES2020→ES5 降级；任何不确定的情况都原样返回（fail-safe）。
  Uint8List _downlevelScript(String url, Uint8List bytes) {
    try {
      final Uint8List? out = JsDownlevel.downlevelBytes(bytes);
      if (out == null) {
        return bytes;
      }
      logEventController.add('WebView: JS 降级生效 $url '
          '(${bytes.length}B -> ${out.length}B)');
      return out;
    } catch (e) {
      logEventController.add('WebView: JS 降级失败（保持原样）$url ($e)');
      return bytes;
    }
  }

  String _contentTypeFor(String url, String? serverContentType) {
    if (serverContentType != null && serverContentType.isNotEmpty) {
      return serverContentType.split(';').first.trim();
    }
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.js')) return 'application/javascript';
    if (path.endsWith('.css')) return 'text/css';
    if (path.endsWith('.json')) return 'application/json';
    if (path.endsWith('.wasm')) return 'application/wasm';
    if (path.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.woff')) return 'font/woff';
    if (path.endsWith('.woff2')) return 'font/woff2';
    return 'application/octet-stream';
  }

  /// 流媒体请求（m3u8 / 分片 / 带 Range）不接管，交给播放器自己处理，
  /// 避免把视频流拖进 Dart 层。
  bool _isMediaStreamRequest(String lower, Map<String, String>? headers) {
    if (headers != null) {
      final range = headers['Range'] ?? headers['range'];
      if (range != null && range.startsWith('bytes=')) return true;
    }
    final path = Uri.tryParse(lower)?.path.toLowerCase() ?? '';
    const exts = ['.m3u8', '.ts', '.m4s', '.mp4', '.flv', '.mpd', '.key'];
    for (final ext in exts) {
      if (path.endsWith(ext)) return true;
    }
    return false;
  }

  void _markFlakyHost(String host, String reason) {
    if (host.isEmpty) return;
    final isNew = _flakyHosts.add(host);
    if (!isNew) return;
    logEventController.add('WebView: 标记不稳定 host -> $host ($reason)');
    _scheduleAutoReload();
  }

  /// 首次踩到失败时重载一次页面，让后续请求走原生代理。
  void _scheduleAutoReload() {
    if (useLegacyParser || isVideoSourceLoaded) return;
    if (_reloadScheduled || _autoReloadCount >= _maxAutoReloads) return;
    _reloadScheduled = true;
    _autoReloadCount++;
    logEventController
        .add('WebView: 计划自动重载以重试失败资源 (第 $_autoReloadCount 次)');
    _autoReloadTimer?.cancel();
    _autoReloadTimer = Timer(const Duration(milliseconds: 1500), () {
      _reloadScheduled = false;
      if (isVideoSourceLoaded) return;
      webviewController?.reload();
    });
  }

  bool _isM3U8Url(String lower) {
    final uri = Uri.tryParse(lower);
    if (uri == null) return false;
    return uri.path.endsWith('.m3u8');
  }

  bool _isRangeVideoRequest(String lower, Map<String, String>? headers) {
    if (headers == null) return false;
    final range = headers['Range'] ?? headers['range'];
    if (range == null || !range.startsWith('bytes=')) return false;
    if (lower.endsWith('.js') ||
        lower.endsWith('.css') ||
        lower.endsWith('.html') ||
        lower.endsWith('.json') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.woff') ||
        lower.endsWith('.woff2') ||
        lower.endsWith('.wasm')) {
      return false;
    }
    return true;
  }

  bool _isAdUrl(String lower) {
    return lower.contains('googleads') ||
        lower.contains('googlesyndication') ||
        lower.contains('adtrafficquality') ||
        lower.contains('doubleclick');
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      final proxyAvailable =
          await android_webview.AndroidWebViewFeature.instance()
              .isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
      if (!proxyAvailable) {
        KazumiLogger().w('WebView: 当前 Android 版本不支持代理');
        return;
      }

      final proxyController = android_webview.AndroidProxyController.instance();
      await proxyController.clearProxyOverride();
      await proxyController.setProxyOverride(
        settings: ProxySettings(
          proxyRules: [
            ProxyRule(url: formattedProxy),
          ],
        ),
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }
}
