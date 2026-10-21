import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

class _NavigationModel extends TamayuraModel {
  @override
  Locale get locale => const Locale('en');
  @override
  bool loading = false;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  String get deviceName => 'This device';
  @override
  List<String> get addresses => const [];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> get sharedFolders => const [];
  @override
  String? get downloadFolder => null;
  @override
  int get localMediaCount => 0;
  @override
  final devices = List.generate(
    12,
    (index) => DeviceView(
      id: 'peer-$index',
      name: 'Device $index',
      address: '',
      online: false,
    ),
  );
  @override
  String? selectedDeviceId = 'peer-0';
  @override
  String? selectedCollectionKey = 'peer-0/camera';
  @override
  final collections = [
    MediaCollection(
      deviceId: 'peer-0',
      sharedFolderId: 'camera',
      sharedFolderName: 'Camera',
      itemCount: 120,
      thumbnail: Uint8List(0),
    ),
  ];
  @override
  final media = List.generate(
    120,
    (index) => MediaView(
      id: 'photo-$index',
      deviceId: 'peer-0',
      sharedFolderId: 'camera',
      sharedFolderName: 'Camera',
      name: 'Photo $index.jpg',
      mimeType: 'image/jpeg',
      size: 1024,
      modified: DateTime(2026, 10, 1),
      thumbnail: Uint8List(0),
    ),
  );
  @override
  final Map<String, TransferView> transfers = {};
  int refreshCalls = 0;
  int downloadCalls = 0;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
  @override
  Future<void> refresh() async => refreshCalls++;
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
    notifyListeners();
  }

  @override
  Future<void> selectCollection(String? key) async {
    selectedCollectionKey = key;
    notifyListeners();
  }

  @override
  Future<void> download(MediaView item) async => downloadCalls++;
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {}
}

const _tabs = ['album', 'devices', 'settings'];
const _labels = ['Album', 'Devices', 'Settings'];
const _desktopPlatforms = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

Finder _page(int tab) =>
    find.byKey(PageStorageKey('${_tabs[tab]}-scroll'), skipOffstage: false);

ScrollPosition _position(WidgetTester tester, int tab) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: _page(tab),
            matching: find.byType(Scrollable, skipOffstage: false),
            skipOffstage: false,
          )
          .first,
    )
    .position;

Finder _navigationLabel(int tab) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is NavigationBar || widget is NavigationRail,
  ),
  matching: find.text(_labels[tab]),
);

int _selectedTab(WidgetTester tester) =>
    find.byType(NavigationBar).evaluate().isNotEmpty
    ? tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex
    : tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex!;

Future<void> _show(
  WidgetTester tester,
  _NavigationModel model, {
  Size size = const Size(480, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(model.dispose);
  await tester.pumpWidget(TamayuraApp(model: model));
  // A loading indicator deliberately never settles.
  if (!model.loading) await tester.pumpAndSettle();
}

Future<void> _selectAndScroll(WidgetTester tester, int tab) async {
  await tester.tap(_navigationLabel(tab));
  await tester.pumpAndSettle();
  await tester.pump(kDoubleTapTimeout);
  await tester.drag(_page(tab), const Offset(0, -450));
  await tester.pumpAndSettle();
  expect(_position(tester, tab).pixels, greaterThan(100));
}

Future<void> _doubleTap(WidgetTester tester, int tab) async {
  await tester.tap(_navigationLabel(tab));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(_navigationLabel(tab));
  await tester.pump();
}

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  for (final layout in [
    (
      name: 'bottom navigation',
      size: const Size(480, 700),
      extended: null,
      platforms: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    ),
    (
      name: 'compact desktop navigation',
      size: const Size(920, 700),
      extended: false,
      platforms: _desktopPlatforms,
    ),
    (
      name: 'expanded desktop navigation',
      size: const Size(1280, 700),
      extended: true,
      platforms: _desktopPlatforms,
    ),
  ]) {
    testWidgets('${layout.name} double taps return each page to its top', (
      tester,
    ) async {
      final model = _NavigationModel();
      await _show(tester, model, size: layout.size);
      if (layout.extended == null) {
        expect(find.byType(NavigationBar), findsOneWidget);
      } else {
        expect(
          tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
          layout.extended,
        );
      }

      final offsets = <double>[];
      for (var tab = 0; tab < _tabs.length; tab++) {
        await _selectAndScroll(tester, tab);
        offsets.add(_position(tester, tab).pixels);
      }
      for (var tab = 0; tab < _tabs.length; tab++) {
        // Tapping the text exercises the complete native destination area.
        await tester.tap(_navigationLabel(tab));
        await tester.pump(const Duration(milliseconds: 100));
        expect(_selectedTab(tester), tab);
        expect(_position(tester, tab).pixels, offsets[tab]);
        await tester.tap(_navigationLabel(tab));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(_position(tester, tab).pixels, greaterThan(0));
        expect(_position(tester, tab).pixels, lessThan(offsets[tab]));
        await tester.pumpAndSettle();
        expect(
          _position(tester, tab).pixels,
          _position(tester, tab).minScrollExtent,
        );
        for (var other = tab + 1; other < _tabs.length; other++) {
          expect(_position(tester, other).pixels, offsets[other]);
        }
      }
      expect(model.selectedDeviceId, 'peer-0');
      expect(model.selectedCollectionKey, 'peer-0/camera');
      expect(model.refreshCalls, 0);
      expect(model.downloadCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: layout.platforms);
  }

  testWidgets('album overview double tap preserves the collection overview', (
    tester,
  ) async {
    final model = _NavigationModel()
      ..selectedDeviceId = null
      ..selectedCollectionKey = null;
    model.collections
      ..clear()
      ..addAll(
        List.generate(
          24,
          (index) => MediaCollection(
            deviceId: 'peer-0',
            sharedFolderId: 'collection-$index',
            sharedFolderName: 'Collection $index',
            itemCount: 120,
            thumbnail: Uint8List(0),
          ),
        ),
      );
    await _show(tester, model);
    await _selectAndScroll(tester, 0);
    await _doubleTap(tester, 0);
    await tester.pumpAndSettle();
    expect(_position(tester, 0).pixels, 0);
    expect(model.selectedCollectionKey, isNull);
    expect(model.selectedDeviceId, isNull);
    expect(model.refreshCalls, 0);
    expect(model.downloadCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'resizing a desktop rail to bottom navigation preserves single scroll attachments',
    (tester) async {
      await _show(tester, _NavigationModel(), size: const Size(1280, 700));
      expect(find.byType(NavigationRail), findsOneWidget);
      final controllers = <ScrollController>[];
      for (var tab = 0; tab < _tabs.length; tab++) {
        await _selectAndScroll(tester, tab);
        final controller = tester.widget<ScrollView>(_page(tab)).controller!;
        expect(controller.positions, hasLength(1));
        controllers.add(controller);
      }

      tester.view.physicalSize = const Size(480, 700);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(_selectedTab(tester), 2);
      for (var tab = 0; tab < _tabs.length; tab++) {
        expect(
          tester.widget<ScrollView>(_page(tab)).controller,
          same(controllers[tab]),
        );
        expect(controllers[tab].positions, hasLength(1));
        expect(_position(tester, tab).pixels, greaterThan(0));
        await _doubleTap(tester, tab);
        await tester.pumpAndSettle();
        expect(_position(tester, tab).pixels, 0);
        expect(controllers[tab].positions, hasLength(1));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: _desktopPlatforms,
  );

  testWidgets(
    'separate taps and different destinations retain scroll offsets',
    (tester) async {
      await _show(tester, _NavigationModel());
      await _selectAndScroll(tester, 2);
      final settingsOffset = _position(tester, 2).pixels;
      await tester.tap(_navigationLabel(2));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
      await tester.tap(_navigationLabel(2));
      await tester.pumpAndSettle();
      expect(_position(tester, 2).pixels, settingsOffset);

      await _selectAndScroll(tester, 1);
      final devicesOffset = _position(tester, 1).pixels;
      await tester.tap(_navigationLabel(1));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(_navigationLabel(2));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(_navigationLabel(1));
      await tester.pumpAndSettle();
      expect(_position(tester, 1).pixels, devicesOffset);
      expect(_position(tester, 2).pixels, settingsOffset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop shortcuts neither scroll to top nor complete a navigation double tap',
    (tester) async {
      await _show(tester, _NavigationModel(), size: const Size(1280, 700));
      await _selectAndScroll(tester, 2);
      final offset = _position(tester, 2).pixels;
      await _shortcut(tester, LogicalKeyboardKey.digit3);
      await _shortcut(tester, LogicalKeyboardKey.digit3);
      expect(_position(tester, 2).pixels, offset);

      await tester.tap(_navigationLabel(2));
      await tester.pump(const Duration(milliseconds: 50));
      await _shortcut(tester, LogicalKeyboardKey.digit2);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(_navigationLabel(2));
      await tester.pumpAndSettle();
      expect(_selectedTab(tester), 2);
      expect(_position(tester, 2).pixels, offset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: _desktopPlatforms,
  );

  for (final feature in ['disableAnimations', 'accessibleNavigation']) {
    testWidgets('$feature makes double-tap scrolling immediate', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(
            disableAnimations: feature == 'disableAnimations',
            accessibleNavigation: feature == 'accessibleNavigation',
          );
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _show(tester, _NavigationModel());
      for (var tab = 0; tab < _tabs.length; tab++) {
        await _selectAndScroll(tester, tab);
        await _doubleTap(tester, tab);
        expect(
          _position(tester, tab).pixels,
          _position(tester, tab).minScrollExtent,
        );
        expect(_position(tester, tab).isScrollingNotifier.value, isFalse);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('double taps are safe while pages are loading and at the top', (
    tester,
  ) async {
    final model = _NavigationModel()..loading = true;
    await _show(tester, model);
    for (var tab = 0; tab < _tabs.length; tab++) {
      await _doubleTap(tester, tab);
      expect(_selectedTab(tester), tab);
      expect(_page(tab), findsNothing);
      expect(tester.takeException(), isNull);
    }
    model.loading = false;
    model.media.clear();
    model.collections.clear();
    model.devices.clear();
    model.notifyListeners();
    await tester.pumpAndSettle();
    for (var tab = 0; tab < _tabs.length; tab++) {
      await _doubleTap(tester, tab);
      await tester.pumpAndSettle();
      expect(_position(tester, tab).pixels, 0);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'disposing after one navigation tap cancels double-tap tracking',
    (tester) async {
      await _show(tester, _NavigationModel());
      await tester.tap(_navigationLabel(2));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(kDoubleTapTimeout);
      expect(tester.takeException(), isNull);
    },
  );
}
