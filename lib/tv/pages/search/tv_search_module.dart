import 'package:flutter_modular/flutter_modular.dart';
import 'tv_search_page.dart';

class TVSearchModule extends Module {
  @override
  void register(ModularContext c) {
    c.child('/', child: (_) => const TVSearchPage());
  }
}
