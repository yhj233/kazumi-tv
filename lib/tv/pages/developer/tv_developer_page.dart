import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import '../../modules/bangumi/bangumi_item.dart';
import '../../utils/modular_compat.dart';
import '../../core/utils/tv_constants.dart';

/// 开发者菜单页面
///
/// 用于调试导航功能，可以直接跳转到不同页面。
class TVDeveloperPage extends StatefulWidget {
  const TVDeveloperPage({super.key});

  @override
  State<TVDeveloperPage> createState() => _TVDeveloperPageState();
}

class _TVDeveloperPageState extends State<TVDeveloperPage> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _navigate(String route, {Object? arguments}) {
    debugPrint('TV: Developer menu navigating to $route');
    Modular.to.pushNamed(route, arguments: arguments);
  }

  void _handleBack() {
    Modular.to.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TVConstants.backgroundColor,
      appBar: AppBar(
        title: const Text('开发者菜单'),
        backgroundColor: TVConstants.surfaceVariantColor,
        foregroundColor: TVConstants.textPrimaryColor,
      ),
      body: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.goBack ||
                event.logicalKey == LogicalKeyboardKey.escape) {
              _handleBack();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '调试导航功能：',
                style: TextStyle(
                  color: TVConstants.textSecondaryColor,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              _buildButton('跳转到热门番剧页', () => _navigate('/tab/popular/')),
              _buildButton('跳转到时间线页', () => _navigate('/tab/timeline/')),
              _buildButton('跳转到收藏页', () => _navigate('/tab/collect/')),
              _buildButton('跳转到搜索页', () => _navigate('/tab/search/')),
              _buildButton('跳转到设置页', () => _navigate('/tab/settings/')),
              _buildButton('跳转到插件列表页', () => _navigate('/tab/plugin/')),
              const SizedBox(height: 16),
              const Text(
                '测试详情页（需要 BangumiItem 参数）：',
                style: TextStyle(
                  color: TVConstants.textSecondaryColor,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              _buildButton(
                '跳转到详情页 (ID: 622288)',
                () => _navigate(
                  '/info/',
                  arguments: BangumiItem(
                    id: 622288,
                    name: '测试番剧',
                    nameCn: '测试中文',
                  ),
                ),
              ),
              _buildButton(
                '跳转到详情页 (ID: 328609)',
                () => _navigate(
                  '/info/',
                  arguments: BangumiItem(
                    id: 328609,
                    name: 'Test Bangumi',
                    nameCn: '测试番剧',
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _buildButton('返回', _handleBack),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: TVConstants.surfaceVariantColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              label,
              style: const TextStyle(
                color: TVConstants.textPrimaryColor,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
