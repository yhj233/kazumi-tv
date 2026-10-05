import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/tv/pages/search/tv_search_page.dart';
import 'package:kazumi/tv/pages/settings/tv_settings_page.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';
import '../../core/utils/tv_constants.dart';
import '../../tv_app.dart';
import 'tv_menu_widget.dart';
import '../collect/tv_collect_page.dart';
import '../popular/tv_popular_page.dart';
import '../timeline/tv_timeline_page.dart';

/// TV 主页面
class TVMainPage extends StatefulWidget {
  const TVMainPage({
    super.key,
    this.initialTab = 0,
    this.isRoot = true,
  });

  /// 初始选中的 Tab（0:推荐 1:时间线 2:收藏 3:搜索 4:设置）
  final int initialTab;

  /// 是否为根路由。
  ///
  /// 根路由下按返回键弹出「退出应用」确认框；
  /// 被 push 出来的实例（例如开发者菜单跳转）则正常出栈。
  final bool isRoot;

  @override
  State<TVMainPage> createState() => _TVMainPageState();
}

class _TVMainPageState extends State<TVMainPage> {
  late int _selectedTabIndex = widget.initialTab;

  final List<FocusNode> _contentFocusNodes = [
    FocusNode(debugLabel: 'popular_content'),
    FocusNode(debugLabel: 'timeline_content'),
    FocusNode(debugLabel: 'collect_content'),
    FocusNode(debugLabel: 'search_content'),
    FocusNode(debugLabel: 'settings_content'),
  ];

  final List<Widget> _pages = [];
  final GlobalKey<TVMenuWidgetState> _menuKey = GlobalKey<TVMenuWidgetState>();

  @override
  void initState() {
    super.initState();
    _initPages();
    // 初始化 TV 环境（屏幕方向、焦点策略等）
    initTVEnvironment();
    // 全局按键监听：不依赖焦点，任何位置都能响应快捷键。
    // 只有根实例注册，避免 push 出来的多个实例重复响应。
    if (widget.isRoot) {
      HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    }
  }

  @override
  void dispose() {
    if (widget.isRoot) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    }
    for (final node in _contentFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// 全局快捷键处理。
  ///
  /// 之前的实现用 `Focus` / `KeyboardListener` 绑定在页面上，
  /// 只有该节点持有焦点时才能收到按键；但 TV 上焦点一直在内容区，
  /// 所以按键永远收不到。改用 [HardwareKeyboard] 全局监听，
  /// 与焦点无关，必定生效。
  ///
  /// - `D`：打开开发者菜单
  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyD) {
      debugPrint('TV: global shortcut "D" pressed -> /developer');
      Modular.pushNamed('/developer');
      return true;
    }
    return false;
  }

  void _initPages() {
    _pages.addAll([
      TVPopularPage(
        contentFocusNode: _contentFocusNodes[0],
        onExitToMenu: _handleExitToMenu,
      ),
      TVTimelinePage(
        contentFocusNode: _contentFocusNodes[1],
        onExitToMenu: _handleExitToMenu,
      ),
      TVCollectPage(
        contentFocusNode: _contentFocusNodes[2],
        onExitToMenu: _handleExitToMenu,
      ),
      TVSearchPage(
        contentFocusNode: _contentFocusNodes[3],
        onExitToMenu: _handleExitToMenu,
      ),
      TVSettingsPage(
        contentFocusNode: _contentFocusNodes[4],
        onExitToMenu: _handleExitToMenu,
      ),
    ]);
  }

  void _handleTabSelected(int index) {
    setState(() {
      _selectedTabIndex = index;
    });
  }

  void _handleExitToMenu() {
    _menuKey.currentState?.requestMenuFocus();
  }

  @override
  Widget build(BuildContext context) {
    // 尽早把 Navigator 交给兼容层，避免 Modular.pushNamed 时还是 null
    Modular.setNavigator(Navigator.of(context));

    return PopScope(
      canPop: !widget.isRoot,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (!(_menuKey.currentState?.hasFocus() ?? false)) {
          _handleExitToMenu();
          return;
        }

        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('退出应用'),
            content: const Text('确定要退出吗?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );

        if (shouldExit == true) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: TVConstants.backgroundColor,
        body: Row(
          children: [
            TVMenuWidget(
              key: _menuKey,
              selectedIndex: _selectedTabIndex,
              onItemSelected: _handleTabSelected,
              onMenuItemFocused: (index) {
                _handleTabSelected(index);
              },
              onExitRight: () {
                final currentNode = _contentFocusNodes[_selectedTabIndex];
                currentNode.requestFocus();
              },
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedTabIndex,
                children: _pages,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
