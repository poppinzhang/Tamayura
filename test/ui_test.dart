import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

class _FakeModel extends TamayuraModel {
  @override
  bool albumDetailedMode = false;
  @override
  ThemeMode themeMode = ThemeMode.system;
  @override
  bool themeModeSaving = false;
  final List<ThemeMode> themeModeRequests = [];
  Completer<void>? themeSave;
  @override
  int autoSyncIntervalMinutes = 10;
  @override
  bool autoSyncIntervalSaving = false;
  final List<int> autoSyncIntervalRequests = [];
  Completer<void>? autoSyncIntervalSave;
  bool failAutoSyncInterval = false;
  bool reportAutoSyncIntervalError = false;
  @override
  bool backgroundSharingEnabled = false;
  @override
  bool backgroundSharingRunning = false;
  @override
  bool backgroundSharingStarting = false;
  @override
  String? backgroundSharingError;
  @override
  bool backgroundSharingSaving = false;
  @override
  bool batteryOptimizationExempt = true;
  final List<bool> backgroundSharingRequests = [];
  Completer<void>? backgroundSharingSave;
  bool failBackgroundSharing = false;
  int batterySettingsCalls = 0;
  @override
  bool loading = false;
  @override
  bool busy = false;
  @override
  String? error;
  @override
  String deviceName = '我的手机';
  @override
  List<String> addresses = ['192.168.1.10'];
  @override
  int port = 50728;
  @override
  List<SharedFolder> sharedFolders = [];
  @override
  String? downloadFolder;
  @override
  int localMediaCount = 0;
  @override
  List<DeviceView> devices = [];
  @override
  List<SyncProgress> syncProgress = [];
  @override
  String? selectedDeviceId;
  @override
  String? selectedCollectionKey;
  final List<MediaView> items = [];
  @override
  List<MediaCollection> get collections {
    final groups = <String, List<MediaView>>{};
    for (final item in items) {
      if (selectedDeviceId != null && item.deviceId != selectedDeviceId) {
        continue;
      }
      groups
          .putIfAbsent('${item.deviceId}/${item.sharedFolderId}', () => [])
          .add(item);
    }
    return groups.values
        .map(
          (items) => MediaCollection(
            deviceId: items.first.deviceId,
            sharedFolderId: items.first.sharedFolderId,
            sharedFolderName: items.first.sharedFolderName,
            itemCount: items.length,
            thumbnail: items.first.thumbnail,
          ),
        )
        .toList();
  }

  @override
  List<MediaView> get media => items
      .where(
        (item) =>
            (selectedDeviceId == null || item.deviceId == selectedDeviceId) &&
            (selectedCollectionKey == null ||
                '${item.deviceId}/${item.sharedFolderId}' ==
                    selectedCollectionKey),
      )
      .toList();
  @override
  Map<String, TransferView> transfers = {};
  @override
  bool hasMoreMedia = false;
  @override
  bool loadingMoreMedia = false;

  int initializeCalls = 0;
  int refreshCalls = 0;
  final List<String> syncRetryRequests = [];
  int shareFolderCalls = 0;
  int downloadFolderCalls = 0;
  final List<String> removedFolderIds = [];
  int downloadCalls = 0;
  int shareCalls = 0;
  int openCalls = 0;
  int previewCalls = 0;
  int cancelCalls = 0;
  int loadMoreCalls = 0;
  bool failLoadMore = false;
  bool failPreview = false;
  Uint8List? previewBytes;
  String? connectedAddress;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    themeModeRequests.add(mode);
    themeModeSaving = true;
    notifyListeners();
    try {
      await themeSave?.future;
      themeMode = mode;
    } finally {
      themeModeSaving = false;
      notifyListeners();
    }
  }

  @override
  Future<void> setAutoSyncIntervalMinutes(int minutes) async {
    autoSyncIntervalRequests.add(minutes);
    autoSyncIntervalSaving = true;
    notifyListeners();
    try {
      await autoSyncIntervalSave?.future;
      if (failAutoSyncInterval) throw StateError('Could not save interval');
      if (reportAutoSyncIntervalError) {
        error = '同步间隔未能保存，请重试。';
        return;
      }
      autoSyncIntervalMinutes = minutes;
    } finally {
      autoSyncIntervalSaving = false;
      notifyListeners();
    }
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
    notifyListeners();
  }

  @override
  Future<void> retrySync(String peerId) async {
    syncRetryRequests.add(peerId);
    await refresh();
  }

  @override
  Future<void> setBackgroundSharing(bool enabled) async {
    backgroundSharingRequests.add(enabled);
    backgroundSharingSaving = true;
    notifyListeners();
    try {
      await backgroundSharingSave?.future;
      if (failBackgroundSharing) {
        error = '无法开启后台共享，请重试。';
        return;
      }
      backgroundSharingEnabled = enabled;
      backgroundSharingRunning = enabled;
      backgroundSharingStarting = false;
      backgroundSharingError = null;
    } finally {
      backgroundSharingSaving = false;
      notifyListeners();
    }
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {
    batterySettingsCalls++;
  }

  @override
  Future<void> chooseSharedFolder() async {
    shareFolderCalls++;
    sharedFolders.add(
      SharedFolder(
        id: 'shared-$shareFolderCalls',
        uri: 'DCIM/Camera$shareFolderCalls',
        name: 'Camera$shareFolderCalls',
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> removeSharedFolder(String id) async {
    removedFolderIds.add(id);
    sharedFolders.removeWhere((folder) => folder.id == id);
    notifyListeners();
  }

  @override
  Future<void> chooseDownloadFolder() async {
    downloadFolderCalls++;
    downloadFolder = 'Pictures/Tamayura';
    notifyListeners();
  }

  @override
  Future<void> connect(String address) async {
    connectedAddress = address;
    notifyListeners();
  }

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
  Future<void> download(MediaView item) async {
    downloadCalls++;
    transfers[item.key] = TransferView(
      progress: .4,
      item: item,
      totalBytes: item.size,
      receivedBytes: (item.size * .4).round(),
    );
    notifyListeners();
  }

  @override
  Future<void> share(MediaView item) async {
    shareCalls++;
  }

  @override
  Future<void> open(MediaView item) async {
    openCalls++;
  }

  @override
  Future<Uint8List?> loadPreview(
    MediaView item, {
    int maxDimension = 2560,
    bool Function()? isCurrent,
  }) async {
    previewCalls++;
    if (failPreview) throw StateError('Cannot read local file');
    return previewBytes;
  }

  @override
  Future<void> cancelDownload(String key) async {
    cancelCalls++;
    final task = transfers[key]!;
    transfers[key] = TransferView(
      progress: task.progress,
      item: task.item,
      status: TransferStatus.cancelled,
    );
    notifyListeners();
  }

  @override
  Future<void> loadMoreMedia() async {
    loadMoreCalls++;
    if (failLoadMore) throw StateError('Database temporarily unavailable');
    items.add(_photo(id: 'more-photo'));
    hasMoreMedia = false;
    notifyListeners();
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

MediaView _photo({
  String id = 'photo-1',
  bool video = false,
  String deviceId = 'phone-b',
  String sharedFolderId = 'camera',
  String sharedFolderName = 'Camera',
  String relativePath = 'IMG_20261008.jpg',
}) => MediaView(
  id: id,
  deviceId: deviceId,
  sharedFolderId: sharedFolderId,
  sharedFolderName: sharedFolderName,
  relativePath: relativePath,
  name: 'IMG_20261008.jpg',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  size: 3 * 1024 * 1024,
  modified: DateTime(2026, 10, 8),
  thumbnail: Uint8List(0),
);

_FakeModel _withPhoto({
  bool online = true,
  String deviceId = 'phone-b',
  String deviceName = '另一部手机',
}) => _FakeModel()
  ..sharedFolders = [
    const SharedFolder(id: 'camera', uri: 'DCIM/Camera', name: 'Camera'),
  ]
  ..downloadFolder = 'Pictures/Tamayura'
  ..devices = [
    DeviceView(
      id: deviceId,
      name: deviceName,
      address: '192.168.1.11:50728',
      online: online,
    ),
  ]
  ..items.add(_photo(deviceId: deviceId));

void _expectDeviceIdHidden(String id) {
  final rawId = id.replaceFirst('android-', '');
  expect(find.textContaining(rawId), findsNothing);
  expect(find.bySemanticsLabel(RegExp(RegExp.escape(rawId))), findsNothing);
}

Future<void> _ensureVisible(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
}

Future<void> _scrollAlbumTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('album-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollSettingsTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollDevicesTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('devices-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _FakeModel model, {
  bool openCollection = true,
}) async {
  await tester.pumpWidget(TamayuraApp(model: model));
  await tester.pumpAndSettle();
  if (openCollection && model.collections.isNotEmpty) {
    final card = find.byKey(Key('collection-${model.collections.first.key}'));
    await _ensureVisible(tester, card);
    await tester.tap(card);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'album and devices only refresh from explicit actions on every platform',
    (tester) async {
      final model = _FakeModel();
      await _pump(tester, model);
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(find.textContaining('下拉'), findsNothing);
      await tester.drag(
        find.byKey(const PageStorageKey('album-scroll')),
        const Offset(0, 350),
      );
      await tester.pumpAndSettle();
      expect(model.refreshCalls, 0);
      await tester.tap(find.byKey(const Key('refresh')));
      await tester.pumpAndSettle();
      expect(model.refreshCalls, 1);
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      expect(find.byType(RefreshIndicator), findsNothing);
      await tester.drag(
        find.byKey(const PageStorageKey('devices-scroll')),
        const Offset(0, 350),
      );
      await tester.pumpAndSettle();
      expect(model.refreshCalls, 1);
      await tester.tap(find.byKey(const Key('refresh')));
      await tester.pumpAndSettle();
      expect(model.refreshCalls, 2);
      model.busy = true;
      model.notifyListeners();
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byKey(const Key('refresh'))).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets(
    'auto sync interval edits and cancels on mobile and desktop platforms',
    (tester) async {
      final model = _FakeModel();
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final setting = find.byKey(const Key('auto-sync-interval'));
      await _scrollSettingsTo(tester, setting);
      expect(find.textContaining('超过 10 分钟'), findsOneWidget);
      for (final minutes in [1, 525600, 24]) {
        await tester.tap(setting);
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('auto-sync-interval-input'));
        expect(find.text('间隔分钟数'), findsOneWidget);
        expect(find.text('1–525600 分钟，默认 10 分钟'), findsOneWidget);
        expect(
          tester.widget<TextField>(input).controller!.text,
          '${model.autoSyncIntervalMinutes}',
        );
        await tester.enterText(input, '$minutes');
        await tester.tap(find.byKey(const Key('auto-sync-interval-save')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(model.autoSyncIntervalMinutes, minutes);
        expect(find.textContaining('超过 $minutes 分钟'), findsOneWidget);
      }
      await tester.tap(setting);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('auto-sync-interval-input')),
        '48',
      );
      await tester.tap(find.byKey(const Key('auto-sync-interval-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.autoSyncIntervalRequests, [1, 525600, 24]);
      expect(model.autoSyncIntervalMinutes, 24);
      expect(model.refreshCalls, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('auto sync interval validates whole minutes before saving', (
    tester,
  ) async {
    final model = _FakeModel();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('auto-sync-interval'));
    await _scrollSettingsTo(tester, setting);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    for (final invalid in [
      '',
      '0',
      '-1',
      '1.5',
      '525601',
      'abc',
      '1e3',
      '+1',
    ]) {
      await tester.enterText(
        find.byKey(const Key('auto-sync-interval-input')),
        invalid,
      );
      await tester.tap(find.byKey(const Key('auto-sync-interval-save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–525600 之间的整数分钟'), findsOneWidget);
      expect(model.autoSyncIntervalRequests, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
    }
    expect(model.autoSyncIntervalMinutes, 10);
  });

  testWidgets('auto sync interval disables edits and dismissal while saving', (
    tester,
  ) async {
    final model = _FakeModel()..autoSyncIntervalSave = Completer<void>();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('auto-sync-interval'));
    await _scrollSettingsTo(tester, setting);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('auto-sync-interval-input'));
    await tester.enterText(input, '24');
    final save = find.byKey(const Key('auto-sync-interval-save'));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).enabled, isFalse);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('auto-sync-interval-cancel')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<ListTile>(setting).onTap, isNull);
    await tester.tap(save);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(model.autoSyncIntervalRequests, [24]);
    model.autoSyncIntervalSave!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.autoSyncIntervalMinutes, 24);
    expect(tester.widget<ListTile>(setting).onTap, isNotNull);
  });

  for (final throwFailure in [true, false]) {
    testWidgets('auto sync interval preserves failed edits ($throwFailure)', (
      tester,
    ) async {
      final model = _FakeModel()
        ..failAutoSyncInterval = throwFailure
        ..reportAutoSyncIntervalError = !throwFailure;
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final setting = find.byKey(const Key('auto-sync-interval'));
      await _scrollSettingsTo(tester, setting);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('auto-sync-interval-input'));
      await tester.enterText(input, '24');
      await tester.tap(find.byKey(const Key('auto-sync-interval-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('同步间隔未能保存，请重试。'), findsWidgets);
      expect(tester.widget<TextField>(input).controller!.text, '24');
      expect(tester.widget<TextField>(input).enabled, isTrue);
      expect(model.autoSyncIntervalMinutes, 10);
      if (throwFailure) {
        expect(find.text('操作未能完成，请检查网络与目录权限后重试。'), findsOneWidget);
      }
      model.failAutoSyncInterval = false;
      model.reportAutoSyncIntervalError = false;
      await tester.tap(find.byKey(const Key('auto-sync-interval-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.autoSyncIntervalMinutes, 24);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('auto sync settings fit a small phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _FakeModel();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('auto-sync-interval'));
    await _scrollSettingsTo(tester, setting);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    final input = find.byKey(const Key('auto-sync-interval-input'));
    await _ensureVisible(tester, input);
    await tester.enterText(input, '36');
    await tester.tap(find.byKey(const Key('auto-sync-interval-save')));
    await tester.pumpAndSettle();
    expect(model.autoSyncIntervalMinutes, 36);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first sync waits for photos and shows arrivals while busy', (
    tester,
  ) async {
    final model = _withPhoto()
      ..busy = true
      ..selectedCollectionKey = 'phone-b/camera'
      ..syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '另一部手机',
          phase: SyncPhase.connecting,
        ),
      ];
    model.items.clear();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.pump();
    expect(find.text('正在接收相册'), findsOneWidget);
    expect(find.text('这个合集还没有照片'), findsNothing);
    expect(find.text('连接一台设备'), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('sync-indicator-phone-b')),
          )
          .value,
      isNull,
    );

    model.items.add(_photo());
    model.syncProgress = [
      const SyncProgress(
        peerId: 'phone-b',
        peerName: '另一部手机',
        phase: SyncPhase.receiving,
        totalCount: 3000,
        receivedCount: 200,
        readyCount: 1,
      ),
    ];
    model.notifyListeners();
    await tester.pump();
    expect(find.text('正在接收相册'), findsNothing);
    expect(find.text('已就绪 1 / 3000 项，可边同步边浏览。'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('sync-indicator-phone-b')),
          )
          .value,
      closeTo(1 / 3000, 0.000001),
    );
    final photo = find.byKey(const Key('media-phone-b/photo-1'));
    await tester.scrollUntilVisible(
      photo,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('album-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(photo, findsOneWidget);
    await tester.pump();
    await tester.tap(photo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(model.downloadCalls, 1);
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new collections and incremental photos appear during sync', (
    tester,
  ) async {
    final model = _withPhoto()
      ..syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '另一部手机',
          phase: SyncPhase.receiving,
          totalCount: 3,
          receivedCount: 3,
          readyCount: 1,
        ),
      ];
    await _pump(tester, model, openCollection: false);
    model.items.add(
      _photo(id: 'holiday', sharedFolderId: 'holiday', sharedFolderName: '假日'),
    );
    model.notifyListeners();
    await tester.pumpAndSettle();
    final newCollection = find.byKey(const Key('collection-phone-b/holiday'));
    await _ensureVisible(tester, newCollection);
    await tester.tap(newCollection);
    await tester.pumpAndSettle();
    await _scrollAlbumTo(
      tester,
      find.byKey(const Key('media-phone-b/holiday')),
    );
    expect(find.byKey(const Key('media-phone-b/holiday')), findsOneWidget);
    expect(find.byKey(const Key('sync-progress-phone-b')), findsOneWidget);

    model.items.add(
      _photo(
        id: 'holiday-2',
        sharedFolderId: 'holiday',
        sharedFolderName: '假日',
      ),
    );
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-phone-b/holiday')), findsOneWidget);
    expect(find.byKey(const Key('media-phone-b/holiday-2')), findsOneWidget);
    expect(model.selectedCollectionKey, 'phone-b/holiday');
  });

  testWidgets('sync progress follows device and collection filters', (
    tester,
  ) async {
    final model = _withPhoto()
      ..syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '另一部手机',
          phase: SyncPhase.receiving,
          totalCount: 10,
          readyCount: 2,
        ),
        const SyncProgress(
          peerId: 'phone-c',
          peerName: '第三部手机',
          phase: SyncPhase.receiving,
          totalCount: 20,
          readyCount: 3,
        ),
      ];
    model.devices.add(
      const DeviceView(
        id: 'phone-c',
        name: '第三部手机',
        address: '192.168.1.12:50728',
        online: true,
      ),
    );
    model.items.add(_photo(deviceId: 'phone-c'));
    await _pump(tester, model, openCollection: false);
    expect(find.byKey(const Key('sync-progress-phone-b')), findsOneWidget);
    expect(find.byKey(const Key('sync-progress-phone-c')), findsOneWidget);
    final collection = find.byKey(const Key('collection-phone-b/camera'));
    await _scrollAlbumTo(tester, collection);
    await tester.tap(collection);
    await tester.pumpAndSettle();
    expect(model.selectedDeviceId, isNull);
    expect(find.byKey(const Key('sync-progress-phone-b')), findsOneWidget);
    expect(find.byKey(const Key('sync-progress-phone-c')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '第三部手机'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-progress-phone-b')), findsNothing);
    expect(find.byKey(const Key('sync-progress-phone-c')), findsOneWidget);
    expect(model.selectedCollectionKey, isNull);
  });

  testWidgets(
    'failed sync keeps cached photos and offers retry without success',
    (tester) async {
      final model = _withPhoto()
        ..syncProgress = [
          const SyncProgress(
            peerId: 'phone-b',
            peerName: '另一部手机',
            phase: SyncPhase.receiving,
            totalCount: 10,
            receivedCount: 10,
            readyCount: 10,
          ),
        ];
      await _pump(tester, model);
      model.syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '另一部手机',
          phase: SyncPhase.failed,
          totalCount: 10,
          receivedCount: 10,
          readyCount: 10,
          error: '连接已中断',
        ),
      ];
      model.notifyListeners();
      await tester.pump();
      expect(find.text('本次同步未完成'), findsOneWidget);
      expect(find.text('已保留 10 项，恢复连接后可继续同步。'), findsOneWidget);
      expect(find.text('继续同步'), findsOneWidget);
      expect(find.text('相册同步完成'), findsNothing);
      expect(find.byKey(const Key('sync-indicator-phone-b')), findsNothing);
      await _scrollAlbumTo(
        tester,
        find.byKey(const Key('media-phone-b/photo-1')),
      );
      expect(find.byKey(const Key('media-phone-b/photo-1')), findsOneWidget);
      final retry = find.byKey(const Key('retry-sync-phone-b'));
      await _ensureVisible(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(model.refreshCalls, 1);
      expect(model.syncRetryRequests, ['phone-b']);

      model.items.clear();
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('同步尚未完成'), findsOneWidget);
      expect(find.text('这个合集还没有照片'), findsNothing);
    },
  );

  testWidgets('finishing and empty completion have distinct sync states', (
    tester,
  ) async {
    final model = _withPhoto()
      ..syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '另一部手机',
          phase: SyncPhase.committing,
          totalCount: 0,
        ),
      ];
    model.items.clear();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.pump();
    expect(find.text('正在完成同步'), findsOneWidget);
    expect(find.text('相册同步完成'), findsNothing);
    expect(find.text('正在接收相册'), findsOneWidget);
    model.syncProgress = [
      const SyncProgress(
        peerId: 'phone-b',
        peerName: '另一部手机',
        phase: SyncPhase.completed,
        totalCount: 0,
      ),
    ];
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('相册同步完成'), findsOneWidget);
    expect(find.text('已就绪 0 项。'), findsOneWidget);
    expect(find.text('这里还没有合集'), findsOneWidget);
    expect(find.byKey(const Key('sync-indicator-phone-b')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync card supports narrow screens and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _withPhoto()
      ..syncProgress = [
        const SyncProgress(
          peerId: 'phone-b',
          peerName: '这是一台保存了许多旅行照片的手机',
          phase: SyncPhase.receiving,
          totalCount: 5000,
          readyCount: 2345,
        ),
      ];
    await _pump(tester, model, openCollection: false);
    final indicator = find.byKey(const Key('sync-indicator-phone-b'));
    await _ensureVisible(tester, indicator);
    expect(find.text('已就绪 2345 / 5000 项，可边同步边浏览。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    model.syncProgress = [
      const SyncProgress(
        peerId: 'phone-b',
        peerName: '这是一台保存了许多旅行照片的手机',
        phase: SyncPhase.failed,
        totalCount: 5000,
        readyCount: 2345,
      ),
    ];
    model.notifyListeners();
    await tester.pumpAndSettle();
    final retry = find.byKey(const Key('retry-sync-phone-b'));
    await _ensureVisible(tester, retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(model.refreshCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background sharing toggles and reports actual running state', (
    tester,
  ) async {
    final model = _FakeModel();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('background-sharing-switch'));
    await _scrollSettingsTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('后台共享已关闭。'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.backgroundSharingRequests, [true]);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsOneWidget);
    model.backgroundSharingRunning = false;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('后台共享尚未运行。'), findsOneWidget);
    expect(find.byKey(const Key('background-sharing-retry')), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.backgroundSharingRequests, [true, false]);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('后台共享已关闭。'), findsOneWidget);
    expect(find.byKey(const Key('background-sharing-retry')), findsNothing);
  });

  testWidgets(
    'background sharing startup waits for readiness and can be cancelled',
    (tester) async {
      final model = _FakeModel()
        ..backgroundSharingEnabled = true
        ..backgroundSharingStarting = true;
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('background-sharing-switch'));
      await _scrollSettingsTo(tester, toggle);
      expect(find.text('正在启动后台共享…'), findsOneWidget);
      expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsNothing);
      expect(find.byKey(const Key('background-sharing-retry')), findsNothing);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
      model.backgroundSharingStarting = false;
      model.backgroundSharingRunning = true;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('正在启动后台共享…'), findsNothing);
      expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsOneWidget);
      model.backgroundSharingStarting = true;
      model.backgroundSharingRunning = false;
      model.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(model.backgroundSharingRequests, [false]);
      expect(find.text('后台共享已关闭。'), findsOneWidget);
    },
  );

  testWidgets(
    'failed background rebuild retains the error and retries directly',
    (tester) async {
      final model = _FakeModel()
        ..backgroundSharingEnabled = true
        ..backgroundSharingError = '无法监听共享端口，请稍后重试。';
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final retry = find.byKey(const Key('background-sharing-retry'));
      await _scrollSettingsTo(tester, retry);
      expect(find.text('后台共享启动失败，请重试。'), findsOneWidget);
      expect(find.text('无法监听共享端口，请稍后重试。'), findsOneWidget);
      expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsNothing);
      final toggle = find.byKey(const Key('background-sharing-switch'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(model.backgroundSharingRequests, [true]);
      expect(find.byKey(const Key('background-sharing-error')), findsNothing);
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('settings-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await _scrollSettingsTo(tester, toggle);
      expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsOneWidget);
      expect(retry, findsNothing);
    },
  );

  testWidgets('background sharing startup can be cancelled while saving', (
    tester,
  ) async {
    final model = _FakeModel()
      ..backgroundSharingEnabled = true
      ..backgroundSharingStarting = true
      ..backgroundSharingSaving = true;
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('background-sharing-switch'));
    await _scrollSettingsTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    expect(find.byKey(const Key('background-sharing-retry')), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.backgroundSharingRequests, [false]);
    expect(find.text('后台共享已关闭。'), findsOneWidget);
  });

  testWidgets(
    'settings can cancel a background rebuild during initialization',
    (tester) async {
      final model = _FakeModel()
        ..loading = true
        ..backgroundSharingEnabled = true
        ..backgroundSharingStarting = true
        ..backgroundSharingSaving = true;
      await tester.pumpWidget(TamayuraApp(model: model));
      expect(find.text('正在打开你的随身相册…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final addFolder = find.byKey(const Key('add-shared-folder'));
      await _scrollSettingsTo(tester, addFolder);
      expect(tester.widget<FilledButton>(addFolder).onPressed, isNull);
      final toggle = find.byKey(const Key('background-sharing-switch'));
      await _scrollSettingsTo(tester, toggle);
      expect(find.text('正在启动后台共享…'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
      await tester.tap(toggle);
      await tester.pump();
      expect(model.backgroundSharingRequests, [false]);
      expect(model.backgroundSharingEnabled, isFalse);
      expect(find.text('正在打开你的随身相册…'), findsOneWidget);
      expect(toggle, findsNothing);
      model.loading = false;
      model.notifyListeners();
      await tester.pumpAndSettle();
      await _scrollSettingsTo(tester, toggle);
      expect(find.text('后台共享已关闭。'), findsOneWidget);
    },
  );

  testWidgets('background sharing disables while loading or saving', (
    tester,
  ) async {
    final model = _FakeModel()
      ..loading = true
      ..backgroundSharingSave = Completer<void>();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pump(const Duration(milliseconds: 300));
    final toggle = find.byKey(const Key('background-sharing-switch'));
    expect(toggle, findsNothing);
    expect(model.backgroundSharingRequests, isEmpty);
    model.loading = false;
    model.notifyListeners();
    await tester.pumpAndSettle();
    await _scrollSettingsTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('正在更新后台共享…'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.backgroundSharingRequests, [true]);
    model.backgroundSharingSave!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('failed background sharing remains off and displays the error', (
    tester,
  ) async {
    final model = _FakeModel()..failBackgroundSharing = true;
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('background-sharing-switch'));
    await _scrollSettingsTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('无法开启后台共享，请重试。'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    expect(find.text('后台共享正在运行，锁屏后仍可访问已选目录。'), findsNothing);
  });

  testWidgets(
    'background sharing offers battery settings only when restricted',
    (tester) async {
      final model = _FakeModel()
        ..backgroundSharingEnabled = true
        ..backgroundSharingRunning = true
        ..batteryOptimizationExempt = false;
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final battery = find.byKey(
        const Key('background-sharing-battery-settings'),
      );
      await _scrollSettingsTo(tester, battery);
      expect(find.textContaining('系统省电限制可能在休眠时中断共享'), findsOneWidget);
      await tester.tap(battery);
      await tester.pumpAndSettle();
      expect(model.batterySettingsCalls, 1);
      model.batteryOptimizationExempt = true;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(battery, findsNothing);
      model.batteryOptimizationExempt = false;
      model.backgroundSharingEnabled = false;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(battery, findsNothing);
      expect(find.textContaining('系统省电限制可能在休眠时中断共享'), findsNothing);
    },
  );

  testWidgets('background sharing fits small phones with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _FakeModel()
      ..backgroundSharingEnabled = true
      ..backgroundSharingRunning = true
      ..batteryOptimizationExempt = false;
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('background-sharing-switch'));
    await _scrollSettingsTo(tester, toggle);
    expect(tester.takeException(), isNull);
    final battery = find.byKey(
      const Key('background-sharing-battery-settings'),
    );
    await _scrollSettingsTo(tester, battery);
    expect(tester.takeException(), isNull);
    await tester.tap(battery);
    await tester.pumpAndSettle();
    expect(model.batterySettingsCalls, 1);
  });

  testWidgets('system theme updates live until a manual mode is selected', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final model = _FakeModel();
    await _pump(tester, model);
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
    expect(brightness(), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);

    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('theme-mode-selector'));
    await _ensureVisible(tester, selector);
    expect(tester.widget<SegmentedButton<ThemeMode>>(selector).selected, {
      ThemeMode.system,
    });
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(model.themeMode, ThemeMode.light);
    expect(brightness(), Brightness.light);
    expect(find.text('已固定为浅色外观。'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(model.themeMode, ThemeMode.dark);
    expect(brightness(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect(model.themeModeRequests, [
      ThemeMode.light,
      ThemeMode.dark,
      ThemeMode.system,
    ]);
    expect(model.initializeCalls, 0);
  });

  testWidgets('theme selection disables while saving and keeps album state', (
    tester,
  ) async {
    final model = _withPhoto()..themeSave = Completer<void>();
    await _pump(tester, model, openCollection: false);
    await tester.tap(find.widgetWithText(ChoiceChip, '另一部手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('collection-phone-b/camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('theme-mode-selector'));
    await _ensureVisible(tester, selector);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(find.text('正在保存主题…'), findsOneWidget);
    expect(
      tester.widget<SegmentedButton<ThemeMode>>(selector).onSelectionChanged,
      isNull,
    );
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(model.themeModeRequests, [ThemeMode.dark]);
    model.themeSave!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<ThemeMode>>(selector).selected, {
      ThemeMode.dark,
    });
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(model.selectedDeviceId, 'phone-b');
    expect(model.selectedCollectionKey, 'phone-b/camera');
    await tester.tap(find.byKey(const Key('album-tab')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('media-${model.items.single.key}')), findsOneWidget);
    expect(model.downloadCalls, 0);
    expect(model.initializeCalls, 0);
  });

  testWidgets('theme changes preserve open download routes and style dialogs', (
    tester,
  ) async {
    final model = _withPhoto();
    final photo = model.items.single;
    model.transfers[photo.key] = TransferView(
      progress: .4,
      item: photo,
      totalBytes: photo.size,
      receivedBytes: (photo.size * .4).round(),
    );
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('downloads-entry')));
    await tester.pumpAndSettle();
    await model.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    final downloads = find.byKey(const Key('downloads-page'));
    expect(downloads, findsOneWidget);
    expect(Theme.of(tester.element(downloads)).brightness, Brightness.dark);
    expect(find.byKey(Key('task-${photo.key}')), findsOneWidget);
    expect(
      model.transfers[photo.key]!.receivedBytes,
      (photo.size * .4).round(),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('devices-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-manual')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);
    await model.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(Theme.of(tester.element(dialog)).brightness, Brightness.light);
    expect(find.byKey(const Key('ip-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme options fit small phones with large system text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _FakeModel();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('theme-mode-selector'));
    await _ensureVisible(tester, selector);
    expect(
      tester.widget<SegmentedButton<ThemeMode>>(selector).direction,
      Axis.vertical,
    );
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(model.themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(model.themeMode, ThemeMode.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone theme labels remain visible without truncation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, _FakeModel());
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('theme-mode-selector'));
    await _ensureVisible(tester, selector);
    expect(
      tester.widget<SegmentedButton<ThemeMode>>(selector).direction,
      Axis.horizontal,
    );
    for (final label in ['跟随系统', '浅色', '深色']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.didExceedMaxLines, isFalse, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty album guides folder selection without starting services', (
    tester,
  ) async {
    final model = _FakeModel();
    await _pump(tester, model);
    expect(find.text('让照片相遇'), findsOneWidget);
    expect(find.byKey(const Key('setup-share')), findsOneWidget);
    expect(find.byKey(const Key('setup-download')), findsOneWidget);
    await tester.tap(find.byKey(const Key('setup-share')));
    await tester.pumpAndSettle();
    expect(model.shareFolderCalls, 1);
    expect(find.byKey(const Key('setup-share')), findsNothing);
    await tester.tap(find.byKey(const Key('setup-download')));
    await tester.pumpAndSettle();
    expect(model.downloadFolderCalls, 1);
    expect(find.text('先安顿好你的相册'), findsNothing);
    expect(model.initializeCalls, 0);
  });

  testWidgets('settings add and remove multiple shared folders', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model, openCollection: false);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    await _scrollSettingsTo(
      tester,
      find.byKey(const Key('shared-folder-camera')),
    );
    expect(find.byKey(const Key('shared-folder-camera')), findsOneWidget);
    expect(
      find.text('可添加多个文件夹，自动包含所有子目录。已添加的目录及其父目录、子目录不能重复添加。'),
      findsOneWidget,
    );
    final add = find.byKey(const Key('add-shared-folder'));
    await _ensureVisible(tester, add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(model.sharedFolders, hasLength(2));
    expect(find.byKey(const Key('shared-folder-camera')), findsOneWidget);
    expect(find.byKey(const Key('shared-folder-shared-1')), findsOneWidget);
    final remove = find.byKey(const Key('remove-shared-folder-camera'));
    await _ensureVisible(tester, remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(model.removedFolderIds, ['camera']);
    expect(model.sharedFolders.single.id, 'shared-1');
    expect(find.byKey(const Key('shared-folder-camera')), findsNothing);
    expect(find.byKey(const Key('add-shared-folder')), findsOneWidget);
  });

  testWidgets('album starts with collections and opens all nested photos', (
    tester,
  ) async {
    final model = _withPhoto();
    model.items.add(_photo(id: 'nested', relativePath: '2026/October/IMG.jpg'));
    await _pump(tester, model, openCollection: false);
    expect(find.byKey(const Key('collection-phone-b/camera')), findsOneWidget);
    expect(find.text('2 个瞬间'), findsOneWidget);
    expect(find.byKey(Key('media-${model.items.first.key}')), findsNothing);
    expect(model.downloadCalls, 0);
    await tester.tap(find.byKey(const Key('collection-phone-b/camera')));
    await tester.pumpAndSettle();
    expect(model.selectedCollectionKey, 'phone-b/camera');
    expect(find.byKey(Key('media-${model.items.first.key}')), findsOneWidget);
    expect(find.byKey(Key('media-${model.items.last.key}')), findsOneWidget);
    expect(model.downloadCalls, 0);
    await tester.tap(find.byKey(const Key('back-to-collections')));
    await tester.pumpAndSettle();
    expect(model.selectedCollectionKey, isNull);
    expect(find.byKey(const Key('collection-phone-b/camera')), findsOneWidget);
    expect(find.byKey(Key('media-${model.items.first.key}')), findsNothing);
  });

  testWidgets('system back returns from photos to the collection list', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    expect(model.selectedCollectionKey, 'phone-b/camera');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(model.selectedCollectionKey, isNull);
    expect(find.byKey(const Key('collection-phone-b/camera')), findsOneWidget);
  });

  testWidgets('same named collections remain separate by folder and device', (
    tester,
  ) async {
    final model = _withPhoto();
    model.devices.add(
      const DeviceView(
        id: 'phone-c',
        name: '第三部手机',
        address: '192.168.1.12:50728',
        online: true,
      ),
    );
    model.items.addAll([
      _photo(id: 'other-root', sharedFolderId: 'other-camera'),
      _photo(id: 'other-device', deviceId: 'phone-c'),
    ]);
    await _pump(tester, model, openCollection: false);
    expect(find.text('3 个合集'), findsOneWidget);
    for (final key in [
      'phone-b/camera',
      'phone-b/other-camera',
      'phone-c/camera',
    ]) {
      expect(find.byKey(Key('collection-$key')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('collection-phone-b/other-camera')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-phone-b/other-root')), findsOneWidget);
    expect(find.byKey(const Key('media-phone-b/photo-1')), findsNothing);
    expect(find.byKey(const Key('media-phone-c/other-device')), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '第三部手机'));
    await tester.pumpAndSettle();
    expect(model.selectedCollectionKey, isNull);
    expect(find.byKey(const Key('collection-phone-c/camera')), findsOneWidget);
    expect(find.byKey(const Key('collection-phone-b/camera')), findsNothing);
    expect(find.byKey(const Key('back-to-collections')), findsNothing);
  });

  testWidgets('collection list does not load media pages while scrolling', (
    tester,
  ) async {
    final model = _withPhoto()..hasMoreMedia = true;
    await _pump(tester, model, openCollection: false);
    await tester.drag(
      find.byKey(const PageStorageKey('album-scroll')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(model.loadMoreCalls, 0);
    expect(find.byKey(const Key('load-more-media')), findsNothing);
  });

  testWidgets('tap downloads, displays progress, then shares a saved file', (
    tester,
  ) async {
    final model = _withPhoto();
    final photo = model.items.single;
    await _pump(tester, model);
    expect(find.text(photo.name), findsNothing);
    await tester.tap(find.byKey(Key('media-${photo.key}')));
    await tester.pumpAndSettle();
    expect(find.text(photo.name), findsOneWidget);
    expect(model.downloadCalls, 1);
    expect(find.text('40%'), findsOneWidget);
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    await tester.tap(find.byKey(const Key('close-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('media-${photo.key}')));
    await tester.pumpAndSettle();
    expect(
      model.downloadCalls,
      1,
      reason: 'Running downloads must not be started twice',
    );
    model.transfers[photo.key] = const TransferView(
      progress: 1,
      savedUri: 'content://download/photo',
    );
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('已保存到本机'), findsOneWidget);
    await tester.tap(find.byKey(Key('share-${photo.key}')));
    expect(model.shareCalls, 1);
  });

  testWidgets(
    'detailed mode keeps offline information and a failed download retry',
    (tester) async {
      final model = _withPhoto(online: false)..albumDetailedMode = true;
      final photo = model.items.single;
      model.transfers[photo.key] = const TransferView(
        progress: 0,
        error: '设备暂时离线',
      );
      await _pump(tester, model);
      expect(find.text('设备离线'), findsOneWidget);
      expect(find.text(photo.name), findsOneWidget);
      await _ensureVisible(tester, find.byKey(Key('retry-${photo.key}')));
      await tester.tap(find.byKey(Key('retry-${photo.key}')));
      await tester.pump();
      expect(model.downloadCalls, 1);
    },
  );

  testWidgets('devices support manual connection and local connection QR', (
    tester,
  ) async {
    final model = _FakeModel();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('devices-tab')));
    await tester.pumpAndSettle();
    expect(find.text('附近的伙伴'), findsOneWidget);
    await tester.tap(find.byKey(const Key('connect-manual')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-connect')));
    await tester.pump();
    expect(find.text('请输入对方的 IP 地址'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('ip-input')),
      '192.168.1.11:50728',
    );
    await tester.tap(find.byKey(const Key('confirm-connect')));
    await tester.pumpAndSettle();
    expect(model.connectedAddress, '192.168.1.11:50728');
    await tester.tap(find.text('展示连接二维码'));
    await tester.pumpAndSettle();
    expect(find.text('另一台设备打开玉响扫一扫'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(model.initializeCalls, 0);
  });

  testWidgets(
    'devices show their last successful sync independently of connection and attempts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = _withPhoto()
        ..devices = [
          DeviceView(
            id: 'phone-b',
            name: '在线伙伴',
            address: '192.0.2.11:50728',
            online: true,
            lastSync: DateTime(2026, 1, 9, 12),
            lastSuccessfulSync: DateTime(2026, 1, 2, 3, 4, 5).toUtc(),
          ),
          DeviceView(
            id: 'offline',
            name: '离线伙伴',
            address: '192.0.2.12:50728',
            online: false,
            lastSync: DateTime(2026, 1, 9, 12),
            lastSuccessfulSync: DateTime(2025, 12, 31, 23, 59, 58).toUtc(),
          ),
          DeviceView(
            id: 'never-synced',
            name: '新伙伴',
            address: '192.0.2.13:50728',
            online: true,
            lastSync: DateTime(2026, 1, 9, 12),
          ),
        ];
      model.items.add(_photo(deviceId: 'offline'));
      await _pump(tester, model, openCollection: false);
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      for (final (id, details) in [
        ('phone-b', '在线\n192.0.2.11:50728\n最后成功同步：2026-01-02 03:04:05'),
        ('offline', '离线 · 可浏览缓存\n192.0.2.12:50728\n最后成功同步：2025-12-31 23:59:58'),
        ('never-synced', '在线\n192.0.2.13:50728\n最后成功同步：尚未成功同步'),
      ]) {
        final tile = find.byKey(Key('device-$id'));
        await _scrollDevicesTo(tester, tile);
        expect(
          find.descendant(of: tile, matching: find.text(details)),
          findsOneWidget,
        );
      }
      expect(find.textContaining('2026-01-09'), findsNothing);
      final offline = find.byKey(const Key('device-offline'));
      await _scrollDevicesTo(tester, offline);
      await tester.tap(offline);
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, 'offline');
      expect(
        find.byKey(const Key('collection-offline/camera')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('collection-phone-b/camera')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('device last successful sync updates when the model changes', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model, openCollection: false);
    await tester.tap(find.byKey(const Key('devices-tab')));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('device-phone-b'));
    await _scrollDevicesTo(tester, tile);
    expect(find.textContaining('最后成功同步：尚未成功同步'), findsOneWidget);

    for (final online in [true, false]) {
      model.devices = [
        DeviceView(
          id: 'phone-b',
          name: '另一部手机',
          address: '192.0.2.11:50728',
          online: online,
          lastSync: DateTime(2026, 1, online ? 2 : 3, 12),
          lastSuccessfulSync: DateTime(2026, 1, 2, 3, 4, 5).toUtc(),
        ),
      ];
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('最后成功同步：尚未成功同步'), findsNothing);
      expect(find.textContaining('最后成功同步：2026-01-02 03:04:05'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'device last successful sync wraps with large text in narrow layouts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final model = _withPhoto()
        ..devices = [
          DeviceView(
            id: 'phone-b',
            name: '客厅的平板电脑',
            address: '192.0.2.11:50728',
            online: false,
            lastSuccessfulSync: DateTime(2026, 1, 2, 3, 4, 5).toUtc(),
          ),
        ];
      await _pump(tester, model, openCollection: false);
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      final tile = find.byKey(const Key('device-phone-b'));
      await _scrollDevicesTo(tester, tile);
      final details = find.textContaining('最后成功同步：2026-01-02 03:04:05');
      expect(details, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(details);
      expect(paragraph.didExceedMaxLines, isFalse);
      final tileRect = tester.getRect(tile);
      final detailsRect = tester.getRect(details);
      expect(tileRect.contains(detailsRect.topLeft), isTrue);
      expect(tileRect.contains(detailsRect.bottomRight), isTrue);
      expect(tester.takeException(), isNull);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, 'phone-b');
      expect(
        find.byKey(const Key('collection-phone-b/camera')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('settings show chosen folders and background sharing guidance', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Pictures/Tamayura'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('DCIM/Camera'), findsOneWidget);
    expect(find.text('Pictures/Tamayura'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('接收可在后台继续'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('接收可在后台继续'), findsOneWidget);
    expect(find.textContaining('通知权限为可选项，关闭通知仍可下载'), findsOneWidget);
    expect(find.textContaining('来源设备开启后台共享后可以锁屏'), findsOneWidget);
    expect(model.initializeCalls, 0);
  });

  testWidgets('error is visible, retryable, and dismissible', (tester) async {
    final model = _FakeModel()..error = '连接失败，请确认对方在线';
    await _pump(tester, model);
    expect(find.text('连接失败，请确认对方在线'), findsOneWidget);
    await tester.tap(find.text('重试连接与刷新'));
    await tester.pumpAndSettle();
    expect(model.refreshCalls, 1);
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('error-banner')), findsNothing);
  });

  testWidgets('settings open about and return to the selected settings tab', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-entry')),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await _ensureVisible(tester, find.byKey(const Key('about-entry')));
    await tester.tap(find.byKey(const Key('about-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-page')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(find.byKey(const Key('about-entry')), findsOneWidget);
    expect(model.initializeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('device filter narrows the album and survives navigation', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    await tester.tap(find.widgetWithText(ChoiceChip, '另一部手机'));
    await tester.pumpAndSettle();
    expect(model.selectedDeviceId, 'phone-b');
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('album-tab')));
    await tester.pumpAndSettle();
    expect(model.selectedDeviceId, 'phone-b');
    expect(model.initializeCalls, 0);
  });

  testWidgets('Android device identity stays hidden while names update', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const deviceId = 'android-89abcdef01234567';
      const deviceName = '客厅的手机';
      final model = _withPhoto(deviceId: deviceId, deviceName: deviceName);
      await _pump(tester, model, openCollection: false);
      expect(find.widgetWithText(ChoiceChip, deviceName), findsOneWidget);
      expect(find.text(deviceName), findsNWidgets(2));
      expect(
        find.bySemanticsLabel(RegExp('Camera，来自$deviceName，1 个瞬间')),
        findsWidgets,
      );
      _expectDeviceIdHidden(deviceId);

      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      final deviceTile = find.widgetWithText(ListTile, deviceName);
      await _ensureVisible(tester, deviceTile);
      expect(deviceTile, findsOneWidget);
      _expectDeviceIdHidden(deviceId);
      await tester.tap(deviceTile);
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, deviceId);
      await tester.tap(find.byKey(const Key('collection-$deviceId/camera')));
      await tester.pumpAndSettle();
      expect(find.text(deviceName), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('IMG_20261008.jpg，来自$deviceName')),
        findsWidgets,
      );
      _expectDeviceIdHidden(deviceId);

      const renamed = '书房的手机';
      model.devices = [
        const DeviceView(
          id: deviceId,
          name: renamed,
          address: '192.168.1.42:50728',
          online: true,
        ),
      ];
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, deviceId);
      expect(model.selectedCollectionKey, '$deviceId/camera');
      expect(find.text(deviceName), findsNothing);
      expect(find.text(renamed), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, renamed))
            .selected,
        isTrue,
      );
      _expectDeviceIdHidden(deviceId);
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      await _ensureVisible(tester, find.widgetWithText(ListTile, renamed));
      expect(find.widgetWithText(ListTile, renamed), findsOneWidget);
      expect(find.textContaining('192.168.1.42'), findsOneWidget);
      _expectDeviceIdHidden(deviceId);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('same named Android devices keep separate filters and albums', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const firstId = 'android-0123456789abcdef';
      const secondId = 'android-fedcba9876543210';
      const name = '家里的手机';
      final model = _withPhoto(deviceId: firstId, deviceName: name);
      model.devices.add(
        const DeviceView(
          id: secondId,
          name: name,
          address: '192.168.1.12:50728',
          online: false,
        ),
      );
      model.items.add(_photo(deviceId: secondId));
      await _pump(tester, model, openCollection: false);
      expect(find.widgetWithText(ChoiceChip, name), findsNWidgets(2));
      expect(
        find.byKey(const Key('collection-$firstId/camera')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('collection-$secondId/camera')),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, name).at(1));
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, secondId);
      expect(find.byKey(const Key('collection-$firstId/camera')), findsNothing);
      expect(
        find.byKey(const Key('collection-$secondId/camera')),
        findsOneWidget,
      );
      final filters = tester
          .widgetList<ChoiceChip>(find.widgetWithText(ChoiceChip, name))
          .toList();
      expect(filters[0].selected, isFalse);
      expect(filters[1].selected, isTrue);
      await tester.tap(find.byKey(const Key('collection-$secondId/camera')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-$secondId/photo-1')), findsOneWidget);
      expect(find.byKey(const Key('media-$firstId/photo-1')), findsNothing);
      expect(find.byTooltip('设备离线'), findsOneWidget);
      _expectDeviceIdHidden(firstId);
      _expectDeviceIdHidden(secondId);

      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      final firstDevice = find.byKey(const Key('device-$firstId'));
      await tester.scrollUntilVisible(
        firstDevice,
        200,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('devices-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(firstDevice);
      await tester.pumpAndSettle();
      expect(model.selectedDeviceId, firstId);
      expect(
        find.byKey(const Key('collection-$firstId/camera')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('collection-$secondId/camera')),
        findsNothing,
      );
      _expectDeviceIdHidden(firstId);
      _expectDeviceIdHidden(secondId);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('small phone lays out all screens without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _FakeModel();
    await _pump(tester, model);
    expect(tester.takeException(), isNull);
    for (final tab in ['devices-tab', 'settings-tab', 'album-tab']) {
      await tester.tap(find.byKey(Key(tab)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    model.sharedFolders = [
      const SharedFolder(id: 'camera', uri: 'DCIM/Camera', name: 'Camera'),
    ];
    model.downloadFolder = 'Pictures/Tamayura';
    model.items.add(_photo());
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('large system text remains usable on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _FakeModel();
    await _pump(tester, model);
    expect(tester.takeException(), isNull);
    for (final tab in ['devices-tab', 'settings-tab', 'album-tab']) {
      await tester.tap(find.byKey(Key(tab)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    model.sharedFolders = [
      const SharedFolder(id: 'camera', uri: 'DCIM/Camera', name: 'Camera'),
    ];
    model.downloadFolder = 'Pictures/Tamayura';
    model.items.add(_photo());
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling near the album bottom loads the next page once', (
    tester,
  ) async {
    final model = _withPhoto()..hasMoreMedia = true;
    model.items.addAll(
      List.generate(39, (index) => _photo(id: 'photo-$index-extra')),
    );
    await _pump(tester, model);
    final album = find.byKey(const PageStorageKey('album-scroll'));
    await tester.drag(album, const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(model.loadMoreCalls, 1);
    expect(model.items.last.id, 'more-photo');
    expect(find.byKey(const Key('load-more-media')), findsNothing);
  });

  testWidgets('failed page load offers retry and does not endlessly repeat', (
    tester,
  ) async {
    final model = _withPhoto()
      ..hasMoreMedia = true
      ..failLoadMore = true;
    await _pump(tester, model);
    await tester.drag(
      find.byKey(const PageStorageKey('album-scroll')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    if (model.loadMoreCalls == 0) {
      await tester.tap(find.byKey(const Key('load-more-media')));
      await tester.pumpAndSettle();
    }
    expect(model.loadMoreCalls, 1);
    expect(find.text('更多照片暂时未能加载，请重试。'), findsOneWidget);
    model.failLoadMore = false;
    await tester.tap(find.byKey(const Key('load-more-media')));
    await tester.pumpAndSettle();
    expect(model.loadMoreCalls, 2);
  });

  testWidgets('filter changes reset the album scroll position', (tester) async {
    final model = _withPhoto();
    model.items.addAll(
      List.generate(39, (index) => _photo(id: 'photo-$index-extra')),
    );
    await _pump(tester, model);
    final album = tester.widget<CustomScrollView>(
      find.byKey(const PageStorageKey('album-scroll')),
    );
    album.controller!.jumpTo(450);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('devices-tab')));
    await tester.pumpAndSettle();
    await _ensureVisible(tester, find.widgetWithText(ListTile, '另一部手机'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '另一部手机'));
    await tester.pumpAndSettle();
    expect(model.selectedDeviceId, 'phone-b');
    expect(album.controller!.offset, 0);
  });

  testWidgets(
    'preview follows a downward swipe and closes without cancelling download',
    (tester) async {
      final model = _withPhoto();
      await _pump(tester, model);
      await tester.tap(find.byKey(Key('media-${model.items.single.key}')));
      await tester.pumpAndSettle();
      expect(find.text('缓存缩略图 · 下载完成后显示原图'), findsOneWidget);
      final area = find.byKey(const Key('preview-gesture-area'));
      await tester.drag(area, const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(model.cancelCalls, 0);
      expect(model.transfers.values.single.running, isTrue);
    },
  );

  testWidgets('zooming prevents downward pan from dismissing the preview', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    await tester.tap(find.byKey(Key('media-${model.items.single.key}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preview-zoom')));
    await tester.pumpAndSettle();
    expect(find.text('双击还原'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('preview-gesture-area')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    await tester.tap(find.byKey(const Key('preview-zoom')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('preview-gesture-area')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsNothing);
  });

  testWidgets('completed photo loads local preview and does not download again', (
    tester,
  ) async {
    final model = _withPhoto();
    final photo = model.items.single;
    model.previewBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    model.transfers[photo.key] = TransferView(
      progress: 1,
      savedUri: 'content://saved/photo',
      item: photo,
    );
    await _pump(tester, model);
    final albumImage = tester.widget<Image>(
      find.byKey(ValueKey('local-album-image-${photo.key}')),
    );
    expect(
      ((albumImage.image as ResizeImage).imageProvider as MemoryImage).bytes,
      same(model.previewBytes),
    );
    await tester.tap(find.byKey(Key('media-${photo.key}')));
    await tester.pumpAndSettle();
    expect(model.downloadCalls, 0);
    expect(model.previewCalls, 2);
    expect(find.text('本机原图 · 双指缩放'), findsOneWidget);
    expect(find.byKey(const ValueKey('full-preview')), findsOneWidget);
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('full-preview')),
    );
    final resized = image.image as ResizeImage;
    expect(resized.policy, ResizeImagePolicy.fit);
    expect(resized.width, 2048);
    expect(resized.height, 2048);
  });

  testWidgets(
    'local preview read failure has a retry and external viewer fallback',
    (tester) async {
      final model = _withPhoto()..failPreview = true;
      final photo = model.items.single;
      model.transfers[photo.key] = TransferView(
        progress: 1,
        savedUri: 'content://saved/photo',
        item: photo,
      );
      await _pump(tester, model);
      await tester.tap(find.byKey(Key('media-${photo.key}')));
      await tester.pumpAndSettle();
      expect(find.text('原文件预览读取失败，可重试或用其他应用打开。'), findsOneWidget);
      await tester.tap(find.text('重新读取预览'));
      await tester.pumpAndSettle();
      expect(model.previewCalls, 3);
      await _ensureVisible(tester, find.byKey(Key('open-${photo.key}')));
      await tester.tap(find.byKey(Key('open-${photo.key}')));
      await tester.pumpAndSettle();
      expect(model.openCalls, 1);
    },
  );

  testWidgets(
    'video preview uses the system player instead of decoding video bytes',
    (tester) async {
      final model = _withPhoto();
      final video = _photo(video: true);
      model.items.clear();
      model.items.add(video);
      model.transfers[video.key] = TransferView(
        progress: 1,
        savedUri: 'content://saved/video',
        item: video,
      );
      await _pump(tester, model);
      await tester.tap(find.byKey(Key('media-${video.key}')));
      await tester.pumpAndSettle();
      expect(find.text('播放视频'), findsOneWidget);
      expect(model.previewCalls, 0);
      await tester.tap(find.byKey(Key('open-${video.key}')));
      expect(model.openCalls, 1);
    },
  );

  testWidgets(
    'download tasks survive filtered albums and can cancel then retry',
    (tester) async {
      final model = _FakeModel();
      final photo = _photo();
      model.transfers[photo.key] = TransferView(
        progress: .4,
        item: photo,
        receivedBytes: 1000,
        totalBytes: photo.size,
      );
      await _pump(tester, model);
      await tester.tap(find.byKey(const Key('downloads-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('downloads-page')), findsOneWidget);
      expect(find.text(photo.name), findsOneWidget);
      await tester.tap(find.byKey(Key('cancel-${photo.key}')));
      await tester.pumpAndSettle();
      expect(model.cancelCalls, 1);
      expect(find.text('已暂停'), findsOneWidget);
      await tester.tap(find.byKey(Key('retry-${photo.key}')));
      await tester.pumpAndSettle();
      expect(model.downloadCalls, 1);
      expect(find.text('正在下载'), findsOneWidget);
      model.transfers[photo.key] = TransferView(
        progress: .4,
        item: photo,
        status: TransferStatus.failed,
        error: '来源设备离线',
        attempt: 2,
      );
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('来源设备离线'), findsOneWidget);
      expect(find.text('第 2 次尝试'), findsOneWidget);
    },
  );

  testWidgets('empty download task list gives album guidance', (tester) async {
    await _pump(tester, _FakeModel());
    await tester.tap(find.byKey(const Key('downloads-entry')));
    await tester.pumpAndSettle();
    expect(find.text('下一张心动的照片，在路上'), findsOneWidget);
  });

  testWidgets('preview and tasks fit small phones with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final model = _withPhoto();
    await _pump(tester, model);
    await _scrollAlbumTo(
      tester,
      find.byKey(Key('media-${model.items.single.key}')),
    );
    await tester.tap(find.byKey(Key('media-${model.items.single.key}')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('close-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('downloads-entry')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('two finger pinch zooms without triggering drag dismissal', (
    tester,
  ) async {
    final model = _withPhoto();
    await _pump(tester, model);
    await tester.tap(find.byKey(Key('media-${model.items.single.key}')));
    await tester.pumpAndSettle();
    final center = tester.getCenter(
      find.byKey(const Key('preview-gesture-area')),
    );
    final first = await tester.startGesture(
      center + const Offset(-40, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveTo(center + const Offset(-100, 30));
    await second.moveTo(center + const Offset(100, 30));
    await tester.pump();
    await first.moveTo(center + const Offset(-120, 50));
    await second.moveTo(center + const Offset(120, 50));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const Key('preview-zoom-view')),
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1.05),
    );
    expect(model.cancelCalls, 0);
  });
}
