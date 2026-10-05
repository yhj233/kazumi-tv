import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// TV 应用的根 Navigator GlobalKey。
///
/// 由 `main.dart` 交给 `MaterialApp(navigatorKey: ...)` 使用，
/// 保证任意时刻都能从任意位置拿到根 NavigatorState。
final GlobalKey<NavigatorState> tvNavigatorKey = GlobalKey<NavigatorState>();

/// Compatibility layer for the old `Modular` global getter API.
///
/// In flutter_modular 7.x, the global `Modular` facade no longer exists.
/// This class provides a backward-compatible static interface that wraps
/// the new `inject<T>()` function and stores a NavigatorState reference.
class Modular {
  static NavigatorState? _navigator;

  /// Set the navigator reference. Called from the root widget during build.
  static void setNavigator(NavigatorState navigator) {
    _navigator = navigator;
  }

  /// 获取根 NavigatorState。
  ///
  /// 优先使用显式绑定的实例，未绑定时回退到 [tvNavigatorKey]，
  /// 避免出现 `Null check operator used on a null value`。
  static NavigatorState? get navigator => _navigator ?? tvNavigatorKey.currentState;

  /// Get a registered singleton service.
  static T get<T>() => inject<T>();

  /// Get the navigator state for navigation operations.
  ///
  /// 注意：未初始化时会抛错，新代码请优先使用 [pushNamed] / [pop]。
  static NavigatorState get to => navigator!;

  /// 压栈一个具名路由（navigator 未就绪时静默忽略，不会崩溃）。
  static Future<Object?>? pushNamed(
    String path, {
    Object? arguments,
  }) {
    final nav = navigator;
    if (nav == null) {
      debugPrint('TV: Modular.pushNamed($path) ignored - navigator is null');
      return null;
    }
    return nav.pushNamed<Object?>(path, arguments: arguments);
  }

  /// 出栈当前路由（栈底时不做任何事）。
  static void pop<T extends Object?>([T? result]) {
    final nav = navigator;
    if (nav == null) return;
    if (!nav.canPop()) return;
    nav.pop<T>(result);
  }
}
