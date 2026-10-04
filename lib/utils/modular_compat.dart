import 'package:flutter_modular/flutter_modular.dart';

/// Compatibility layer for the old `Modular` global getter API.
///
/// The new `flutter_modular` 7.x API uses `createModule` and `ModularContext`
/// instead of the old global `Modular` getter and `Module` class.
/// This class provides a backward-compatible static interface.
class Modular {
  static ModularContext? _context;

  /// Set the modular context. Called by [TVApp] during initialization.
  static void setContext(ModularContext context) {
    _context = context;
  }

  /// Get a registered service from the modular context.
  static T get<T>() {
    if (_context == null) {
      throw StateError('Modular context not initialized');
    }
    return _context!.get<T>();
  }

  /// Get a registered service, returning null if not found.
  static T? getOrNull<T>() {
    if (_context == null) return null;
    return _context!.getOrNull<T>();
  }

  /// Navigator for navigation operations.
  static Navigator get to {
    if (_context == null) {
      throw StateError('Modular context not initialized');
    }
    return _context!.navigator;
  }

  /// Router configuration.
  static IRouterConfig get routerConfig {
    if (_context == null) {
      throw StateError('Modular context not initialized');
    }
    return _context!.routerConfig;
  }

  /// Set observers for the modular system.
  static void setObservers(List<Observer> observers) {
    // Observers are set via ModularApp's navigatorObservers parameter.
  }
}

/// A wrapper around the old `Module` class that works with the new API.
///
/// Subclasses of [CompatModule] can continue to use `binds` and `routes`
/// methods, and they will be converted to the new `createModule` format.
abstract class CompatModule {
  final void Function(ModularContext i) _binds;
  final void Function(ModularContext r) _routes;

  CompatModule({
    required void Function(ModularContext i) binds,
    required void Function(ModularContext r) routes,
  }) : _binds = binds,
       _routes = routes;

  /// Create a `Module` from this compat module.
  Module toModule() {
    return Module(
      register: (c) {
        _binds(c);
        _routes(c);
      },
    );
  }
}
