import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/pages/plugin_editor/plugin_update_actions.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/tv/core/focus/tv_list_items.dart';
import 'package:kazumi/tv/core/utils/tv_constants.dart';
import 'package:kazumi/tv/core/widgets/tv_button.dart';
import 'package:kazumi/tv/utils/modular_compat.dart';

/// 规则仓库（插件商店）
///
/// App 内置的规则只有 3 条（agedm / DM84 / aafun），这些站点随时可能失效，
/// 一旦失效详情页就会「获取集数失败」。这里浏览社区维护的完整规则列表
/// （Predidit/KazumiRules），按需安装/更新，从而拿回可用的视频源。
///
/// 页面不依赖 flutter_modular 路由，通过 [Modular.pushNamed] 进入，
/// 返回键直接出栈。
class TVPluginShopPage extends StatefulWidget {
  const TVPluginShopPage({super.key, this.onExitUp});

  /// 向上退出（嵌在设置页时由父级接管焦点）。
  final VoidCallback? onExitUp;

  @override
  State<TVPluginShopPage> createState() => _TVPluginShopPageState();
}

enum _CatalogFilter { all, installed, updates }

class _TVPluginShopPageState extends State<TVPluginShopPage> {
  final PluginsController _controller = Modular.get<PluginsController>();

  /// 工具行焦点：0=刷新 1=全部 2=已安装 3=可更新 4=规则镜像
  final List<FocusNode> _toolNodes = List<FocusNode>.generate(
    5,
    (index) => FocusNode(debugLabel: 'rule_shop_tool_$index'),
  );

  bool _loading = true;
  bool _loadFailed = false;
  bool _mirrorEnabled = false;
  _CatalogFilter _filter = _CatalogFilter.all;
  final Set<String> _installing = <String>{};

  @override
  void initState() {
    super.initState();
    _mirrorEnabled = GStorage.getSetting(SettingsKeys.enableGitProxy);
    _loadCatalog();
  }

  @override
  void dispose() {
    for (final node in _toolNodes) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog({bool force = false}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      if (force) {
        await _controller.refreshPluginCatalog();
      } else {
        await _controller.ensurePluginCatalog();
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      KazumiDialog.showToast(message: '无法访问规则仓库，可尝试切换规则镜像');
    }
  }

  /// 规则仓库有两个源：GitHub raw（直连）与 gitcode 镜像。
  /// 国内直连 GitHub 经常失败，切换后立刻重新拉取。
  Future<void> _toggleMirror() async {
    final bool next = !_mirrorEnabled;
    await GStorage.putSetting(SettingsKeys.enableGitProxy, next);
    if (!mounted) return;
    setState(() => _mirrorEnabled = next);
    KazumiDialog.showToast(message: next ? '已启用规则镜像' : '已关闭规则镜像');
    await _loadCatalog(force: true);
  }

  Future<void> _install(
    PluginHTTPItem item,
    PluginCatalogItemStatus status,
  ) async {
    if (!_installing.add(item.name)) return;
    setState(() {});

    try {
      await updatePluginWithFeedback(
        _controller,
        item.name,
        installing: status == PluginCatalogItemStatus.install,
      );
    } finally {
      if (mounted) {
        setState(() => _installing.remove(item.name));
      }
    }
  }

  List<PluginHTTPItem> _visibleItems() {
    final List<PluginHTTPItem> items = _controller.pluginHTTPList.where((item) {
      final PluginCatalogItemStatus status = _controller.pluginStatus(item);
      return switch (_filter) {
        _CatalogFilter.all => true,
        _CatalogFilter.installed =>
          status != PluginCatalogItemStatus.install,
        _CatalogFilter.updates => status == PluginCatalogItemStatus.update,
      };
    }).toList();
    items.sort((a, b) => b.lastUpdate.compareTo(a.lastUpdate));
    return items;
  }

  static String _formatDate(int millis) {
    if (millis <= 0) return '';
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TVConstants.backgroundColor,
      body: SafeArea(
        child: Observer(
          builder: (_) {
            final List<PluginHTTPItem> catalog = _controller.pluginHTTPList;
            final int installed = catalog
                .where((item) =>
                    _controller.pluginStatus(item) !=
                    PluginCatalogItemStatus.install)
                .length;
            final int updates = catalog
                .where((item) =>
                    _controller.pluginStatus(item) ==
                    PluginCatalogItemStatus.update)
                .length;

            if (_loading && catalog.isEmpty) {
              return const Center(
                child: CircularProgressIndicator(
                  color: TVConstants.focusColor,
                ),
              );
            }

            if (_loadFailed && catalog.isEmpty) {
              return _buildLoadFailed();
            }

            final List<PluginHTTPItem> items = _visibleItems();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(catalog.length, installed, updates),
                _buildToolRow(catalog.length, installed, updates),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: LinearProgressIndicator(
                      color: TVConstants.focusColor,
                      backgroundColor: TVConstants.surfaceVariantColor,
                    ),
                  ),
                if (_loadFailed)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Text(
                      '刷新失败，正在显示上次获取的规则列表。',
                      style: TextStyle(
                        color: TVConstants.textTertiaryColor,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? _buildEmpty()
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final PluginHTTPItem item = items[index];
                            return _RuleCard(
                              item: item,
                              status: _controller.pluginStatus(item),
                              busy: _installing.contains(item.name),
                              autofocus: index == 0,
                              onInstall: () => _install(
                                item,
                                _controller.pluginStatus(item),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(int total, int installed, int updates) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '规则仓库',
                style: TextStyle(
                  color: TVConstants.textPrimaryColor,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                '共 $total 条 · 已安装 $installed · 可更新 $updates',
                style: const TextStyle(
                  color: TVConstants.textTertiaryColor,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '内置规则可能已失效，安装社区规则后返回详情页重新搜索即可。',
            style: TextStyle(
              color: TVConstants.textTertiaryColor,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolRow(int total, int installed, int updates) {
    final List<String> labels = [
      '刷新',
      '全部 $total',
      '已安装 $installed',
      '可更新 $updates',
      _mirrorEnabled ? '镜像 开' : '镜像 关',
    ];
    final List<bool> highlighted = [
      false,
      _filter == _CatalogFilter.all,
      _filter == _CatalogFilter.installed,
      _filter == _CatalogFilter.updates,
      _mirrorEnabled,
    ];
    final List<VoidCallback> handlers = [
      () => _loadCatalog(force: true),
      () => setState(() => _filter = _CatalogFilter.all),
      () => setState(() => _filter = _CatalogFilter.installed),
      () => setState(() => _filter = _CatalogFilter.updates),
      _toggleMirror,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TvHorizontalListItem(
                focusNode: _toolNodes[i],
                // 仅当列表为空时把初始焦点交给「刷新」，否则交给第一条规则
                autofocus: i == 0 && total == 0,
                isFirst: i == 0,
                isLast: i == labels.length - 1,
                exitLeft: i == 0 ? null : _toolNodes[i - 1],
                exitRight:
                    i == labels.length - 1 ? null : _toolNodes[i + 1],
                onMoveUp: i == 0 ? widget.onExitUp : null,
                onSelect: handlers[i],
                onFocusChange: (_) => setState(() {}),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: highlighted[i]
                        ? TVConstants.focusColor
                        : TVConstants.surfaceVariantColor,
                    borderRadius: BorderRadius.circular(8),
                    border: _toolNodes[i].hasFocus
                        ? Border.all(color: Colors.white, width: 2)
                        : null,
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      color: highlighted[i]
                          ? Colors.white
                          : TVConstants.textSecondaryColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Text(
        '没有符合条件的规则',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
    );
  }

  Widget _buildLoadFailed() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: TVConstants.textTertiaryColor,
            size: 56,
          ),
          const SizedBox(height: 16),
          const Text(
            '无法访问规则仓库',
            style: TextStyle(
              color: TVConstants.textPrimaryColor,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '请检查网络，或切换规则镜像后重试。',
            style: TextStyle(
              color: TVConstants.textTertiaryColor,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TVButton(
                autofocus: true,
                onTap: () => _loadCatalog(force: true),
                child: const Text('重试'),
              ),
              const SizedBox(width: 16),
              TVButton(
                onTap: _toggleMirror,
                child: Text(_mirrorEnabled ? '关闭规则镜像' : '启用规则镜像'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单条规则卡片
class _RuleCard extends StatefulWidget {
  const _RuleCard({
    required this.item,
    required this.status,
    required this.busy,
    required this.onInstall,
    this.autofocus = false,
  });

  final PluginHTTPItem item;
  final PluginCatalogItemStatus status;
  final bool busy;
  final VoidCallback onInstall;
  final bool autofocus;

  @override
  State<_RuleCard> createState() => _RuleCardState();
}

class _RuleCardState extends State<_RuleCard> {
  late final FocusNode _cardFocusNode;
  late final FocusNode _actionFocusNode;

  @override
  void initState() {
    super.initState();
    _cardFocusNode = FocusNode(debugLabel: 'rule_card_${widget.item.name}');
    _actionFocusNode =
        FocusNode(debugLabel: 'rule_action_${widget.item.name}');
  }

  @override
  void dispose() {
    _cardFocusNode.dispose();
    _actionFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool installed =
        widget.status == PluginCatalogItemStatus.installed;

    return TvVerticalListItem(
      focusNode: _cardFocusNode,
      autofocus: widget.autofocus,
      onSelect: installed ? null : widget.onInstall,
      onFocusChange: (_) => setState(() {}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _cardFocusNode.hasFocus
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: _cardFocusNode.hasFocus
              ? Border.all(color: TVConstants.focusColor, width: 2)
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        widget.item.name,
                        style: const TextStyle(
                          color: TVConstants.textPrimaryColor,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 10),
                      _tag(
                        'v${widget.item.version}',
                        TVConstants.surfaceHighColor,
                        TVConstants.textSecondaryColor,
                      ),
                      if (widget.item.antiCrawlerEnabled) ...[
                        const SizedBox(width: 8),
                        _tag(
                          '需验证',
                          TVConstants.focusColorDim,
                          TVConstants.focusColor,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (widget.item.author.isNotEmpty)
                        '作者 · ${widget.item.author}',
                      if (_TVPluginShopPageState._formatDate(
                              widget.item.lastUpdate)
                          .isNotEmpty)
                        '更新于 ${_TVPluginShopPageState._formatDate(widget.item.lastUpdate)}',
                    ].join('   '),
                    style: const TextStyle(
                      color: TVConstants.textTertiaryColor,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            _buildAction(installed),
          ],
        ),
      ),
    );
  }

  Widget _tag(String label, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(color: foreground, fontSize: 12),
      ),
    );
  }

  Widget _buildAction(bool installed) {
    if (installed && !widget.busy) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded,
                size: 16, color: TVConstants.textTertiaryColor),
            SizedBox(width: 6),
            Text(
              '已安装',
              style: TextStyle(
                color: TVConstants.textTertiaryColor,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    final bool installing =
        widget.status == PluginCatalogItemStatus.install;
    final String label = widget.busy
        ? (installing ? '安装中' : '更新中')
        : (installing ? '安装' : '更新');

    return TvVerticalListItem(
      focusNode: _actionFocusNode,
      onSelect: widget.onInstall,
      onFocusChange: (_) => setState(() {}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: _actionFocusNode.hasFocus
              ? TVConstants.focusColor
              : TVConstants.focusColorDim,
          borderRadius: BorderRadius.circular(8),
          border: _actionFocusNode.hasFocus
              ? Border.all(color: Colors.white, width: 2)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              installing ? Icons.add_rounded : Icons.sync_rounded,
              size: 16,
              color: Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
