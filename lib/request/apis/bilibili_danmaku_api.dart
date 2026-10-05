import 'package:dio/dio.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/danmaku.dart';

/// B 站（哔哩哔哩）直连弹幕来源。
///
/// **不需要任何 AppId / AppSecret** —— 这是相对 DanDanPlay 的核心优势
/// （后者自 2025-01 起强制应用认证，需要在 DevCenter 注册并人工审核）。
///
/// 代价是「番剧 → 剧集」的映射要自己做，流程：
///   1. `search/type?search_type=media_bangumi` 用番剧名搜 season
///   2. `pgc/view/web/season` 取该 season 的剧集列表（含每集 cid）
///   3. `x/v1/dm/list.so?oid=<cid>` 取该集弹幕 XML
///
/// 因此对「多季番剧 / 剧场版 / 集数错位」的匹配可能不准。每一步都会打日志，
/// 匹配不对时看 `BiliDanmaku:` 前缀的日志即可定位是哪一步出的问题。
///
/// 失败一律返回空列表（不抛异常），由调用方决定怎么提示用户。
class BilibiliDanmakuApi {
  BilibiliDanmakuApi._();

  static const String _searchUrl =
      'https://api.bilibili.com/x/web-interface/search/type';
  static const String _seasonUrl =
      'https://api.bilibili.com/pgc/view/web/season';
  static const String _danmakuUrl =
      'https://api.bilibili.com/x/v1/dm/list.so';

  static Dio get _dio => DioFactory.apiDio;

  static Map<String, String> get _headers => const {
    'referer': 'https://www.bilibili.com',
    'accept': 'application/json, text/plain, */*',
  };

  /// 按番剧名 + 集数拉取弹幕。
  static Future<List<DanmakuEntry>> byNameAndEpisode(
    String keyword,
    int episode,
  ) async {
    final String name = keyword.trim();
    if (name.isEmpty || episode <= 0) {
      return const [];
    }

    final int? seasonId = await _findSeasonId(name);
    if (seasonId == null) {
      return const [];
    }

    final List<_BiliEpisode> episodes = await _fetchEpisodes(seasonId);
    if (episodes.isEmpty) {
      KazumiLogger().w('BiliDanmaku: season $seasonId has no episode list');
      return const [];
    }

    final int index = episode - 1;
    if (index >= episodes.length) {
      KazumiLogger().w(
        'BiliDanmaku: episode $episode out of range, season $seasonId has '
        '${episodes.length} episodes',
      );
      return const [];
    }

    final _BiliEpisode target = episodes[index];
    KazumiLogger().i(
      'BiliDanmaku: "$name" season=$seasonId episode=$episode -> '
      'epId=${target.epId} cid=${target.cid} title="${target.title}"',
    );
    return _fetchDanmaku(target.cid);
  }

  // ---------------------------------------------------------------------------
  // 1. 搜索 season
  // ---------------------------------------------------------------------------
  static Future<int?> _findSeasonId(String name) async {
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(
        _searchUrl,
        queryParameters: {
          'search_type': 'media_bangumi',
          'keyword': name,
          'page': 1,
        },
        options: Options(headers: _headers),
      );

      final dynamic body = response.data;
      final dynamic data = body is Map ? body['data'] : null;
      final List<dynamic> results =
          data is Map && data['result'] is List ? data['result'] as List : const [];

      if (results.isEmpty) {
        KazumiLogger().w(
          'BiliDanmaku: search "$name" returned no result '
          '(code=${body is Map ? body['code'] : '?'})',
        );
        return null;
      }

      final List<Map<String, dynamic>> candidates = [
        for (final dynamic item in results)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
      if (candidates.isEmpty) {
        return null;
      }

      final String wanted = _normalize(name);
      Map<String, dynamic>? picked;
      // 优先标题完全一致
      for (final Map<String, dynamic> candidate in candidates) {
        if (_normalize(_rawTitle(candidate)) == wanted) {
          picked = candidate;
          break;
        }
      }
      // 其次标题互相包含
      picked ??= candidates.firstWhere(
        (candidate) {
          final String title = _normalize(_rawTitle(candidate));
          return title.isNotEmpty &&
              (title.contains(wanted) || wanted.contains(title));
        },
        orElse: () => candidates.first,
      );

      KazumiLogger().i(
        'BiliDanmaku: search "$name" got ${candidates.length} candidate(s), '
        'picked "${_rawTitle(picked)}"',
      );

      final dynamic seasonId = picked['season_id'] ?? picked['media_id'];
      final int? parsed = _asInt(seasonId);
      if (parsed == null) {
        KazumiLogger().w('BiliDanmaku: picked candidate has no season_id');
      }
      return parsed;
    } catch (e) {
      KazumiLogger().w('BiliDanmaku: search failed for "$name"', error: e);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 2. 取剧集列表
  // ---------------------------------------------------------------------------
  static Future<List<_BiliEpisode>> _fetchEpisodes(int seasonId) async {
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(
        _seasonUrl,
        queryParameters: {'season_id': seasonId},
        options: Options(headers: _headers),
      );

      final dynamic body = response.data;
      final dynamic result = body is Map ? body['result'] : null;
      final List<dynamic> raw =
          result is Map && result['episodes'] is List
          ? result['episodes'] as List
          : const [];

      final List<_BiliEpisode> episodes = [];
      for (final dynamic item in raw) {
        if (item is! Map) continue;
        final int? cid = _asInt(item['cid']);
        if (cid == null) continue;
        episodes.add(
          _BiliEpisode(
            epId: _asInt(item['id']) ?? 0,
            cid: cid,
            title:
                '${item['title'] ?? ''} ${item['long_title'] ?? ''}'.trim(),
          ),
        );
      }
      return episodes;
    } catch (e) {
      KazumiLogger().w('BiliDanmaku: season $seasonId fetch failed', error: e);
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // 3. 取弹幕 XML
  // ---------------------------------------------------------------------------
  static Future<List<DanmakuEntry>> _fetchDanmaku(int cid) async {
    try {
      final Response<String> response = await _dio.get<String>(
        _danmakuUrl,
        queryParameters: {'oid': cid},
        options: Options(
          headers: _headers,
          responseType: ResponseType.plain,
        ),
      );

      final String xml = response.data ?? '';
      if (xml.isEmpty) {
        KazumiLogger().w('BiliDanmaku: empty danmaku response for cid=$cid');
        return const [];
      }
      if (!xml.contains('<d ')) {
        // 风控页 / 错误 JSON 都会走到这里，把开头打出来便于定位
        final String head = xml.length > 200 ? xml.substring(0, 200) : xml;
        KazumiLogger().w(
          'BiliDanmaku: unexpected danmaku payload for cid=$cid '
          '(status=${response.statusCode}): $head',
        );
        return const [];
      }

      final List<DanmakuEntry> entries = [];
      int skipped = 0;
      for (final RegExpMatch match in _dTagPattern.allMatches(xml)) {
        final List<String> parts = (match.group(1) ?? '').split(',');
        if (parts.length < 4) {
          skipped++;
          continue;
        }
        final double? time = double.tryParse(parts[0]);
        final int mode = int.tryParse(parts[1]) ?? 1;
        final int color = int.tryParse(parts[3]) ?? 0xFFFFFF;
        // 7=高级弹幕 8=代码弹幕：位置由脚本控制，当普通弹幕渲染会错乱
        if (time == null || mode == 7 || mode == 8) {
          skipped++;
          continue;
        }
        final String text = _unescapeXml(match.group(2) ?? '');
        if (text.isEmpty) {
          skipped++;
          continue;
        }
        entries.add(
          DanmakuEntry(
            message: text,
            time: time,
            type: _internalDanmakuType(mode),
            color: generateDanmakuColor(color),
            // 复用内置的「B站来源」开关，与 DanDanPlay 的 withRelated 结果保持一致
            source: 'BiliBili',
          ),
        );
      }

      KazumiLogger().i(
        'BiliDanmaku: cid=$cid parsed ${entries.length} danmaku '
        '(skipped $skipped)',
      );
      return entries;
    } catch (e) {
      KazumiLogger().w('BiliDanmaku: danmaku fetch failed for cid=$cid',
          error: e);
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// B 站 `p` 的 mode 映射到内部 type（1 滚动 / 4 底部 / 5 顶部）。
  static int _internalDanmakuType(int mode) {
    if (mode == 4) return 4;
    if (mode == 5) return 5;
    return 1;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static String _rawTitle(Map<String, dynamic> item) =>
      '${item['title'] ?? item['org_title'] ?? ''}';

  /// 去掉搜索接口返回的高亮标签 `<em class="keyword">`。
  static final RegExp _tagPattern = RegExp(r'<[^>]+>');

  /// 归一化：去掉空白与常见标点，便于标题比对。
  static final RegExp _ignoredPattern = RegExp(
    r'''[\s\u3000!！?？.,，。:：;；、·・\-—_~～「」『』【】\[\]()（）《》<>"'`]''',
  );

  static String _normalize(String input) => input
      .replaceAll(_tagPattern, '')
      .replaceAll(_ignoredPattern, '')
      .toLowerCase();

  static final RegExp _dTagPattern = RegExp(
    r'<d p="([^"]+)"[^>]*>(.*?)</d>',
    dotAll: true,
  );

  static String _unescapeXml(String input) => input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

class _BiliEpisode {
  const _BiliEpisode({
    required this.epId,
    required this.cid,
    required this.title,
  });

  final int epId;
  final int cid;
  final String title;
}
