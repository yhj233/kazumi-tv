import 'package:flutter_modular/flutter_modular.dart';
import 'tv_collect_page.dart';

/// 收藏页面模块
final tvCollectModule = createModule(
  path: '/collect',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVCollectPage(),
    );
  },
);
