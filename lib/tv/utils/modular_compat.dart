import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// Compatibility layer for the old `Modular` global getter API.
///
/// In flutter_modular 7.x, the global `Modular` getter no longer exists.
/// This class provides a backward-compatible static interface that wraps
/// the new `inject<T>()` function and stores a NavigatorState reference.
class Modular {
  static NavigatorState? _navigator;

  /// Set the navigator reference. Called from [TVApp] during build.
  static void setNavigator(NavigatorState navigator) {
    _navigator = navigator;
  }

  /// Get a registered singleton service.
  static T get<T>() => inject<T>();

  /// Get the navigator state for navigation operations.
  static NavigatorState get to => _navigator!;
}
