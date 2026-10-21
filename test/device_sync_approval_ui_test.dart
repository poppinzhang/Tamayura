import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

DeviceView _device(
  String id,
  String name, {
  PeerSyncApproval approval = PeerSyncApproval.approved,
}) => DeviceView(
  id: id,
  name: name,
  address: '192.0.2.${id.codeUnitAt(0) % 200}:50728',
  online: true,
  syncApproval: approval,
);

class _ApprovalModel extends TamayuraModel {
  _ApprovalModel(this.devices, {List<String> requests = const []})
    : requests = List.of(requests);

  @override
  List<DeviceView> devices;
  final List<String> requests;
  final decisions = <(String, bool)>[];
  final dismissed = <String>[];
  final forgotten = <String>[];
  Completer<bool>? pendingForget;
  Set<String> forgetting = {};
  @override
  String? error;

  @override
  List<DeviceView> get syncApprovalRequests => [
    for (final id in requests) devices.singleWhere((device) => device.id == id),
  ];

  @override
  Future<void> setDeviceSyncEnabled(String id, bool enabled) async {
    requests.remove(id);
    decisions.add((id, enabled));
    devices = [
      for (final device in devices)
        device.id == id
            ? _device(
                device.id,
                device.name,
                approval: enabled
                    ? PeerSyncApproval.approved
                    : PeerSyncApproval.declined,
              )
            : device,
    ];
    notifyListeners();
  }

  @override
  void dismissSyncApproval(String id) {
    requests.remove(id);
    dismissed.add(id);
    notifyListeners();
  }

  @override
  Set<String> get forgettingDeviceIds => forgetting;

  @override
  Future<bool> forgetDevice(String id) async {
    forgotten.add(id);
    forgetting = {id};
    notifyListeners();
    final forgottenNow = await (pendingForget?.future ?? Future.value(true));
    forgetting = {};
    if (forgottenNow) {
      devices = devices.where((device) => device.id != id).toList();
    } else {
      error = '数据库暂不可用，请重试';
    }
    notifyListeners();
    return forgottenNow;
  }

  @override
  String? selectedDeviceId;
  @override
  String? get selectedCollectionKey => null;
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
  List<SharedFolder> get sharedFolders => const [];
  @override
  String? get downloadFolder => null;
  @override
  int get localMediaCount => 0;
  @override
  List<MediaCollection> get collections => [];
  @override
  List<MediaView> get media => [];
  @override
  Map<String, TransferView> get transfers => {};
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

Future<void> _pump(WidgetTester tester, _ApprovalModel model) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(TamayuraApp(model: model));
  await tester.pumpAndSettle();
}

Future<void> _openDevices(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('devices-tab')));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _inDevice(String id, String text) => find.descendant(
  of: find.byKey(Key('device-$id')),
  matching: find.textContaining(text),
);

void main() {
  testWidgets(
    'a newly discovered device prompts once and can start syncing',
    (tester) async {
      final model = _ApprovalModel(
        [_device('new', '客厅平板', approval: PeerSyncApproval.pending)],
        requests: ['new'],
      );
      await _pump(tester, model);
      expect(find.byKey(const Key('sync-approval-dialog')), findsOneWidget);
      expect(find.textContaining('客厅平板'), findsWidgets);
      await tester.tap(find.byKey(const Key('sync-approval-accept')));
      await tester.pumpAndSettle();
      expect(model.decisions, [('new', true)]);
      expect(find.byKey(const Key('sync-approval-dialog')), findsNothing);
      // Later model changes do not show the answered prompt again.
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-approval-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'declining keeps the device and the device page can enable it later',
    (tester) async {
      final model = _ApprovalModel(
        [_device('new', '客厅平板', approval: PeerSyncApproval.pending)],
        requests: ['new'],
      );
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('sync-approval-decline')));
      await tester.pumpAndSettle();
      expect(model.decisions, [('new', false)]);
      await _openDevices(tester);
      expect(_inDevice('new', '未开启相册同步'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('device-start-sync-new')));
      expect(model.decisions, [('new', false), ('new', true)]);
      expect(find.byKey(const Key('device-start-sync-new')), findsNothing);
      expect(_inDevice('new', '最后成功同步'), findsOneWidget);
      expect(find.byKey(const Key('sync-approval-dialog')), findsNothing);
    },
  );

  testWidgets(
    'closing the prompt leaves the device pending on the device page',
    (tester) async {
      final model = _ApprovalModel(
        [_device('new', '客厅平板', approval: PeerSyncApproval.pending)],
        requests: ['new'],
      );
      await _pump(tester, model);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(model.dismissed, ['new']);
      expect(model.decisions, isEmpty);
      await _openDevices(tester);
      expect(_inDevice('new', '新发现的设备'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('device-menu-new')));
      await _tapVisible(
        tester,
        find.byKey(const Key('device-enable-sync-new')),
      );
      expect(model.decisions, [('new', true)]);
    },
  );

  testWidgets('several discovered devices are offered one at a time', (
    tester,
  ) async {
    final model = _ApprovalModel(
      [
        _device('a', '书房电脑', approval: PeerSyncApproval.pending),
        _device('b', '旅行手机', approval: PeerSyncApproval.pending),
      ],
      requests: ['a', 'b'],
    );
    await _pump(tester, model);
    expect(find.byKey(const Key('sync-approval-dialog')), findsOneWidget);
    expect(find.textContaining('书房电脑'), findsWidgets);
    await tester.tap(find.byKey(const Key('sync-approval-accept')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-approval-dialog')), findsOneWidget);
    expect(find.textContaining('旅行手机'), findsWidgets);
    await tester.tap(find.byKey(const Key('sync-approval-decline')));
    await tester.pumpAndSettle();
    expect(model.decisions, [('a', true), ('b', false)]);
    expect(find.byKey(const Key('sync-approval-dialog')), findsNothing);
  });

  testWidgets(
    'forgetting a device asks for confirmation first',
    (tester) async {
      final model = _ApprovalModel([
        _device('a', '书房电脑'),
        _device('b', '旅行手机'),
      ]);
      await _pump(tester, model);
      await _openDevices(tester);
      await _tapVisible(tester, find.byKey(const Key('device-menu-a')));
      expect(find.byKey(const Key('device-enable-sync-a')), findsNothing);
      await _tapVisible(tester, find.byKey(const Key('device-forget-a')));
      expect(find.byKey(const Key('forget-device-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('forget-device-cancel')));
      await tester.pumpAndSettle();
      expect(model.forgotten, isEmpty);

      final pending = model.pendingForget = Completer<bool>();
      await _tapVisible(tester, find.byKey(const Key('device-menu-a')));
      await _tapVisible(tester, find.byKey(const Key('device-forget-a')));
      await tester.tap(find.byKey(const Key('forget-device-confirm')));
      await tester.pump();
      expect(model.forgotten, ['a']);
      final menu = tester.widget<PopupMenuButton<Object?>>(
        find.byKey(const Key('device-menu-a')),
      );
      expect(menu.enabled, isFalse, reason: 'A running forget blocks repeats');
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-a')), findsNothing);
      expect(find.byKey(const Key('device-b')), findsOneWidget);
      expect(find.textContaining('已忘记「书房电脑」'), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('a failed forget keeps the device and shows the error', (
    tester,
  ) async {
    final model = _ApprovalModel([_device('a', '书房电脑')])
      ..pendingForget = (Completer<bool>()..complete(false));
    await _pump(tester, model);
    await _openDevices(tester);
    await _tapVisible(tester, find.byKey(const Key('device-menu-a')));
    await _tapVisible(tester, find.byKey(const Key('device-forget-a')));
    await tester.tap(find.byKey(const Key('forget-device-confirm')));
    await tester.pumpAndSettle();
    expect(model.forgotten, ['a']);
    expect(find.byKey(const Key('device-a')), findsOneWidget);
    expect(find.text('数据库暂不可用，请重试'), findsWidgets);
  });
}
