import 'package:flutter_modular/flutter_modular.dart';
import '../../../pages/player/player_controller.dart';
import '../../../services/player/audio_controller.dart';
import '../../../services/shaders/shader_asset_service.dart';
import '../../../pages/download/download_controller.dart';
import 'tv_player_page.dart';

class TVPlayerModule extends Module {
  @override
  void register(ModularContext c) {
    c.child("/", child: (_) => const TVPlayerPage());

    c.addSingleton(AudioController.new);
    c.addSingleton(
      (i) => PlayerController(
        i.get<ShaderAssetService>(),
        i.get<DownloadController>(),
        i.get<AudioController>(),
      ),
    );
  }
}
