import 'package:flutter_modular/flutter_modular.dart';
import 'tv_timeline_page.dart';

/// 时间线页面模块
final tvTimelineModule = createModule(
  path: '/timeline',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVTimelinePage(),
    );
  },
);
