import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_group_header.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_toggle_row.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_slider_row.dart';

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

  /// 弹幕服务状态提示。
  ///
  /// DanDanPlay 是本项目**唯一的**弹幕数据来源（它自己聚合了 B站 / 巴哈姆特 /
  /// 弹弹play 三方弹幕）。它的接口需要 `X-AppId` + `X-Signature` 签名，
  /// 密钥由 CI 通过 `--dart-define=DANDANAPI_APPID/KEY` 注入。
  ///
  /// 自行构建 / fork 构建（仓库里没有这两个 secret）时密钥为空串，
  /// 接口会直接返回 **403**，表现就是「播放正常但一条弹幕都没有」，
  /// 而界面上完全看不出原因 —— 所以这里明确显示出来。
  Widget _buildServiceNotice() {
    final bool ready = hasDandanCredentials;
    final Color accent = ready ? const Color(0xFF4CAF50) : const Color(0xFFFF9800);

    return Container(
      margin: const EdgeInsets.fromLTRB(40, 12, 40, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.50)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ready
                ? Icons.check_circle_outline_rounded
                : Icons.warning_amber_rounded,
            color: accent,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? '弹幕服务已配置' : '弹幕服务未配置（当前不会有任何弹幕）',
                  style: TextStyle(
                    color: accent,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  ready
                      ? '已注入 DanDanPlay 应用凭据，播放时会自动拉取弹幕。'
                      : '构建时没有注入 DanDanPlay 应用凭据，弹幕接口会返回 403。\n'
                          '修复：到 doc.dandanplay.com 注册一个开发者应用，把 '
                          'DANDANAPI_APPID / DANDANAPI_KEY 加到本仓库的 '
                          'Settings → Secrets and variables → Actions，'
                          '再重新打 tag 构建即可。\n'
                          '（DanDanPlay 聚合 B站 / 巴哈姆特 / 弹弹play 三方弹幕，'
                          '是当前唯一的数据来源；下面的「弹幕来源」只是从中做筛选。）',
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
        const TVSettingsGroupHeader(title: '弹幕设置'),
        TVSettingsToggleRow(
          label: '弹幕开关',
          subtitle: '开启或关闭弹幕显示',
          value: danmakuEnabled,
          onChanged: updateDanmakuEnabled,
          isFirst: true,
          focusNode: widget.firstItemFocusNode,
          onMoveUp: widget.onExitUp,
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
