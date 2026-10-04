import 'package:flutter_modular/flutter_modular.dart';
import 'tv_main_page.dart';

/// 主页面模块
final tvMainModule = createModule(
  path: '/',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVMainPage(),
    );
  },
);
