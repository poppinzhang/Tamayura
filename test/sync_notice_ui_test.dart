import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';
import 'package:tamayura/ui/sync_notice_transition.dart';

class _Model extends TamayuraModel {
  @override
  bool get loading => false;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  String get deviceName => '本机';
  @override
  List<String> get addresses => const [];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> get sharedFolders => const [
    SharedFolder(id: 'local', uri: 'content://shared', name: '共享'),
  ];
  @override
  String get downloadFolder => '接收';
  @override
  int get localMediaCount => 0;
  @override
  List<DeviceView> get devices => const [
    DeviceView(id: 'a', name: '设备 A', address: '', online: true),
    DeviceView(id: 'b', name: '设备 B', address: '', online: true),
  ];
  @override
  List<SyncProgress> syncProgress = [];
  @override
  String? selectedDeviceId;
  @override
  String? selectedCollectionKey;
  @override
  List<MediaCollection> get collections => [
    for (final device in devices)
      if (selectedDeviceId == null || selectedDeviceId == device.id)
        MediaCollection(
          deviceId: device.id,
          sharedFolderId: 'camera',
          sharedFolderName: '${device.name} 相册',
          itemCount: 1,
          thumbnail: Uint8List(0),
        ),
  ];
  @override
  List<MediaView> get media => const [];
  @override
  Map<String, TransferView> get transfers => const {};

  final retries = <String>[];

  @override
  Future<void> initialize() async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> retrySync(String peerId) async => retries.add(peerId);
  @override
  Future<void> chooseSharedFolder() async {}
  @override
  Future<void> removeSharedFolder(String id) async {}
  @override
  Future<void> chooseDownloadFolder() async {}
  @override
  Future<void> connect(String address) async {}
  @override
  Future<void> selectDevice(String? id) async {
    selectedDeviceId = id;
    selectedCollectionKey = null;
    notifyListeners();
  }

  @override
  Future<void> selectCollection(String? key) async {
    selectedCollectionKey = key;
    notifyListeners();
  }

  @override
  Future<void> download(MediaView item) async {}
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {}

  void setProgress(List<SyncProgress> value) {
    syncProgress = value;
    notifyListeners();
  }
}

SyncProgress _progress(
  String id,
  SyncPhase phase, {
  int readyCount = 2,
  int attempt = 0,
  Object? sessionId,
}) => SyncProgress(
  peerId: id,
  peerName: '设备 ${id.toUpperCase()}',
  phase: phase,
  totalCount: 10,
  readyCount: readyCount,
  attempt: attempt,
  sessionId: sessionId,
);

Finder _notice(String id) => find.byKey(Key('sync-progress-$id'));
Finder _dismiss(String id) => find.byKey(Key('dismiss-sync-$id'));
Finder _transition(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is SyncNoticeTransition && widget.notice.progress.peerId == id,
);

double _opacity(WidgetTester tester, String id) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: _transition(id),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

// Animate schedules initialization on a zero-delay event. Render it, then
// drain that event without advancing the five-second retention clock.
Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(Duration.zero);
}

Future<void> _show(WidgetTester tester, _Model model) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(TamayuraApp(model: model));
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _filter(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await _pump(tester);
}

void main() {
  testWidgets('idle and historical terminal states do not display notices', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.completed),
        _progress('b', SyncPhase.failed),
      ];
    await _show(tester, model);
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsNothing);

    model.notifyListeners();
    await _pump(tester);
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsNothing);

    model.setProgress([]);
    await _pump(tester);
    model.setProgress([_progress('a', SyncPhase.failed)]);
    await _pump(tester);
    expect(_notice('a'), findsNothing);

    model.setProgress([_progress('a', SyncPhase.connecting)]);
    await _pump(tester);
    expect(_notice('a'), findsOneWidget);
    expect(_dismiss('a'), findsOneWidget);
  });

  testWidgets('dismiss immediately removes notice and its occupied space', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model);
    final baseline = tester.getTopLeft(find.text('2 个合集')).dy;

    model.setProgress([_progress('a', SyncPhase.receiving)]);
    await _pump(tester);
    expect(tester.getTopLeft(find.text('2 个合集')).dy, greaterThan(baseline));

    await tester.tap(_dismiss('a'));
    await _pump(tester);
    expect(_notice('a'), findsNothing);
    expect(tester.getTopLeft(find.text('2 个合集')).dy, baseline);
    expect(model.syncProgress.single.phase, SyncPhase.receiving);
  });

  testWidgets(
    'dismissal survives progress and internal retry until next sync',
    (tester) async {
      final model = _Model()
        ..syncProgress = [_progress('a', SyncPhase.receiving)];
      await _show(tester, model);
      await tester.tap(_dismiss('a'));
      await _pump(tester);

      for (final progress in [
        _progress('a', SyncPhase.receiving, readyCount: 4),
        _progress('a', SyncPhase.connecting, attempt: 1),
        _progress('a', SyncPhase.receiving, readyCount: 6, attempt: 1),
        _progress('a', SyncPhase.committing, attempt: 1),
        _progress('a', SyncPhase.failed, attempt: 1),
      ]) {
        model.setProgress([progress]);
        await _pump(tester);
        expect(_notice('a'), findsNothing);
      }

      model.setProgress([_progress('a', SyncPhase.connecting)]);
      await _pump(tester);
      expect(_notice('a'), findsOneWidget);
      expect(_opacity(tester, 'a'), 1);
    },
  );

  testWidgets('removing an attempt allows its next sync to show again', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [_progress('a', SyncPhase.receiving)];
    await _show(tester, model);
    await tester.tap(_dismiss('a'));
    await _pump(tester);
    model.setProgress([]);
    await _pump(tester);
    model.setProgress([_progress('a', SyncPhase.receiving)]);
    await _pump(tester);
    expect(_notice('a'), findsOneWidget);
  });

  testWidgets('dismissal follows a session when the device ID is resolved', (
    tester,
  ) async {
    final session = Object();
    final model = _Model()
      ..syncProgress = [
        _progress('pending-device', SyncPhase.connecting, sessionId: session),
      ];
    await _show(tester, model);
    await tester.tap(_dismiss('pending-device'));
    await _pump(tester);
    model.setProgress([
      _progress('a', SyncPhase.receiving, sessionId: session),
    ]);
    await _pump(tester);
    expect(_notice('pending-device'), findsNothing);
    expect(_notice('a'), findsNothing);
    model.setProgress([
      _progress('a', SyncPhase.completed, sessionId: session),
    ]);
    await _pump(tester);
    expect(_notice('a'), findsNothing);
    model.setProgress([
      _progress('a', SyncPhase.connecting, sessionId: Object()),
    ]);
    await _pump(tester);
    expect(_notice('a'), findsOneWidget);
  });

  testWidgets('a new session appears when sync restarts between frames', (
    tester,
  ) async {
    final firstSession = Object();
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.receiving, sessionId: firstSession),
      ];
    await _show(tester, model);
    await tester.tap(_dismiss('a'));
    await _pump(tester);
    model.setProgress([
      _progress('a', SyncPhase.completed, sessionId: firstSession),
    ]);
    model.setProgress([
      _progress('a', SyncPhase.connecting, sessionId: Object()),
    ]);
    await _pump(tester);
    expect(_notice('a'), findsOneWidget);
    expect(_opacity(tester, 'a'), 1);
  });

  testWidgets('resolving a visible device identity preserves its transition', (
    tester,
  ) async {
    final session = Object();
    final model = _Model()
      ..syncProgress = [
        _progress('pending-device', SyncPhase.connecting, sessionId: session),
      ];
    await _show(tester, model);
    expect(_opacity(tester, 'pending-device'), 1);
    model.setProgress([
      _progress('a', SyncPhase.receiving, sessionId: session),
    ]);
    await _pump(tester);
    expect(_notice('pending-device'), findsNothing);
    expect(_notice('a'), findsOneWidget);
    expect(_opacity(tester, 'a'), 1);
    model.setProgress([
      _progress('a', SyncPhase.completed, sessionId: session),
    ]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_opacity(tester, 'a'), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 151));
    expect(_notice('a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final phase in [SyncPhase.completed, SyncPhase.failed]) {
    testWidgets('$phase stays five seconds then fades and releases space', (
      tester,
    ) async {
      final model = _Model();
      await _show(tester, model);
      final baseline = tester.getTopLeft(find.text('2 个合集')).dy;
      model.setProgress([_progress('a', SyncPhase.receiving)]);
      await _pump(tester);
      model.setProgress([_progress('a', phase)]);
      await _pump(tester);

      expect(_notice('a'), findsOneWidget);
      expect(_opacity(tester, 'a'), 1);
      final occupied = tester.getTopLeft(find.text('2 个合集')).dy;
      expect(occupied, greaterThan(baseline));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(_opacity(tester, 'a'), 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_notice('a'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      expect(_opacity(tester, 'a'), greaterThan(0));
      expect(_opacity(tester, 'a'), lessThan(1));
      final shrinking = tester.getTopLeft(find.text('2 个合集')).dy;
      expect(shrinking, greaterThan(baseline));
      expect(shrinking, lessThan(occupied));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 1));
      expect(_notice('a'), findsNothing);
      expect(tester.getTopLeft(find.text('2 个合集')).dy, baseline);

      model.notifyListeners();
      await _pump(tester);
      expect(_notice('a'), findsNothing);
    });

    for (final feature in ['disableAnimations', 'accessibleNavigation']) {
      testWidgets(
        '$phase keeps its retention with $feature then hides at once',
        (tester) async {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(
                disableAnimations: feature == 'disableAnimations',
                accessibleNavigation: feature == 'accessibleNavigation',
              );
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          final model = _Model();
          await _show(tester, model);
          final baseline = tester.getTopLeft(find.text('2 个合集')).dy;
          model.setProgress([_progress('a', SyncPhase.receiving)]);
          await _pump(tester);
          model.setProgress([_progress('a', phase)]);
          await _pump(tester);
          await tester.pump(const Duration(milliseconds: 4999));
          expect(_notice('a'), findsOneWidget);
          expect(
            tester.getTopLeft(find.text('2 个合集')).dy,
            greaterThan(baseline),
          );
          expect(
            find.descendant(
              of: _transition('a'),
              matching: find.byType(FadeTransition),
            ),
            findsNothing,
          );
          await tester.pump(const Duration(milliseconds: 1));
          expect(_notice('a'), findsNothing);
          expect(tester.getTopLeft(find.text('2 个合集')).dy, baseline);
        },
      );
    }

    testWidgets('$phase can be dismissed before the retention timer expires', (
      tester,
    ) async {
      final model = _Model()
        ..syncProgress = [_progress('a', SyncPhase.receiving)];
      await _show(tester, model);
      model.setProgress([_progress('a', phase)]);
      await _pump(tester);
      await tester.tap(_dismiss('a'));
      await _pump(tester);
      expect(_notice('a'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(_notice('a'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unrelated model updates do not restart the completion timer', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [_progress('a', SyncPhase.receiving)];
    await _show(tester, model);
    model.setProgress([_progress('a', SyncPhase.completed)]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 3));
    model.setProgress([_progress('a', SyncPhase.completed)]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1));
    expect(_notice('a'), findsNothing);
  });

  for (final reduceAtStart in [false, true]) {
    testWidgets(
      'changing reduced motion from $reduceAtStart preserves retention deadline',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduceAtStart);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final model = _Model()
          ..syncProgress = [_progress('a', SyncPhase.receiving)];
        await _show(tester, model);
        model.setProgress([_progress('a', SyncPhase.completed)]);
        await _pump(tester);
        await tester.pump(const Duration(seconds: 2));
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: !reduceAtStart);
        await _pump(tester);
        await tester.pump(const Duration(milliseconds: 2999));
        expect(_notice('a'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1));
        if (reduceAtStart) {
          expect(_notice('a'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 150));
          expect(_opacity(tester, 'a'), inExclusiveRange(0, 1));
          await tester.pump(const Duration(milliseconds: 151));
        }
        expect(_notice('a'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('enabling reduced motion during a fade removes it immediately', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final model = _Model()
      ..syncProgress = [_progress('a', SyncPhase.receiving)];
    await _show(tester, model);
    model.setProgress([_progress('a', SyncPhase.failed)]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_opacity(tester, 'a'), inExclusiveRange(0, 1));
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    await _pump(tester);
    expect(_notice('a'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new sync cancels the previous completion fade', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [_progress('a', SyncPhase.receiving)];
    await _show(tester, model);
    model.setProgress([_progress('a', SyncPhase.completed)]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_opacity(tester, 'a'), lessThan(1));

    model.setProgress([_progress('a', SyncPhase.receiving)]);
    await _pump(tester);
    expect(_opacity(tester, 'a'), 1);
    await tester.pump(const Duration(seconds: 6));
    expect(_notice('a'), findsOneWidget);
  });

  testWidgets('dismissal survives filters, collection browsing and tabs', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.receiving),
        _progress('b', SyncPhase.receiving),
      ];
    await _show(tester, model);
    await tester.tap(_dismiss('a'));
    await _pump(tester);
    await _filter(tester, '设备 B');
    expect(_notice('b'), findsOneWidget);
    await tester.tap(find.byKey(const Key('collection-b/camera')));
    await _pump(tester);
    expect(model.selectedCollectionKey, 'b/camera');
    await tester.tap(find.byKey(const Key('back-to-collections')));
    await _pump(tester);
    await _filter(tester, '全部设备');
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('album-tab')));
    await _pump(tester);
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsOneWidget);
  });

  testWidgets('completion expires while its device is filtered out', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.receiving),
        _progress('b', SyncPhase.receiving),
      ];
    await _show(tester, model);
    await _filter(tester, '设备 B');
    model.setProgress([
      _progress('a', SyncPhase.completed),
      _progress('b', SyncPhase.receiving),
    ]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1));
    await _filter(tester, '全部设备');
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsOneWidget);
  });

  testWidgets('filtering out a fading notice restores its current progress', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.receiving),
        _progress('b', SyncPhase.receiving),
      ];
    await _show(tester, model);
    model.setProgress([
      _progress('a', SyncPhase.completed),
      _progress('b', SyncPhase.receiving),
    ]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 100));
    final beforeFiltering = _opacity(tester, 'a');
    await _filter(tester, '设备 B');
    await tester.pump(const Duration(milliseconds: 100));
    await _filter(tester, '全部设备');
    expect(_opacity(tester, 'a'), greaterThan(0));
    expect(_opacity(tester, 'a'), lessThan(beforeFiltering));
    await tester.pump(const Duration(milliseconds: 101));
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion expires while viewing another tab', (tester) async {
    final model = _Model()
      ..syncProgress = [_progress('a', SyncPhase.receiving)];
    await _show(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await _pump(tester);
    model.setProgress([_progress('a', SyncPhase.failed)]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.byKey(const Key('album-tab')));
    await _pump(tester);
    expect(_notice('a'), findsNothing);
  });

  testWidgets('devices have independent completion timers and dismissals', (
    tester,
  ) async {
    final model = _Model()
      ..syncProgress = [
        _progress('a', SyncPhase.receiving),
        _progress('b', SyncPhase.receiving),
      ];
    await _show(tester, model);
    model.setProgress([
      _progress('a', SyncPhase.completed),
      _progress('b', SyncPhase.receiving),
    ]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 2));
    model.setProgress([
      _progress('a', SyncPhase.completed),
      _progress('b', SyncPhase.failed),
    ]);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1));
    expect(_notice('a'), findsNothing);
    expect(_notice('b'), findsOneWidget);
    expect(_opacity(tester, 'b'), 1);
    await tester.tap(_dismiss('b'));
    await _pump(tester);
    expect(_notice('b'), findsNothing);
    model.setProgress([
      _progress('a', SyncPhase.receiving),
      _progress('b', SyncPhase.failed),
    ]);
    await _pump(tester);
    expect(_notice('a'), findsOneWidget);
    expect(_notice('b'), findsNothing);
  });

  for (final fading in [false, true]) {
    testWidgets('disposing the page releases notices while fading is $fading', (
      tester,
    ) async {
      final model = _Model()
        ..syncProgress = [_progress('a', SyncPhase.receiving)];
      await _show(tester, model);
      for (var i = 0; i < 3; i++) {
        await _filter(tester, '设备 B');
        await _filter(tester, '全部设备');
      }
      model.setProgress([_progress('a', SyncPhase.failed)]);
      await _pump(tester);
      if (fading) {
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 100));
        expect(_opacity(tester, 'a'), inExclusiveRange(0, 1));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      model.setProgress([_progress('a', SyncPhase.receiving)]);
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }
}
