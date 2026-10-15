class PlayerErrorMapper {
  const PlayerErrorMapper._();

  /// 解码链初始化失败。安卓电视盒子（老 MediaCodec / 不支持 P010 输出）上
  /// 非常常见：`h264_mediacodec: Both surface and native_window are NULL` →
  /// `Output color format 0x2f is not supported` → `Could not open codec.`。
  /// 过去这类错误不在匹配表内，且 `showPlayerError` 默认关闭，导致播放失败
  /// 时界面完全没有提示（只剩转圈），用户无法区分「解析失败」与「播放失败」。
  static const List<String> _decoderFailures = [
    'Could not open codec',
    'Failed to configure context',
    'Failed to initialize a decoder',
    'failed to start',
    'Could not open video codec',
    'Decoder init failed',
  ];

  /// 直链本身取不到数据：CDN 拒绝、签名过期、防盗链返回错误页等。
  static const List<String> _sourceFailures = [
    'Failed to recognize file format',
    'Failed to open',
    'HTTP error',
    'Connection refused',
    'Connection reset',
    'Invalid data found when processing input',
  ];

  static String? toActionableMessage(
    Object error, {
    required bool isBuffering,
  }) {
    final message = error.toString();
    if (_decoderFailures.any(message.contains)) {
      return '视频解码失败, 已尝试切换软解, 若仍无画面请更换其他视频来源';
    }
    if (message.contains('Failed to recognize file format') ||
        (isBuffering && message.contains('Failed to open'))) {
      return '加载失败, 请尝试更换其他视频来源';
    }
    if (_sourceFailures.any(message.contains)) {
      return '视频源无响应, 请尝试更换其他视频来源';
    }
    return null;
  }
}
