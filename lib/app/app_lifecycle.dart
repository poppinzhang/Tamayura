import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Separates window visibility from focus and from refreshing on activation.
class AppLifecycleCoordinator {
  AppLifecycleCoordinator({
    required this.isMacOS,
    this.isWindows = false,
    required this.setForeground,
    required this.onResume,
    this.isWindowVisible,
  });

  final bool isMacOS;
  final bool isWindows;
  bool get _desktop => isMacOS || isWindows;
  final Future<void> Function(bool foreground) setForeground;
  final Future<void> Function() onResume;
  // macOS counts status-menu popups as visible application windows. Check the
  // retained main window before treating those lifecycle events as foreground.
  final Future<bool> Function()? isWindowVisible;
  bool? _foreground;
  int _stateRevision = 0;

  Future<void> initialize(AppLifecycleState? state) async {
    await _setForeground(
      state == AppLifecycleState.resumed ||
          (_desktop && (state == null || state == AppLifecycleState.inactive)),
    );
  }

  Future<void> handleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        // Re-read native sharing status on activation even if the window was
        // already visible but unfocused.
        if (await _setForeground(true, force: true)) await onResume();
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

  Future<bool> _setForeground(bool foreground, {bool force = false}) async {
    final revision = ++_stateRevision;
    if (foreground && _desktop && isWindowVisible != null) {
      try {
        foreground = await isWindowVisible!();
      } catch (_) {
        // A failed visibility query must not enable sharing while hidden.
        // The next activation/visibility event retries the native query.
        foreground = false;
      }
      if (revision != _stateRevision) return false;
    }
    if (!force && _foreground == foreground) return foreground;
    _foreground = foreground;
    await setForeground(foreground);
    return revision == _stateRevision && _foreground == true;
  }
}
