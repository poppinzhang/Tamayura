import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/app_lifecycle.dart';

void main() {
  late List<bool> foregroundChanges;
  late int refreshes;

  setUp(() {
    foregroundChanges = [];
    refreshes = 0;
  });

  AppLifecycleCoordinator coordinator({bool isMacOS = true}) =>
      AppLifecycleCoordinator(
        isMacOS: isMacOS,
        setForeground: (value) async => foregroundChanges.add(value),
        onResume: () async => refreshes++,
      );

  test('macOS cold start distinguishes visible and detached windows', () async {
    for (final state in [null, ...AppLifecycleState.values]) {
      foregroundChanges.clear();
      await coordinator().initialize(state);
      expect(foregroundChanges, [
        state == null ||
            state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive,
      ], reason: '$state');
    }
    expect(refreshes, 0);
  });

  test('Android cold start requires a resumed activity', () async {
    for (final state in [null, ...AppLifecycleState.values]) {
      foregroundChanges.clear();
      await coordinator(isMacOS: false).initialize(state);
      expect(foregroundChanges, [
        state == AppLifecycleState.resumed,
      ], reason: '$state');
    }
    expect(refreshes, 0);
  });

  test('macOS focus loss preserves sharing without a media refresh', () async {
    final lifecycle = coordinator();
    await lifecycle.initialize(AppLifecycleState.resumed);
    await lifecycle.handleState(AppLifecycleState.inactive);
    expect(foregroundChanges, [true]);
    expect(refreshes, 0);
  });

  test('macOS showing a window without focus restores sharing', () async {
    final lifecycle = coordinator();
    await lifecycle.initialize(AppLifecycleState.resumed);
    await lifecycle.handleState(AppLifecycleState.inactive);
    await lifecycle.handleState(AppLifecycleState.hidden);
    await lifecycle.handleState(AppLifecycleState.inactive);
    expect(foregroundChanges, [true, false, true]);
    expect(refreshes, 0);
    await lifecycle.handleState(AppLifecycleState.resumed);
    expect(foregroundChanges, [true, false, true, true]);
    expect(refreshes, 1);
  });

  test(
    'macOS hidden cold start can become visible without activation',
    () async {
      final lifecycle = coordinator();
      await lifecycle.initialize(AppLifecycleState.hidden);
      await lifecycle.handleState(AppLifecycleState.inactive);
      expect(foregroundChanges, [false, true]);
      expect(refreshes, 0);
    },
  );

  test('Android inactive keeps the existing foreground state', () async {
    final lifecycle = coordinator(isMacOS: false);
    await lifecycle.initialize(AppLifecycleState.resumed);
    await lifecycle.handleState(AppLifecycleState.inactive);
    expect(foregroundChanges, [true]);
    await lifecycle.handleState(AppLifecycleState.hidden);
    await lifecycle.handleState(AppLifecycleState.paused);
    await lifecycle.handleState(AppLifecycleState.hidden);
    await lifecycle.handleState(AppLifecycleState.inactive);
    expect(foregroundChanges, [true, false]);
    expect(refreshes, 0);
    await lifecycle.handleState(AppLifecycleState.resumed);
    expect(foregroundChanges, [true, false, true]);
    expect(refreshes, 1);
  });

  test('hidden, paused and detached windows all leave foreground', () async {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      foregroundChanges.clear();
      final lifecycle = coordinator();
      await lifecycle.initialize(AppLifecycleState.resumed);
      await lifecycle.handleState(state);
      expect(foregroundChanges, [true, false], reason: '$state');
    }
    expect(refreshes, 0);
  });

  test('activation waits for foreground setup before refreshing', () async {
    final ready = Completer<void>();
    final lifecycle = AppLifecycleCoordinator(
      isMacOS: true,
      setForeground: (foreground) async {
        foregroundChanges.add(foreground);
        if (foreground) await ready.future;
      },
      onResume: () async => refreshes++,
    );
    await lifecycle.initialize(AppLifecycleState.hidden);
    final resuming = lifecycle.handleState(AppLifecycleState.resumed);
    expect(foregroundChanges, [false, true]);
    expect(refreshes, 0);
    ready.complete();
    await resuming;
    expect(refreshes, 1);
  });

  test('a late activation does not refresh after hiding the window', () async {
    final ready = Completer<void>();
    final lifecycle = AppLifecycleCoordinator(
      isMacOS: true,
      setForeground: (foreground) async {
        if (foreground) await ready.future;
      },
      onResume: () async => refreshes++,
    );
    await lifecycle.initialize(AppLifecycleState.hidden);
    final resuming = lifecycle.handleState(AppLifecycleState.resumed);
    await lifecycle.handleState(AppLifecycleState.hidden);
    ready.complete();
    await resuming;
    expect(refreshes, 0);
  });
}
