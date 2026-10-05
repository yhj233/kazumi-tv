import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

enum BangumiAcceleration {
  direct,
  ech,
  mirror;

  static BangumiAcceleration get current => switch (GStorage.getSetting(
    SettingsKeys.bangumiAcceleration,
  )) {
    'direct' => direct,
    'ech' => ech,
    'mirror' => mirror,
    _ => GStorage.getSetting(SettingsKeys.enableBangumiProxy) ? mirror : direct,
  };

  String get label => switch (this) {
    direct => '直连',
    ech => 'ECH',
    mirror => '镜像',
  };

  /// 镜像后端对「搜索 / 评论」等接口要求 `X-AppId` + `X-Signature` 签名，
  /// 而签名密钥由 CI 通过 `--dart-define=KAZUMI_APPID/KAZUMI_KEY` 注入
  /// （见 `lib/utils/bangumi_mirror_credentials.dart`）。
  ///
  /// 自行构建 / fork 构建时这两个值会是**空字符串**，生成的签名必然校验失败，
  /// 镜像会直接返回 **401**（表现为「搜索任何关键词都立刻无结果」）。
  /// 因此缺少密钥时这些接口必须绕开镜像。
  static bool get hasMirrorCredentials {
    final String id = bangumiMirrorCredentials['id'] ?? '';
    final String value = bangumiMirrorCredentials['value'] ?? '';
    return id.isNotEmpty && value.isNotEmpty;
  }

  /// 镜像后端需要签名的接口（与 `BangumiClient._shouldSignProtectedMirrorRequest` 一致）。
  static bool isProtectedMirrorEndpoint(String method, String path) {
    if (method == 'POST' && path == '/v0/search/subjects') {
      return true;
    }
    if (method != 'GET') {
      return false;
    }
    return path.startsWith('/p1/subjects/') && path.endsWith('/comments') ||
        path.startsWith('/p1/episodes/') && path.endsWith('/comments') ||
        path.startsWith('/p1/characters/') && path.endsWith('/comments');
  }
}
