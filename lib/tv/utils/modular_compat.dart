import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// Compatibility layer for the old `Modular` global getter API.
///
/// In flutter_modular 7.x, the global `Modular` getter no longer exists.
/// This class provides a backward-compatible static interface that wraps
/// the new `inject<T>()` function and stores a Navigator reference.
class Modular {
  static Navigator? _navigator;

  /// Set the navigator reference. Called from [TVApp] during build.
  static void setNavigator(Navigator navigator) {
    _navigator = navigator;
  }

  /// Get a registered singleton service.
  static T get<T>() => inject<T>();

  /// Get the navigator for navigation operations.
  static Navigator get to => _navigator!;
}
