import 'package:flutter_modular/flutter_modular.dart';
import 'tv_info_page.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

class TVInfoModule extends Module {
  @override
  void register(ModularContext c) {
    c.child(
      "/",
      child: (context, state) {
        final bangumiItem = state.arguments as BangumiItem;
        return TVInfoPage(bangumiItem: bangumiItem);
      },
    );
  }
}
