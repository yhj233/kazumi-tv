import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'tv_info_page.dart';

/// 番组详情页面模块
final tvInfoModule = createModule(
  path: '/info',
  register: (c) {
    c.route(
      '/',
      child: (context, state) {
        final bangumiItem = state.arguments as BangumiItem;
        return TVInfoPage(bangumiItem: bangumiItem);
      },
    );
  },
);
