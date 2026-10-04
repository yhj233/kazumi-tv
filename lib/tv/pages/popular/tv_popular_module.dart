import 'package:flutter_modular/flutter_modular.dart';
import 'tv_popular_page.dart';

/// 热门页面模块
final tvPopularModule = createModule(
  path: '/popular',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVPopularPage(),
    );
  },
);
