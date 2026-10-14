import 'dart:io';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/logging/logger.dart';

class WebViewFeatureService {
  WebViewFeatureService._();

  static bool? _isDocumentStartScriptSupported;

  static Future<void> initialize() async {
    if (Platform.isAndroid) {
      // 【诊断】记录 DOCUMENT_START_SCRIPT 检测结果。
      // 该项决定 `VideoWebviewControllerFactory` 走「预注入」还是「fallback」路径：
      // - true  → VideoWebviewAndroidImpl（文档创建前注入钩子）
      // - false → VideoWebviewImpl（加载后注入，旧设备上可能来不及拦截）
      try {
        _isDocumentStartScriptSupported = await PlatformWebViewFeature.static()
            .isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        KazumiLogger().i(
            'WebViewFeature: DOCUMENT_START_SCRIPT supported=$_isDocumentStartScriptSupported');
      } catch (e) {
        // 极端情况下 isFeatureSupported 本身可能抛异常（旧 WebView / 无 WebView），
        // 此处不改变原有语义（视为不支持），仅记录，避免 main() 无日志中断。
        _isDocumentStartScriptSupported = false;
        KazumiLogger()
            .e('WebViewFeature: DOCUMENT_START_SCRIPT detection failed', error: e);
      }
    }
  }

  static bool get isDocumentStartScriptSupported =>
      _isDocumentStartScriptSupported ?? false;
}
