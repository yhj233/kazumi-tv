import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/utils/http_headers.dart';

/// 单个页面最多尝试的候选媒体地址数（逐个真实请求校验）。
const int _maxProbes = 3;

/// 单次解析中允许拉取的页面数上限（播放页 + 若干层 iframe）。
const int _maxPageFetches = 4;

/// 每个页面最多跟进的 iframe 数。
const int _maxIframesPerPage = 2;

/// 采纳 mp4 等直链所需的最低得分。
///
/// 解析播放器（JX）页面里常带广告位直链，例如
/// `'Kpadmp4': "https://.../Play/adposter.mp4"`——这类地址没有任何
/// 播放器配置上下文（得分仅为基础分 10），必须拒掉，否则会播出广告。
/// 真实正片直链通常紧跟在 `url:` / `file:` / `src=` 之后（≥50 分）。
const int _mp4MinScore = 50;

/// 「直取」阶段的总时间预算上限。
const Duration _maxDirectBudget = Duration(seconds: 8);

/// 连接/读取层的单次超时。
const Duration _connectTimeout = Duration(seconds: 6);
const Duration _readTimeout = Duration(seconds: 8);

/// 视频源「原生直取」解析器。
///
/// 背景：部分设备（典型如 Android 9 电视盒子）系统 WebView 过旧
/// （Chrome 66），而现代规则站点普遍使用 `artplayer 5.x`、`hls.js 1.x`
/// 等依赖 ES2020 语法（可选链 `?.`、空值合并 `??`）的播放器库。旧 WebView
/// 解析脚本时直接抛 `SyntaxError`，播放器无法初始化，页面因此**永远不会
/// 发出 m3u8 请求**——此时无论等多久，WebView 嗅探都必然超时。
///
/// 本解析器绕开 WebView 与 JS 引擎：直接用 HTTP 拉取播放页 HTML，从
/// 「播放器配置 / 资源链接」中正则提取 m3u8 / mp4 地址，并**真实请求一次
/// 候选地址**确认可用（m3u8 校验是否以 `#EXTM3U` 开头，mp4 校验状态码与
/// 类型），因此对 WebView 版本、JS 语法、页面脚本错误完全不敏感。
///
/// 设计约束（保证「行为不劣化」）：
/// - 命中即返回，耗时通常 1~3 秒（对比 WebView 嗅探最长 15 秒）。
/// - 任何一步失败（页面打不开、没提取到、校验不通过、超预算）都返回
///   `null`，由调用方回退到原有 WebView 嗅探，绝不抛异常打断流程。
/// - 页面可能把地址写在 `url: '...'`、`"url":"..."`、`player_aaaa` 配置、
///   `<source src=...>`、`//cdn/...` 协议相对、`/vod/...` 相对路径、
///   JSON 转义斜杠（`https:\/\/...`）以及「解析型」地址（`?url=<媒体地址>`）
///   里，以上形态都已覆盖。
/// - 播放页把播放器放在同域 iframe 中时，会继续拉取 iframe（最多 2 个/页，
///   旧解析器模式下可下钻 2 层），以便覆盖 iframe 型规则站点。
/// - 防误伤：广告/统计资源被过滤；mp4 直链必须处在明确的播放器配置上下文
///   （见 [_mp4MinScore]），避免把解析播放器页面里的广告位当正片。若站点把
///   地址藏在 JS 运行时（需执行脚本才能拿到），直取会失败并回退 WebView。
class DirectVideoSourceResolver {
  Dio? _dio;
  CancelToken? _activeToken;

  Dio get _client => _dio ??= DioFactory.createForConfig(
        NetworkConfig.fromSettings(
          connectTimeout: _connectTimeout,
          receiveTimeout: _readTimeout,
        ).copyWith(enableLog: false),
      );

  /// 尝试直取。[episodeUrl] 为集数播放页地址。
  ///
  /// 返回解析结果；不适合直取或直取失败时返回 `null`（调用方回退 WebView）。
  Future<VideoSource?> tryResolve(
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
  }) async {
    final pageUri = Uri.tryParse(episodeUrl);
    if (pageUri == null ||
        !pageUri.hasScheme ||
        (pageUri.scheme != 'http' && pageUri.scheme != 'https') ||
        pageUri.host.isEmpty) {
      return null;
    }

    // 直取必须给 WebView 回退留出足够时间，因此预算同时受总超时约束。
    final half = Duration(milliseconds: (timeout.inMilliseconds * 0.6).round());
    final budget = half < _maxDirectBudget ? half : _maxDirectBudget;
    if (budget <= Duration.zero) return null;

    final stopwatch = Stopwatch()..start();
    final token = CancelToken();
    _activeToken = token;

    var fetches = 0;
    final visited = <String>{};
    final queue = <({Uri uri, int depth})>[(uri: pageUri, depth: 0)];
    final maxDepth = useLegacyParser ? 2 : 1;

    try {
      final headers = _defaultHeaders(pageUri);

      while (queue.isNotEmpty) {
        if (stopwatch.elapsed >= budget || fetches >= _maxPageFetches) break;

        final item = queue.removeAt(0);
        if (!visited.add(item.uri.toString())) continue;
        fetches++;

        final html = await _fetchText(
          item.uri,
          headers: headers,
          token: token,
          timeout: _remaining(budget, stopwatch),
        );
        if (html == null) continue;

        final candidates =
            DirectVideoSourceExtractor.rankCandidates(html, item.uri);
        if (candidates.isNotEmpty) {
          KazumiLogger().d(
              'DirectVideoSource: candidates@${item.uri} -> '
              '${candidates.take(_maxProbes).join(' | ')}');
        }

        for (final candidate in candidates.take(_maxProbes)) {
          if (stopwatch.elapsed >= budget) break;
          final ok = await _probe(
            candidate,
            headers: headers,
            token: token,
            timeout: _remaining(budget, stopwatch),
          );
          if (!ok) continue;

          KazumiLogger().i(
              'DirectVideoSource: HIT ${candidate.toString()} '
              '(page=${item.uri}, depth=${item.depth}, ${stopwatch.elapsedMilliseconds}ms)');
          return VideoSource(
            url: candidate.toString(),
            offset: offset,
            type: VideoSourceType.online,
            format: DirectVideoSourceExtractor.formatOf(candidate),
          );
        }

        if (item.depth < maxDepth) {
          final frames =
              DirectVideoSourceExtractor.extractIframes(html, item.uri);
          for (final frame in frames) {
            queue.add((uri: frame, depth: item.depth + 1));
          }
        }
      }

      KazumiLogger().i(
          'DirectVideoSource: no usable media url (page=$episodeUrl, '
          'fetches=$fetches, ${stopwatch.elapsedMilliseconds}ms) -> fallback to WebView');
      return null;
    } catch (e) {
      // 直取是「尽力而为」：任何异常都不应影响原有 WebView 流程。
      KazumiLogger()
          .d('DirectVideoSource: aborted (${e.runtimeType}: $e) -> fallback to WebView');
      return null;
    } finally {
      stopwatch.stop();
      if (identical(_activeToken, token)) {
        _activeToken = null;
      }
    }
  }

  /// 取消正在进行的直取请求（随播放页切换 / 下载任务取消触发）。
  void cancel() {
    final token = _activeToken;
    if (token != null && !token.isCancelled) {
      token.cancel('cancelled');
    }
  }

  Future<void> dispose() async {
    cancel();
    final dio = _dio;
    _dio = null;
    if (dio != null) {
      dio.close(force: true);
    }
  }

  Map<String, String> _defaultHeaders(Uri pageUri) {
    return {
      'user-agent': getRandomUA(),
      'accept-language': getRandomAcceptedLanguage(),
      'referer': '${pageUri.scheme}://${pageUri.authority}/',
    };
  }

  Duration _remaining(Duration budget, Stopwatch stopwatch) {
    final left = budget - stopwatch.elapsed;
    if (left < const Duration(seconds: 1)) return const Duration(seconds: 1);
    return left;
  }

  Future<String?> _fetchText(
    Uri url, {
    required Map<String, String> headers,
    required CancelToken token,
    required Duration timeout,
  }) async {
    try {
      final response = await _client.get<String>(
        url.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: token,
      );
      return response.data;
    } on DioException catch (e) {
      KazumiLogger().d(
          'DirectVideoSource: GET ${url.toString()} failed (${e.type} ${e.message})');
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> _probe(
    Uri url, {
    required Map<String, String> headers,
    required CancelToken token,
    required Duration timeout,
  }) async {
    if (DirectVideoSourceExtractor.isHlsUri(url)) {
      final body = await _fetchText(
        url,
        headers: headers,
        token: token,
        timeout: timeout,
      );
      // m3u8 是纯文本清单：以 #EXTM3U 开头即为有效，天然排除广告页 / 错误页。
      return body != null && body.trimLeft().startsWith('#EXTM3U');
    }
    return _probeBinary(
      url,
      headers: headers,
      token: token,
      timeout: timeout,
    );
  }

  /// mp4 等二进制资源：只取响应头，不读取响应体，避免把整个视频读进内存。
  Future<bool> _probeBinary(
    Uri url, {
    required Map<String, String> headers,
    required CancelToken token,
    required Duration timeout,
  }) async {
    ResponseBody? body;
    try {
      final response = await _client.get<ResponseBody>(
        url.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: {...headers, 'range': 'bytes=0-1'},
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: token,
      );
      body = response.data;
      final status = response.statusCode ?? 0;
      final contentType =
          (response.headers.value('content-type') ?? '').toLowerCase();
      if (status == 206) return true;
      return contentType.contains('video') ||
          contentType.contains('mp4') ||
          contentType.contains('octet-stream') ||
          contentType.contains('mpegurl');
    } on DioException catch (e) {
      KazumiLogger().d(
          'DirectVideoSource: probe ${url.toString()} failed (${e.type} ${e.message})');
      return false;
    } catch (e) {
      return false;
    } finally {
      try {
        await body?.stream.listen(null).cancel();
      } catch (_) {
        // 断开探测连接时的异常无需处理。
      }
    }
  }
}

/// 从播放页 HTML 中提取候选媒体地址（纯函数，无 IO，便于单独验证）。
class DirectVideoSourceExtractor {
  DirectVideoSourceExtractor._();

  /// 绝对地址：`https://host/path/index.m3u8?sign=x`。
  ///
  /// 字符类排除引号与括号，保证匹配不会跨过字符串边界（避免在压缩 JS 中
  /// 吞掉大段无关内容）。
  static final RegExp _absolutePattern = RegExp(
    r'''https?://[^\s"'<>\\()\[\]{}]{0,2000}?\.(?:m3u8|mp4)(?:\?[^\s"'<>\\()\[\]{}]{0,1500})?''',
    caseSensitive: false,
  );

  /// 协议相对地址：`//cdn.host/index.m3u8`（前面不能是 `:` 或 `/`，否则
  /// 会重复匹配绝对地址内部的 `//`）。
  static final RegExp _protocolRelativePattern = RegExp(
    r'''(?<![:/\w])//[^\s"'<>\\()\[\]{}]{0,2000}?\.(?:m3u8|mp4)(?:\?[^\s"'<>\\()\[\]{}]{0,1500})?''',
    caseSensitive: false,
  );

  /// 相对地址：`"url":"/vod/1/index.m3u8"`、`'vod/1/index.m3u8'`。
  ///
  /// 排除 `:` 以免再次命中绝对地址；排除 `%` 以免把「解析型」地址里
  /// URL 编码的内层地址（`https%3A%2F%2Fcdn.x%2Fi.m3u8`）当成相对路径。
  static final RegExp _relativePattern = RegExp(
    r'''(?<=["'(\s=])/?[^\s"'<>\\()\[\]{}:%]{1,2000}?\.(?:m3u8|mp4)(?:\?[^\s"'<>\\()\[\]{}]{0,1500})?''',
    caseSensitive: false,
  );

  static final RegExp _iframeTagPattern = RegExp(
    r'''<iframe[^>]*?\ssrc\s*=\s*["']?([^"'\s>]+)''',
    caseSensitive: false,
  );

  /// 「播放器配置上下文」：`url:` / `file:` / `src=` / `source:` 等，紧贴
  /// 候选地址之前。这类位置的地址几乎一定是当前集的正片地址。
  static final RegExp _configContextPattern = RegExp(
    r'''(?:url|file|src|source|video|play|m3u8|m3u|hls|link|path|vid)\s*["']?\s*[:=]\s*["']?\s*$''',
    caseSensitive: false,
  );

  /// 常见播放器 / 苹果 CMS 配置变量名。
  static final RegExp _playerHintPattern = RegExp(
    r'player_aaaa|player_data|playerconfig|player_config|macplayer|artplayer|dplayer|videojs|source_',
    caseSensitive: false,
  );

  static const List<String> _blockedHostKeywords = [
    'googleads',
    'googlesyndication',
    'adtrafficquality',
    'doubleclick',
    'adservice',
    'adsystem',
  ];

  static const List<String> _nonPageSuffixes = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.svg',
    '.ico',
    '.css',
    '.js',
    '.json',
    '.woff',
    '.woff2',
    '.ttf',
  ];

  /// 明显的广告 / 预告片资源路径片段（解析播放器页面的广告位）。
  static const List<String> _adPathKeywords = [
    'adposter',
    '/ad/',
    'advert',
    'banner',
    'trailer',
    'promo',
  ];

  /// 对 [html] 中出现的媒体地址打分排序，去重后返回（最可能是正片的在前）。
  static List<Uri> rankCandidates(String html, Uri pageUri) {
    if (html.isEmpty) return const <Uri>[];

    final text = _normalizeForScan(html);
    final scored = <String, _ScoredUri>{};

    void push(Uri uri, int index, int bonus) {
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return;
      if (uri.host.isEmpty) return;
      if (_isBlockedHost(uri.host)) return;

      final path = uri.path.toLowerCase();
      // 兜底过滤：URL 编码的地址（`...%3A%2F%2F...`）不是可用的媒体地址。
      if (path.contains('%3a')) return;
      // 广告 / 预告片资源不采纳。
      if (_adPathKeywords.any((keyword) => path.contains(keyword))) return;

      final isHls = isHlsUri(uri);
      final score = _score(text, index, isHls) + bonus;
      // mp4 直链容易命中广告位（如解析页的 `Kpadmp4`），必须处在明确的
      // 播放器配置上下文里才采纳；m3u8 需通过 #EXTM3U 校验，不受此限制。
      if (!isHls && score < _mp4MinScore) return;

      final key = uri.toString();
      final existing = scored[key];
      if (existing == null || existing.score < score) {
        scored[key] = _ScoredUri(uri: uri, index: index, score: score);
      }
    }

    for (final match in _absolutePattern.allMatches(text)) {
      _pushRaw(match.group(0)!, match.start, pageUri, push);
    }
    for (final match in _protocolRelativePattern.allMatches(text)) {
      _pushRaw(match.group(0)!, match.start, pageUri, push);
    }
    for (final match in _relativePattern.allMatches(text)) {
      _pushRaw(match.group(0)!, match.start, pageUri, push);
    }

    final ordered = scored.values.toList()
      ..sort((a, b) {
        if (a.score != b.score) return b.score.compareTo(a.score);
        return a.index.compareTo(b.index);
      });
    return ordered.map((e) => e.uri).toList();
  }

  /// 提取页面里的 iframe 播放器地址（用于覆盖 iframe 型规则站点）。
  ///
  /// 只认 `<iframe ... src="...">` 标签：这正是旧版解析器扫描的对象，且能避免
  /// 把页面里其它 `.src = "..."` 赋值（统计脚本、图片等）误当成播放器。
  static List<Uri> extractIframes(String html, Uri pageUri) {
    if (html.isEmpty) return const <Uri>[];
    final text = _normalizeForScan(html);
    final results = <Uri>[];

    void consider(String? raw) {
      if (raw == null) return;
      if (results.length >= _maxIframesPerPage) return;
      final cleaned = _cleanUrl(raw);
      if (cleaned.isEmpty) return;
      final uri = _resolveRaw(cleaned, pageUri);
      if (uri == null || uri.host.isEmpty) return;
      final lower = uri.toString().toLowerCase();
      if (_nonPageSuffixes.any((suffix) => lower.contains(suffix))) return;
      if (results.contains(uri)) return;
      results.add(uri);
    }

    for (final match in _iframeTagPattern.allMatches(text)) {
      consider(match.group(1));
      if (results.length >= _maxIframesPerPage) break;
    }
    return results;
  }

  /// 是否为 m3u8（HLS）地址。
  ///
  /// 只检查 path 与 query：避免把域名里恰好含有 `m3u` 的主机误判为 HLS。
  static bool isHlsUri(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.contains('.m3u8') || path.contains('.m3u')) return true;
    return uri.query.toLowerCase().contains('.m3u');
  }

  /// 已确认的媒体地址对应的格式提示。
  static VideoSourceFormat formatOf(Uri uri) =>
      isHlsUri(uri) ? VideoSourceFormat.hls : VideoSourceFormat.auto;

  static void _pushRaw(
    String raw,
    int index,
    Uri pageUri,
    void Function(Uri uri, int index, int bonus) push,
  ) {
    final cleaned = _cleanUrl(raw);
    if (cleaned.isEmpty) return;
    final uri = _resolveRaw(cleaned, pageUri);
    if (uri == null) return;
    push(uri, index, 0);

    // 「解析型」地址：`https://jx.a.com/?url=https%3A%2F%2Fcdn.b.com%2Fi.m3u8`
    // 内层才是真正的媒体地址，且旧版解析器同样取内层，因此额外以更高优先级
    // 加入内层候选（是否可用仍由后续真实请求校验决定）。
    final inner = _innerMediaFromQuery(uri);
    if (inner != null) {
      push(inner, index, 15);
    }
  }

  static Uri? _resolveRaw(String raw, Uri pageUri) {
    if (raw.startsWith('//')) {
      return Uri.tryParse('${pageUri.scheme}:$raw');
    }
    if (raw.startsWith('/')) {
      return Uri.tryParse(
          '${pageUri.scheme}://${pageUri.authority}$raw');
    }
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) return parsed;
    try {
      return pageUri.resolve(raw);
    } catch (_) {
      return null;
    }
  }

  /// 从 query 参数中找出内层媒体地址（含 URL 编码的形态）。
  static Uri? _innerMediaFromQuery(Uri uri) {
    if (!uri.hasQuery) return null;
    for (final entry in uri.queryParameters.entries) {
      final decoded = _safeDecode(entry.value);
      if (decoded == null) continue;
      final match = _absolutePattern.firstMatch(decoded);
      if (match == null) continue;
      final inner = Uri.tryParse(_cleanUrl(match.group(0)!));
      if (inner != null && inner.host.isNotEmpty) return inner;
    }
    return null;
  }

  static String? _safeDecode(String value) {
    if (!value.toLowerCase().contains('http')) return null;
    if (!value.toLowerCase().contains('.m3u')) return null;
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// 统一扫描前处理：还原 JSON 转义斜杠与 HTML 实体，使各种书写形态归一。
  static String _normalizeForScan(String html) {
    var text = html;
    if (text.contains(r'\/')) {
      text = text.replaceAll(r'\/', '/');
    }
    if (text.contains('&amp;') || text.contains('&#')) {
      text = text
          .replaceAll('&amp;', '&')
          .replaceAll('&#38;', '&')
          .replaceAll('&#x26;', '&')
          .replaceAll('&#X26;', '&');
    }
    return text;
  }

  static String _cleanUrl(String raw) {
    var value = raw.trim();
    while (value.isNotEmpty) {
      final last = value[value.length - 1];
      if (last == ',' ||
          last == ';' ||
          last == '.' ||
          last == ':' ||
          last == '\\') {
        value = value.substring(0, value.length - 1);
      } else {
        break;
      }
    }
    return value;
  }

  static bool _isBlockedHost(String host) {
    final lower = host.toLowerCase();
    return _blockedHostKeywords.any((keyword) => lower.contains(keyword));
  }

  static int _score(String text, int index, bool isHls) {
    final start = index - 72 < 0 ? 0 : index - 72;
    final prefix = text.substring(start, index);
    var score = isHls ? 40 : 10;
    if (_configContextPattern.hasMatch(prefix)) score += 40;
    if (_playerHintPattern.hasMatch(prefix)) score += 25;
    return score;
  }
}

class _ScoredUri {
  final Uri uri;
  final int index;
  final int score;

  const _ScoredUri({
    required this.uri,
    required this.index,
    required this.score,
  });
}
