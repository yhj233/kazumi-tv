import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'tv_player_page.dart';

/// 播放器页面模块
final tvPlayerModule = createModule(
  path: '/player',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => const TVPlayerPage(),
      )
      ..addSingleton(AudioController.new)
      ..addSingleton(
        () => PlayerController(
          inject<ShaderAssetService>(),
          inject<DownloadController>(),
          inject<AudioController>(),
        ),
      );
  },
);
