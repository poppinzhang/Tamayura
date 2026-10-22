import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/app_lifecycle.dart';

void main() {
  test(
    'Linux window visibility controls sharing independently from focus',
    () async {
      final foreground = <bool>[];
      var refreshes = 0;
      final lifecycle = AppLifecycleCoordinator(
        isMacOS: false,
        isLinux: true,
        setForeground: (value) async => foreground.add(value),
        onResume: () async => refreshes++,
      );
      // GTK reports a mapped but unfocused window as inactive.
      await lifecycle.initialize(null);
      await lifecycle.handleState(AppLifecycleState.inactive);
      // Closing to the tray withdraws the window; minimizing iconifies it.
      await lifecycle.handleState(AppLifecycleState.hidden);
      await lifecycle.handleState(AppLifecycleState.inactive);
      expect(foreground, [true, false, true]);
      expect(refreshes, 0);
      await lifecycle.handleState(AppLifecycleState.resumed);
      expect(refreshes, 1);
      await lifecycle.handleState(AppLifecycleState.detached);
      expect(foreground.last, isFalse);
    },
  );

  test('an unfocused Linux window at startup still shares', () async {
    final foreground = <bool>[];
    final lifecycle = AppLifecycleCoordinator(
      isMacOS: false,
      isLinux: true,
      setForeground: (value) async => foreground.add(value),
      onResume: () async {},
    );
    await lifecycle.initialize(AppLifecycleState.inactive);
    expect(foreground, [true]);
  });
}
