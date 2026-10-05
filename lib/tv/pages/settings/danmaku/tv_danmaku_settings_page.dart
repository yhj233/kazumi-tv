import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/danmaku/danmaku_provider.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_group_header.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_toggle_row.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_slider_row.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_dropdown_row.dart';

class TVDanmakuSettingsPage extends StatefulWidget {
  final FocusNode? firstItemFocusNode;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitLeft;
  final FocusNode? sidebarFocusNode;

  const TVDanmakuSettingsPage({
    super.key,
    this.firstItemFocusNode,
    this.onExitUp,
    this.onExitLeft,
    this.sidebarFocusNode,
  });

  @override
  State<TVDanmakuSettingsPage> createState() => _TVDanmakuSettingsPageState();
}

class _TVDanmakuSettingsPageState extends State<TVDanmakuSettingsPage> {
  late bool danmakuEnabled;
  late double danmakuFontSize;
  late double danmakuOpacity;
  late double danmakuArea;
  late bool danmakuTop;
  late bool danmakuBottom;
  late bool danmakuScroll;
  late bool danmakuColor;

  // 弹幕来源（DanDanPlay 会把这三个来源的弹幕一起返回，这里做过滤）
  late bool danmakuBiliBiliSource;
  late bool danmakuGamerSource;
  late bool danmakuDanDanSource;

  // 同步与去重
  late double danmakuTimeOffset;
  late bool danmakuDeduplication;
  late bool danmakuMassive;
  late bool danmakuFollowSpeed;

  /// 弹幕数据源
  late DanmakuProvider danmakuProvider;

  @override
  void initState() {
    super.initState();
    danmakuEnabled = GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault);
    danmakuFontSize = GStorage.getSetting(SettingsKeys.danmakuFontSize);
    danmakuOpacity = GStorage.getSetting(SettingsKeys.danmakuOpacity);
    danmakuArea = GStorage.getSetting(SettingsKeys.danmakuArea);
    danmakuTop = GStorage.getSetting(SettingsKeys.danmakuTop);
    danmakuBottom = GStorage.getSetting(SettingsKeys.danmakuBottom);
    danmakuScroll = GStorage.getSetting(SettingsKeys.danmakuScroll);
    danmakuColor = GStorage.getSetting(SettingsKeys.danmakuColor);
    danmakuBiliBiliSource =
        GStorage.getSetting(SettingsKeys.danmakuBiliBiliSource);
    danmakuGamerSource = GStorage.getSetting(SettingsKeys.danmakuGamerSource);
    danmakuDanDanSource =
        GStorage.getSetting(SettingsKeys.danmakuDanDanSource);
    danmakuTimeOffset = GStorage.getSetting(SettingsKeys.danmakuTimeOffset);
    danmakuDeduplication =
        GStorage.getSetting(SettingsKeys.danmakuDeduplication);
    danmakuMassive = GStorage.getSetting(SettingsKeys.danmakuMassive);
    danmakuFollowSpeed = GStorage.getSetting(SettingsKeys.danmakuFollowSpeed);
    danmakuProvider = DanmakuProvider.current;
  }

  void updateDanmakuProvider(DanmakuProvider value) {
    GStorage.putSetting(SettingsKeys.danmakuProvider, value.storageValue);
    setState(() {
      danmakuProvider = value;
    });
  }

  void updateDanmakuEnabled(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, value);
    setState(() {
      danmakuEnabled = value;
    });
  }

  void updateDanmakuFontSize(double value) {
    GStorage.putSetting(SettingsKeys.danmakuFontSize, value);
    setState(() {
      danmakuFontSize = value;
    });
  }

  void updateDanmakuOpacity(double value) {
    GStorage.putSetting(SettingsKeys.danmakuOpacity, value);
    setState(() {
      danmakuOpacity = value;
    });
  }

  void updateDanmakuArea(double value) {
    GStorage.putSetting(SettingsKeys.danmakuArea, value);
    setState(() {
      danmakuArea = value;
    });
  }

  void updateDanmakuTop(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuTop, value);
    setState(() {
      danmakuTop = value;
    });
  }

  void updateDanmakuBottom(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuBottom, value);
    setState(() {
      danmakuBottom = value;
    });
  }

  void updateDanmakuScroll(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuScroll, value);
    setState(() {
      danmakuScroll = value;
    });
  }

  void updateDanmakuColor(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuColor, value);
    setState(() {
      danmakuColor = value;
    });
  }

  void updateDanmakuBiliBiliSource(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuBiliBiliSource, value);
    setState(() {
      danmakuBiliBiliSource = value;
    });
  }

  void updateDanmakuGamerSource(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuGamerSource, value);
    setState(() {
      danmakuGamerSource = value;
    });
  }

  void updateDanmakuDanDanSource(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuDanDanSource, value);
    setState(() {
      danmakuDanDanSource = value;
    });
  }

  void updateDanmakuTimeOffset(double value) {
    GStorage.putSetting(SettingsKeys.danmakuTimeOffset, value);
    setState(() {
      danmakuTimeOffset = value;
    });
  }

  void updateDanmakuDeduplication(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuDeduplication, value);
    setState(() {
      danmakuDeduplication = value;
    });
  }

  void updateDanmakuMassive(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuMassive, value);
    setState(() {
      danmakuMassive = value;
    });
  }

  void updateDanmakuFollowSpeed(bool value) {
    GStorage.putSetting(SettingsKeys.danmakuFollowSpeed, value);
    setState(() {
      danmakuFollowSpeed = value;
    });
  }

  /// 弹幕来源状态提示。
  ///
  /// - 用 B站直连：不需要任何密钥，直接可用（提示匹配可能不准）
  /// - 用 DanDanPlay：需要构建时注入 `DANDANAPI_APPID/KEY`，
  ///   而 DanDanPlay 自 2025-01 起强制应用认证（需人工审核），
  ///   所以未配置时这里会明确建议改回「自动」或「B站直连」。
  Widget _buildServiceNotice() {
    final DanmakuProvider selected = danmakuProvider;
    final DanmakuProvider effective = selected.resolved;

    if (effective == DanmakuProvider.bilibili) {
      final bool autoSwitched = selected == DanmakuProvider.auto;
      return _notice(
        color: const Color(0xFF4CAF50),
        icon: Icons.check_circle_outline_rounded,
        title: '弹幕来源：B站直连${autoSwitched ? '（自动选择）' : ''}',
        body: autoSwitched
            ? '未检测到 DanDanPlay 应用凭据，已自动改用 B站直连 —— 不需要任何密钥。\n'
                  '注意：B站来源是按「番剧名 + 集数序号」匹配的，多季番剧 / 剧场版 / '
                  '集数错位时可能对不上，可在播放中用「时间轴偏移」微调，或切换上面的数据源。'
            : 'B站直连不需要任何密钥。\n'
                  '注意：按「番剧名 + 集数序号」匹配，多季番剧 / 剧场版可能对不上。',
      );
    }

    final bool ready = hasDandanCredentials;
    return _notice(
      color: ready ? const Color(0xFF4CAF50) : const Color(0xFFFF9800),
      icon: ready
          ? Icons.check_circle_outline_rounded
          : Icons.warning_amber_rounded,
      title: ready
          ? '弹幕来源：DanDanPlay'
          : '弹幕来源：DanDanPlay —— 未配置凭据，不会有弹幕',
      body: ready
          ? '已注入 DanDanPlay 应用凭据，可一次拿到 B站 / 巴哈姆特 / 弹弹play 三方弹幕。'
          : 'DanDanPlay 自 2025-01 起强制应用认证：需要在 DevCenter 注册账号并通过'
                '人工审核才能拿到 AppId，当前构建没有注入 DANDANAPI_APPID / '
                'DANDANAPI_KEY，接口会返回 403。\n'
                '建议把下面的「弹幕数据源」改成「自动」或「B站直连」，就不需要任何密钥了。',
    );
  }

  Widget _notice({
    required Color color,
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(40, 12, 40, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.50)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 20),
      children: [
        _buildServiceNotice(),
        const TVSettingsGroupHeader(title: '弹幕数据源'),
        TVSettingsDropdownRow<DanmakuProvider>(
          label: '数据源',
          subtitle: danmakuProviderSubtitle(danmakuProvider),
          value: danmakuProvider,
          items: DanmakuProvider.selectable,
          itemLabel: (provider) => provider.label,
          onChanged: (value) {
            if (value != null) {
              updateDanmakuProvider(value);
            }
          },
          isFirst: true,
          focusNode: widget.firstItemFocusNode,
          onMoveUp: widget.onExitUp,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        const TVSettingsGroupHeader(title: '弹幕设置'),
        TVSettingsToggleRow(
          label: '弹幕开关',
          subtitle: '开启或关闭弹幕显示',
          value: danmakuEnabled,
          onChanged: updateDanmakuEnabled,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsSliderRow(
          label: '字体大小',
          subtitle: '弹幕文字大小',
          value: danmakuFontSize,
          min: 16,
          max: 40,
          divisions: 24,
          onChanged: updateDanmakuFontSize,
          valueLabel: '${danmakuFontSize.toInt()}px',
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsSliderRow(
          label: '不透明度',
          subtitle: '弹幕不透明度',
          value: danmakuOpacity,
          min: 0.5,
          max: 1.0,
          divisions: 10,
          onChanged: updateDanmakuOpacity,
          valueLabel: danmakuOpacity.toStringAsFixed(1),
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsSliderRow(
          label: '显示区域',
          subtitle: '弹幕显示区域占比',
          value: danmakuArea,
          min: 0.0,
          max: 1.0,
          divisions: 10,
          onChanged: updateDanmakuArea,
          valueLabel: '${(danmakuArea * 100).toInt()}%',
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '顶部弹幕',
          subtitle: '显示顶部位置的弹幕',
          value: danmakuTop,
          onChanged: updateDanmakuTop,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '底部弹幕',
          subtitle: '显示底部位置的弹幕',
          value: danmakuBottom,
          onChanged: updateDanmakuBottom,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '滚动弹幕',
          subtitle: '显示滚动的弹幕',
          value: danmakuScroll,
          onChanged: updateDanmakuScroll,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '彩色弹幕',
          subtitle: '显示彩色弹幕',
          value: danmakuColor,
          onChanged: updateDanmakuColor,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        const TVSettingsGroupHeader(title: '弹幕来源'),
        TVSettingsToggleRow(
          label: 'B站来源',
          subtitle: '显示 BiliBili 的弹幕',
          value: danmakuBiliBiliSource,
          onChanged: updateDanmakuBiliBiliSource,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '巴哈姆特来源',
          subtitle: '显示 巴哈姆特動畫瘋 的弹幕',
          value: danmakuGamerSource,
          onChanged: updateDanmakuGamerSource,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '弹弹play 来源',
          subtitle: '显示弹弹play 自有来源的弹幕',
          value: danmakuDanDanSource,
          onChanged: updateDanmakuDanDanSource,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        const TVSettingsGroupHeader(title: '同步与去重'),
        TVSettingsSliderRow(
          label: '时间轴偏移',
          subtitle: '弹幕比画面快/慢时用它对齐（正数=弹幕延后）',
          value: danmakuTimeOffset,
          min: -10.0,
          max: 10.0,
          divisions: 40,
          onChanged: updateDanmakuTimeOffset,
          valueLabel:
              '${danmakuTimeOffset >= 0 ? '+' : ''}${danmakuTimeOffset.toStringAsFixed(1)}s',
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '防挡字幕',
          subtitle: '弹幕避开画面底部字幕区域',
          value: danmakuMassive,
          onChanged: updateDanmakuMassive,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '跟随倍速',
          subtitle: '改变播放速度时同步调整弹幕滚动速度',
          value: danmakuFollowSpeed,
          onChanged: updateDanmakuFollowSpeed,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '弹幕去重',
          subtitle: '合并 5 秒内重复的弹幕',
          value: danmakuDeduplication,
          onChanged: updateDanmakuDeduplication,
          isLast: true,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
      ],
    );
  }
}
