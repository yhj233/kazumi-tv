import 'package:flutter_modular/flutter_modular.dart';
import 'tv_player_page.dart';

/// 播放器页面模块。
///
/// 这里**只声明路由**，DI 全部注册在根模块 `tvModule` 中：
/// 详情页（`/info`）在跳转到播放器之前就需要 `PlayerController`，
/// 而 feature 子模块（带 `path`）的绑定只有在进入该路由后才会生效，
/// 放在这里会导致详情页 `Modular.get<PlayerController>()` 失败。
final tvPlayerModule = createModule(
  path: '/player',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const TVPlayerPage(),
    );
  },
);
