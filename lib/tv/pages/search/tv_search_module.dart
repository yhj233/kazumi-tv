import 'package:flutter_modular/flutter_modular.dart';
import 'tv_search_page.dart';

/// 搜索页面模块
final tvSearchModule = createModule(
  path: '/search',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVSearchPage(),
    );
  },
);
