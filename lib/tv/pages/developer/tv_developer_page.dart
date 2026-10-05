import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/tv/core/focus/tv_key_handler.dart';
import 'package:kazumi/tv/core/utils/tv_constants.dart';
import 'package:kazumi/tv/core/widgets/tv_button.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';

/// 开发者菜单页面
///
/// 用于调试路由与页面跳转。所有条目都是可聚焦的 [TVButton]，
/// 因此遥控器 DPAD 上下移动 + OK 确认即可操作（旧版只有 InkWell，
/// 键盘/遥控器无法选中）。
class TVDeveloperPage extends StatefulWidget {
  const TVDeveloperPage({super.key});

  @override
  State<TVDeveloperPage> createState() => _TVDeveloperPageState();
}

class _TVDeveloperPageState extends State<TVDeveloperPage> {
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'developer_page');
  final List<FocusNode> _itemNodes = [];

  late final List<_DevMenuItem> _items = _buildItems();

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < _items.length; i++) {
      _itemNodes.add(FocusNode(debugLabel: 'developer_item_$i'));
    }
  }

  @override
  void dispose() {
    _pageFocusNode.dispose();
    for (final node in _itemNodes) {
      node.dispose();
    }
    super.dispose();
  }

  BangumiItem _createTestBangumiItem(int id, String name) {
    return BangumiItem(
      id: id,
      type: 2,
      name: name,
      nameCn: name,
      summary: '测试番剧',
      airDate: '2024-01-01',
      airWeekday: 1,
      rank: 0,
      images: {},
      tags: [],
      alias: [],
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );
  }

  List<_DevMenuItem> _buildItems() {
    return [
      _DevMenuItem(
        '热门番剧页  /popular',
        () => Modular.pushNamed('/popular'),
      ),
      _DevMenuItem(
        '时间线页  /timeline',
        () => Modular.pushNamed('/timeline'),
      ),
      _DevMenuItem(
        '收藏页  /collect',
        () => Modular.pushNamed('/collect'),
      ),
      _DevMenuItem(
        '搜索页  /search',
        () => Modular.pushNamed('/search'),
      ),
      _DevMenuItem(
        '设置页  /settings',
        () => Modular.pushNamed('/settings'),
      ),
      _DevMenuItem(
        '插件列表页  /settings/plugin',
        () => Modular.pushNamed('/settings/plugin'),
      ),
      _DevMenuItem(
        '插件商店页  /settings/plugin/shop',
        () => Modular.pushNamed('/settings/plugin/shop'),
      ),
      _DevMenuItem(
        '详情页 (ID: 622288)  /info',
        () => Modular.pushNamed(
          '/info',
          arguments: _createTestBangumiItem(622288, '测试番剧'),
        ),
      ),
      _DevMenuItem(
        '详情页 (ID: 328609)  /info',
        () => Modular.pushNamed(
          '/info',
          arguments: _createTestBangumiItem(328609, 'Test Bangumi'),
        ),
      ),
      _DevMenuItem(
        '播放器页  /player',
        () => Modular.pushNamed('/player'),
      ),
      _DevMenuItem('返回', () => Modular.pop()),
    ];
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    return TvKeyHandler.handleNavigation(
      event,
      onBack: () {
        Modular.pop();
        return KeyEventResult.handled;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TVConstants.backgroundColor,
      body: Focus(
        focusNode: _pageFocusNode,
        // 自身不参与焦点遍历，只作为按键冒泡的祖先节点，
        // 避免 DPAD 左右把焦点移到一个看不见的节点上。
        canRequestFocus: false,
        onKeyEvent: _handleKeyEvent,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '开发者菜单',
                style: TextStyle(
                  color: TVConstants.textPrimaryColor,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '按 D 键可随时打开本页面；方向键选择，OK 确认，返回键退出。',
                style: TextStyle(
                  color: TVConstants.textTertiaryColor,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              for (int i = 0; i < _items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TVButton(
                    focusNode: _itemNodes[i],
                    autofocus: i == 0,
                    onTap: _items[i].onSelect,
                    onUp: i > 0
                        ? () => _itemNodes[i - 1].requestFocus()
                        : null,
                    onDown: i < _items.length - 1
                        ? () => _itemNodes[i + 1].requestFocus()
                        : null,
                    child: Text(_items[i].label),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DevMenuItem {
  const _DevMenuItem(this.label, this.onSelect);

  final String label;
  final VoidCallback onSelect;
}
