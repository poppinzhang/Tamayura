import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/app_lifecycle.dart';

void main() {
  test(
    'Windows visibility controls sharing independently from window focus',
    () async {
      final foreground = <bool>[];
      var refreshes = 0;
      final lifecycle = AppLifecycleCoordinator(
        isMacOS: false,
        isWindows: true,
        setForeground: (value) async => foreground.add(value),
        onResume: () async => refreshes++,
      );
      await lifecycle.initialize(null);
      await lifecycle.handleState(AppLifecycleState.inactive);
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
}
