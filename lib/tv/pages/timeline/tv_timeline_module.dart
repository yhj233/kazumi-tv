import 'package:flutter_modular/flutter_modular.dart';

import 'tv_timeline_page.dart';

class TVTimelineModule extends Module {
  @override
  void register(ModularContext c) {
    c.child('/', child: (_) => const TVTimelinePage());
  }
}
