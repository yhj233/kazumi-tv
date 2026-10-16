import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';

/// 本地媒体代理：让 mpv 只与本地环回说**明文 HTTP**，真正的 HTTPS
/// 交由系统 TLS 栈（Dart 的 [HttpClient]，与 `curl` 同属 BoringSSL 家族）完成。
///
/// ## 为什么需要它
///
/// 安卓 9 电视盒子（MGV3201-ZG，WebView 为 Chrome 66）上，libmpv 自带的
/// mbedtls 打开这些字节系 CDN 的 HTTPS 直链时会长时间卡住：实测 `open` 只花
/// 130~560ms 就返回，但 mpv 的 demuxer **永远不会建立** —— `file-format` /
/// `duration` / `paused-for-cache` / `cache-buffering-state` 四个属性恒为
/// empty，最终在 217 秒后抛出
/// `tls: mbedtls_ssl_handshake returned -0x7280`
/// （`MBEDTLS_ERR_SSL_CONN_EOF`，即握手期间被对端关闭）。
///
/// 而**同一个 URL、同一时刻**，用系统 TLS 栈在盒子上稳定跑到 2.9~6.4 MB/s，
/// `206 video/mp4` 秒回。所以瓶颈在 libmpv 自带的那套 TLS/HTTP 实现，
/// 与 Android 版本、机型、网络带宽都无关 —— mbedtls 是随 libmpv 一起编译
/// 打包进 `.so` 的，跟系统版本没有任何关系。
///
/// ## 做法
///
/// 把远端地址映射成 `http://127.0.0.1:<port>/p/<base64url(原始地址)>`，
/// 由本代理用 [HttpClient] 真正取数，并把 `Range`、`Content-Length`、
/// `Content-Range` 等头部**原样透传**，以保住 mpv 的 seek 与断点续传语义。
///
/// 该方案不依赖机型、不依赖系统版本、不需要 root（只监听环回地址），
/// 也不修改任何插件源，符合本项目「广泛适用」的要求。
class LocalMediaProxy {
  LocalMediaProxy._();

  static final LocalMediaProxy instance = LocalMediaProxy._();

  /// 总开关。置 `false` 时 [map] 原样返回输入，便于做 A/B 对照。
  bool enabled = true;

  /// 路径前缀，用于把代理请求与其它请求区分开。
  static const String _prefix = 'p';

  static const Duration _connectTimeout = Duration(seconds: 15);

  /// 需要原样透传给 mpv 的响应头。
  ///
  /// `Content-Length` / `Content-Range` 必须与上游严格一致，否则 mpv 计算
  /// 出的偏移会错位，表现为 seek 失败或播放中断。
  static const List<String> _passThroughHeaders = <String>[
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentLengthHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.cacheControlHeader,
  ];

  /// 需要从 mpv 的请求里转发给上游的请求头。
  static const List<String> _forwardHeaders = <String>[
    HttpHeaders.rangeHeader,
    HttpHeaders.ifRangeHeader,
    HttpHeaders.ifModifiedSinceHeader,
    HttpHeaders.ifNoneMatchHeader,
    HttpHeaders.userAgentHeader,
    HttpHeaders.refererHeader,
  ];

  HttpServer? _server;
  HttpClient? _client;
  Future<int>? _starting;

  bool get isRunning => _server != null;

  /// 确保代理已开始监听，返回其端口。
  Future<int> ensureStarted() {
    final server = _server;
    if (server != null) {
      return Future<int>.value(server.port);
    }
    final pending = _starting;
    if (pending != null) {
      return pending;
    }
    final future = _start();
    _starting = future;
    return future;
  }

  Future<int> _start() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = _connectTimeout
        ..idleTimeout = const Duration(seconds: 60)
        // 媒体是二进制流，禁掉自动解压才能让 Content-Length /
        // Content-Range 与上游严格一致。
        ..autoUncompress = false
        ..connectionFactory = _openConnection;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _client = client;
      _server = server;
      server.listen(_handle, onError: (Object error) {
        KazumiLogger().w('LocalMediaProxy: 监听出错 | $error');
      });
      KazumiLogger().e('LocalMediaProxy: 已就绪 http://127.0.0.1:${server.port}');
      return server.port;
    } catch (error) {
      // 失败后清掉进行中的 Future，让后续调用可以重试。
      _starting = null;
      KazumiLogger().w('LocalMediaProxy: 启动失败 | $error');
      rethrow;
    }
  }

  /// 建立到上游的连接。**IPv4 优先**。
  ///
  /// 本网络的 IPv6 出口实测质量极差（ICMPv6 可达，但 TCP 吞吐只有
  /// 0.5 KB/s 量级），而 IPv4 稳定在数 MB/s。系统的 `getaddrinfo` 默认会
  /// 把 IPv6 排在前面，这里显式把它挪到后面。
  Future<ConnectionTask<Socket>> _openConnection(
      Uri uri, String? proxyHost, int? proxyPort) async {
    try {
      final addresses = await InternetAddress.lookup(uri.host);
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4) {
          return Socket.startConnect(address, uri.port,
              timeout: _connectTimeout);
        }
      }
    } catch (_) {
      // 解析失败则退回默认行为，让 HttpClient 自己产生并上报错误。
    }
    return Socket.startConnect(uri.host, uri.port, timeout: _connectTimeout);
  }

  /// 把远端媒体地址映射成本地代理地址；非 http(s) 地址原样返回。
  Future<String> map(String rawUrl) async {
    if (!enabled || rawUrl.isEmpty) {
      return rawUrl;
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return rawUrl;
    }
    final port = await ensureStarted();
    // 去掉 `=` 填充：base64url 的字符集在 URL path 段里最省心。
    final payload = base64Url.encode(utf8.encode(rawUrl)).replaceAll('=', '');
    // 末尾保留 `/`：这样即使上游是 m3u8、播放列表里写的是相对分片路径，
    // mpv 也会把分片拼在 `/p/<payload>/` 之后，代理才能还原出正确地址。
    return 'http://127.0.0.1:$port/$_prefix/$payload/';
  }

  /// 从代理请求里还原出真正的上游地址；不是代理请求则返回 `null`。
  String? resolveTarget(Uri requestUri) {
    final segments = requestUri.pathSegments;
    if (segments.length < 2 || segments.first != _prefix) {
      return null;
    }
    try {
      // `base64.normalize` 会补回填充并把 base64url 字母表转成标准字母表。
      final base = utf8.decode(base64.decode(base64.normalize(segments[1])));
      if (segments.length == 2) {
        return base;
      }
      // m3u8 之类的相对分片路径：先按上游地址所在目录解析，再原样带回 query。
      final resolved = Uri.parse(base).resolve(segments.sublist(2).join('/'));
      return requestUri.query.isEmpty
          ? resolved.toString()
          : resolved.replace(query: requestUri.query).toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final target = resolveTarget(request.uri);
      final client = _client;
      if (target == null || client == null) {
        response.statusCode =
            target == null ? HttpStatus.notFound : HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      final upstreamRequest =
          await client.openUrl(request.method, Uri.parse(target));
      upstreamRequest
        ..followRedirects = true
        ..maxRedirects = 5;
      for (final name in _forwardHeaders) {
        final value = request.headers.value(name);
        if (value != null) {
          upstreamRequest.headers.set(name, value);
        }
      }
      final upstreamResponse = await upstreamRequest.close();
      response.statusCode = upstreamResponse.statusCode;
      for (final name in _passThroughHeaders) {
        final value = upstreamResponse.headers.value(name);
        if (value != null) {
          response.headers.set(name, value);
        }
      }
      await upstreamResponse.pipe(response);
    } catch (error) {
      try {
        if (!response.headersSent) {
          response.statusCode = HttpStatus.badGateway;
        }
        await response.close();
      } catch (_) {
        // 连接早已断开，无需再处理。
      }
    }
  }
}
