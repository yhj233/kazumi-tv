import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_group_header.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_toggle_row.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_slider_row.dart';
import 'package:kazumi/tv/pages/settings/widgets/tv_settings_dropdown_row.dart';

/// 画面比例类型映射
const Map<int, String> aspectRatioTypeMap = {
  0: '自动',
  1: '16:9',
  2: '4:3',
  3: '1:1',
};

/// 番剧数据源模式（对应 `SettingsKeys.bangumiAcceleration`）。
///
/// 空字符串走「自动」：镜像后端对搜索/评论接口要求 `X-AppId` + `X-Signature`
/// 签名，而签名密钥只在 CI 注入了 `KAZUMI_APPID` / `KAZUMI_KEY` 时才存在；
/// 缺少密钥时自动回退 ECH，否则搜索会直接 401（表现为「输入任何都无结果」）。
const Map<String, String> bangumiAccelerationLabelMap = {
  '': '自动',
  'ech': 'ECH',
  'direct': '直连',
  'mirror': '镜像',
};

String bangumiAccelerationSubtitle(String mode) => switch (mode) {
  'ech' => 'DoH + ECH 直连 Bangumi，适合被阻断的网络',
  'direct' => '直接访问 api.bgm.tv，不使用任何加速',
  'mirror' => '强制走 Kazumi 镜像（搜索接口需要签名密钥）',
  _ => '自动选择（推荐）：镜像缺少签名密钥时自动回退 ECH',
};

class TVPlayerSettingsPage extends StatefulWidget {
  final FocusNode? firstItemFocusNode;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitLeft;
  final FocusNode? sidebarFocusNode;

  const TVPlayerSettingsPage({
    super.key,
    this.firstItemFocusNode,
    this.onExitUp,
    this.onExitLeft,
    this.sidebarFocusNode,
  });

  @override
  State<TVPlayerSettingsPage> createState() => _TVPlayerSettingsPageState();
}

class _TVPlayerSettingsPageState extends State<TVPlayerSettingsPage> {
  late bool hAenable;
  late bool lowMemoryMode;
  late double defaultPlaySpeed;
  late int defaultAspectRatioType;
  late String bangumiAccelerationMode;

  @override
  void initState() {
    super.initState();
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    lowMemoryMode = GStorage.getSetting(SettingsKeys.lowMemoryMode);
    defaultPlaySpeed = GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    defaultAspectRatioType = GStorage.getSetting(SettingsKeys.defaultAspectRatioType);
    bangumiAccelerationMode =
        GStorage.getSetting(SettingsKeys.bangumiAcceleration);
  }

  void updateBangumiAcceleration(String value) {
    GStorage.putSetting(SettingsKeys.bangumiAcceleration, value);
    setState(() {
      bangumiAccelerationMode = value;
    });
  }

  void updateHAenable(bool value) {
    GStorage.putSetting(SettingsKeys.hAenable, value);
    setState(() {
      hAenable = value;
    });
  }

  void updateLowMemoryMode(bool value) {
    GStorage.putSetting(SettingsKeys.lowMemoryMode, value);
    setState(() {
      lowMemoryMode = value;
    });
  }

  void updateDefaultPlaySpeed(double value) {
    GStorage.putSetting(SettingsKeys.defaultPlaySpeed, value);
    setState(() {
      defaultPlaySpeed = value;
    });
  }

  void updateDefaultAspectRatioType(int value) {
    GStorage.putSetting(SettingsKeys.defaultAspectRatioType, value);
    setState(() {
      defaultAspectRatioType = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 20),
      children: [
        const TVSettingsGroupHeader(title: '播放器设置'),
        TVSettingsToggleRow(
          label: '硬件解码',
          subtitle: '使用硬件加速解码视频',
          value: hAenable,
          onChanged: updateHAenable,
          isFirst: true,
          focusNode: widget.firstItemFocusNode,
          onMoveUp: widget.onExitUp,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsToggleRow(
          label: '低内存模式',
          subtitle: '减少内存占用，可能降低性能',
          value: lowMemoryMode,
          onChanged: updateLowMemoryMode,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsSliderRow(
          label: '默认播放速度',
          subtitle: '视频播放的默认速度',
          value: defaultPlaySpeed,
          min: 0.25,
          max: 3.0,
          divisions: 11,
          onChanged: updateDefaultPlaySpeed,
          valueLabel: '${defaultPlaySpeed.toStringAsFixed(2)}x',
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        TVSettingsDropdownRow<int>(
          label: '默认画面比例',
          subtitle: '视频画面的默认显示比例',
          value: defaultAspectRatioType,
          items: aspectRatioTypeMap.keys.toList(),
          itemLabel: (type) => aspectRatioTypeMap[type] ?? '自动',
          onChanged: (value) {
            if (value != null) {
              updateDefaultAspectRatioType(value);
            }
          },
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
        const TVSettingsGroupHeader(title: '网络'),
        TVSettingsDropdownRow<String>(
          label: '番剧数据源',
          subtitle: bangumiAccelerationSubtitle(bangumiAccelerationMode),
          value: bangumiAccelerationMode,
          items: bangumiAccelerationLabelMap.keys.toList(),
          itemLabel: (mode) => bangumiAccelerationLabelMap[mode] ?? mode,
          onChanged: (value) {
            if (value != null) {
              updateBangumiAcceleration(value);
            }
          },
          isLast: true,
          onMoveLeft: widget.onExitLeft,
          sidebarFocusNode: widget.sidebarFocusNode,
        ),
      ],
    );
  }
}
