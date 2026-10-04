import 'package:flutter_modular/flutter_modular.dart';
import 'tv_popular_page.dart';

class TVPopularModule extends Module {
  @override
  void register(ModularContext c) {
    c.child('/', child: (_) => const TVPopularPage());
  }
}
