// DanDanPlay API credentials for the client signature flow.
// Release/PR CI injects them via --dart-define=DANDANAPI_APPID / DANDANAPI_KEY.
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID'),
  'value': String.fromEnvironment('DANDANAPI_KEY'),
};

/// 构建时是否注入了 DanDanPlay 凭据。
///
/// 未注入时 `X-Signature` 必然无效，DanDanPlay 会直接返回 **403**，
/// 表现为「弹幕功能无效」。修复方式：在仓库 Settings → Secrets 里配置
/// `DANDANAPI_APPID` / `DANDANAPI_KEY`（CI 已通过 `--dart-define` 传入）。
bool get hasDandanCredentials =>
    (dandanCredentials['id'] ?? '').isNotEmpty &&
    (dandanCredentials['value'] ?? '').isNotEmpty;
