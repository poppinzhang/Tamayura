import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';
import 'package:tamayura/ui/device_order_dialog.dart';

const _devices = [
  DeviceView(id: 'a', name: '相机相册', address: '192.0.2.1:50728', online: true),
  DeviceView(id: 'b', name: '旅行相册', address: '192.0.2.2:50728', online: false),
  DeviceView(id: 'c', name: '家庭相册', address: '192.0.2.3:50728', online: true),
];

class _OrderModel extends TamayuraModel {
  @override
  List<DeviceView> devices = List.of(_devices);
  @override
  bool deviceOrderSaving = false;
  final requests = <List<String>>[];
  Completer<bool>? pendingSave;
  bool failSave = false;
  bool throwOnSave = false;
  @override
  String? error;
  @override
  String? selectedDeviceId = 'b';
  @override
  String? selectedCollectionKey;
  @override
  bool get loading => false;
  @override
  bool get busy => false;
  @override
  String get deviceName => '本机';
  @override
  List<String> get addresses => [];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> get sharedFolders => const [
    SharedFolder(id: 'pictures', uri: 'Pictures', name: '照片'),
  ];
  @override
  String? get downloadFolder => 'Downloads';
  @override
  int get localMediaCount => 0;
  @override
  List<MediaCollection> get collections => [];
  @override
  List<MediaView> get media => [];
  @override
  Map<String, TransferView> get transfers => {};

  @override
  Future<bool> reorderDevices(List<String> deviceIds) async {
    requests.add(List.of(deviceIds));
    deviceOrderSaving = true;
    notifyListeners();
    try {
      if (throwOnSave) throw StateError('Cannot save device order');
      final saved = await (pendingSave?.future ?? Future.value(!failSave));
      if (!saved) {
        error = '设备顺序保存失败，请重试。';
        return false;
      }
      devices = [
        for (final id in deviceIds)
          devices.singleWhere((device) => device.id == id),
      ];
      error = null;
      return true;
    } finally {
      deviceOrderSaving = false;
      notifyListeners();
    }
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
  @override
  Future<void> refresh() async {}
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
  Future<void> selectCollection(String? key) async {}
  @override
  Future<void> download(MediaView item) async {}
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

Future<void> _show(
  WidgetTester tester,
  _OrderModel model, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(TamayuraApp(model: model));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('devices-tab')));
  await tester.pumpAndSettle();
}

Future<void> _openOrder(WidgetTester tester) async {
  final entry = find.byKey(const Key('edit-device-order'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

List<String> _draftOrder(WidgetTester tester) => tester
    .widgetList<ReorderableDragStartListener>(
      find.byType(ReorderableDragStartListener),
    )
    .map(
      (handle) => (handle.key! as ValueKey<String>).value.replaceFirst(
        'device-order-drag-',
        '',
      ),
    )
    .toList();

Future<void> _moveDown(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('device-order-down-$id')));
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      'saved device order updates devices and album without changing selection on $platform',
      (tester) async {
        final model = _OrderModel();
        await _show(
          tester,
          model,
          size: platform == TargetPlatform.android
              ? const Size(320, 844)
              : const Size(1280, 860),
        );
        await _openOrder(tester);
        expect(find.textContaining('相册中的设备也会按此顺序展示'), findsOneWidget);
        await _moveDown(tester, 'a');
        expect(_draftOrder(tester), ['b', 'a', 'c']);
        await tester.tap(find.byKey(const Key('device-order-save')));
        await tester.pumpAndSettle();
        expect(find.byType(DeviceOrderDialog), findsNothing);
        expect(model.requests, [
          ['b', 'a', 'c'],
        ]);
        final deviceTiles = tester.widgetList<ListTile>(
          find.byWidgetPredicate(
            (widget) =>
                widget is ListTile &&
                const [
                  Key('device-a'),
                  Key('device-b'),
                  Key('device-c'),
                ].contains(widget.key),
          ),
        );
        expect(deviceTiles.map((tile) => tile.key), [
          const Key('device-b'),
          const Key('device-a'),
          const Key('device-c'),
        ]);
        await tester.tap(find.byKey(const Key('album-tab')));
        await tester.pumpAndSettle();
        final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
        expect(chips.map((chip) => (chip.label as Text).data), [
          '全部设备',
          '旅行相册',
          '相机相册',
          '家庭相册',
        ]);
        expect(model.selectedDeviceId, 'b');
        expect(
          chips
              .where((chip) => chip.selected)
              .map((chip) => (chip.label as Text).data),
          ['旅行相册'],
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets('cancel discards the draft and reopening uses saved order', (
    tester,
  ) async {
    final model = _OrderModel();
    await _show(tester, model);
    await _openOrder(tester);
    await _moveDown(tester, 'a');
    await tester.tap(find.byKey(const Key('device-order-cancel')));
    await tester.pumpAndSettle();
    expect(model.requests, isEmpty);
    expect(model.devices.map((device) => device.id), ['a', 'b', 'c']);
    await _openOrder(tester);
    expect(_draftOrder(tester), ['a', 'b', 'c']);
  });

  for (final throws in [false, true]) {
    testWidgets('failed save retains draft for retry (throws: $throws)', (
      tester,
    ) async {
      final model = _OrderModel()
        ..failSave = !throws
        ..throwOnSave = throws;
      await _show(tester, model);
      await _openOrder(tester);
      await _moveDown(tester, 'a');
      await tester.tap(find.byKey(const Key('device-order-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-order-error')), findsOneWidget);
      expect(_draftOrder(tester), ['b', 'a', 'c']);
      expect(model.devices.map((device) => device.id), ['a', 'b', 'c']);
      model
        ..failSave = false
        ..throwOnSave = false;
      await tester.tap(find.byKey(const Key('device-order-save')));
      await tester.pumpAndSettle();
      expect(model.requests, [
        ['b', 'a', 'c'],
        ['b', 'a', 'c'],
      ]);
      expect(find.byType(DeviceOrderDialog), findsNothing);
      expect(model.devices.map((device) => device.id), ['b', 'a', 'c']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pending save blocks repeated submission, editing and closing', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final model = _OrderModel()..pendingSave = pending;
    await _show(tester, model);
    await _openOrder(tester);
    await _moveDown(tester, 'a');
    final save = find.byKey(const Key('device-order-save'));
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();
    expect(model.requests.length, 1);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('device-order-cancel')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byType(DeviceOrderDialog),
              matching: find.byType(IconButton),
            ),
          )
          .every((button) => button.onPressed == null),
      isTrue,
    );
    expect(
      tester
          .widgetList<ReorderableDragStartListener>(
            find.byType(ReorderableDragStartListener),
          )
          .every((handle) => !handle.enabled),
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceOrderDialog), findsOneWidget);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceOrderDialog), findsNothing);
    expect(model.requests.length, 1);
  });

  testWidgets('arrows respect list boundaries and identify same-name devices', (
    tester,
  ) async {
    final model = _OrderModel()
      ..devices = [
        for (final device in _devices.take(2))
          DeviceView(
            id: device.id,
            name: '同名设备',
            address: device.address,
            online: device.online,
          ),
      ];
    await _show(tester, model);
    await _openOrder(tester);
    expect(find.text('192.0.2.1:50728'), findsOneWidget);
    expect(find.text('192.0.2.2:50728'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('device-order-up-a')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('device-order-down-b')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('device-order-up-b')));
    await tester.pumpAndSettle();
    expect(_draftOrder(tester), ['b', 'a']);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('device-order-up-b')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('device-order-down-a')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('device-order-save')));
    await tester.pumpAndSettle();
    expect(model.requests.single, ['b', 'a']);
  });

  testWidgets('drag handle reorders the draft', (tester) async {
    final model = _OrderModel();
    await _show(tester, model);
    await _openOrder(tester);
    final first = find.byKey(const Key('device-order-drag-a'));
    final second = find.byKey(const Key('device-order-drag-b'));
    final distance = tester.getCenter(second).dy - tester.getCenter(first).dy;
    final gesture = await tester.startGesture(tester.getCenter(first));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(Offset(0, distance * 1.7));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_draftOrder(tester), ['b', 'a', 'c']);
    await tester.tap(find.byKey(const Key('device-order-save')));
    await tester.pumpAndSettle();
    expect(model.requests.single, ['b', 'a', 'c']);
  });

  for (final count in [0, 1]) {
    testWidgets('ordering entry is hidden with $count saved devices', (
      tester,
    ) async {
      await _show(
        tester,
        _OrderModel()..devices = _devices.take(count).toList(),
      );
      expect(find.byKey(const Key('edit-device-order')), findsNothing);
    });
  }
}
