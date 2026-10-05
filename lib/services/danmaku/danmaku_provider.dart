import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

/// 弹幕数据源。
///
/// [dandanplay] 需要构建时注入 `DANDANAPI_APPID` / `DANDANAPI_KEY`；
/// 自 2025-01 起 DanDanPlay 强制应用认证，需要在 DevCenter 注册账号并
/// **人工审核**才能拿到凭据，对个人 fork 不现实。
///
/// [bilibili] 是直连 B 站的公开接口，**不需要任何密钥**，
/// 代价是「番剧 → 剧集」的匹配要自己做（见 `BilibiliDanmakuApi`）。
enum DanmakuProvider {
  auto,
  dandanplay,
  bilibili;

  static DanmakuProvider get current =>
      switch (GStorage.getSetting(SettingsKeys.danmakuProvider)) {
        'dandanplay' => DanmakuProvider.dandanplay,
        'bilibili' => DanmakuProvider.bilibili,
        _ => DanmakuProvider.auto,
      };

  /// 实际要使用的来源。
  ///
  /// [auto] 在缺少 DanDanPlay 凭据时自动改用 B 站 —— 那种情况下
  /// DanDanPlay 接口必定返回 403，等于没有弹幕。
  DanmakuProvider get resolved => switch (this) {
    DanmakuProvider.auto =>
      hasDandanCredentials ? DanmakuProvider.dandanplay : DanmakuProvider.bilibili,
    _ => this,
  };

  String get label => switch (this) {
    DanmakuProvider.auto => '自动',
    DanmakuProvider.dandanplay => 'DanDanPlay',
    DanmakuProvider.bilibili => 'B站直连',
  };

  String get storageValue => switch (this) {
    DanmakuProvider.auto => '',
    DanmakuProvider.dandanplay => 'dandanplay',
    DanmakuProvider.bilibili => 'bilibili',
  };

  static const List<DanmakuProvider> selectable = [
    DanmakuProvider.auto,
    DanmakuProvider.dandanplay,
    DanmakuProvider.bilibili,
  ];

  static DanmakuProvider fromStorageValue(String value) => switch (value) {
    'dandanplay' => DanmakuProvider.dandanplay,
    'bilibili' => DanmakuProvider.bilibili,
    _ => DanmakuProvider.auto,
  };
}

/// 供设置页显示的一句话说明。
String danmakuProviderSubtitle(DanmakuProvider provider) => switch (provider) {
  DanmakuProvider.auto =>
    '有 DanDanPlay 凭据时用它，否则自动改用 B站直连',
  DanmakuProvider.dandanplay =>
    '需要构建时注入 DANDANAPI_APPID/KEY（官方需人工审核）',
  DanmakuProvider.bilibili =>
    '不需要任何密钥；多季番剧的集数匹配可能不准',
};
