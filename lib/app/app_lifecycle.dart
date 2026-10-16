import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Separates window visibility from focus and from refreshing on activation.
class AppLifecycleCoordinator {
  AppLifecycleCoordinator({
    required this.isMacOS,
    this.isWindows = false,
    required this.setForeground,
    required this.onResume,
  });

  final bool isMacOS;
  final bool isWindows;
  bool get _desktop => isMacOS || isWindows;
  final Future<void> Function(bool foreground) setForeground;
  final Future<void> Function() onResume;
  bool? _foreground;

  Future<void> initialize(AppLifecycleState? state) => _setForeground(
    state == AppLifecycleState.resumed ||
        (_desktop && (state == null || state == AppLifecycleState.inactive)),
  );

  Future<void> handleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        // Re-read native sharing status on activation even if the window was
        // already visible but unfocused.
        await _setForeground(true, force: true);
        if (_foreground == true) await onResume();
      case AppLifecycleState.inactive:
        // On macOS this also occurs when a hidden window becomes visible
        // without gaining focus. Restore sharing without rescanning media.
        if (_desktop) await _setForeground(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        await _setForeground(false);
    }
  }

  Future<void> _setForeground(bool foreground, {bool force = false}) async {
    if (!force && _foreground == foreground) return;
    _foreground = foreground;
    await setForeground(foreground);
  }
}
