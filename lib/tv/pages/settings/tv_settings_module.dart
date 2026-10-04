import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/tv/pages/settings/tv_settings_page.dart';
import 'package:kazumi/tv/pages/settings/plugin/tv_plugin_module.dart';

class TVSettingsModule extends Module {
  @override
  void register(ModularContext c) {
    c.child('/', child: (_) => const TVSettingsPage());
    c.module('/plugin', module: TVPluginModule());
  }
}
