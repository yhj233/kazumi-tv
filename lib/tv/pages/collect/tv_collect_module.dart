import 'package:flutter_modular/flutter_modular.dart';
import 'tv_collect_page.dart';

class TVCollectModule extends Module {
  @override
  void register(ModularContext c) {
    c.child('/', child: (_) => const TVCollectPage());
  }
}
