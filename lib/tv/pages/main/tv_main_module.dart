import 'package:flutter_modular/flutter_modular.dart';
import 'tv_main_page.dart';

class TVMainModule extends Module {
  @override
  void register(ModularContext c) {
    c.child("/", child: (_) => const TVMainPage());
  }
}
