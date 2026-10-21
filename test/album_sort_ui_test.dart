import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

MediaView _photo(int index) => MediaView(
  id: '$index',
  deviceId: 'peer',
  name: 'photo-$index.jpg',
  mimeType: 'image/jpeg',
  sharedFolderId: 'camera',
  sharedFolderName: '相机',
  size: 100,
  modified: DateTime(2026, 10, 17),
  thumbnail: Uint8List(0),
);

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
  List<String> get addresses => [];
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
    DeviceView(id: 'peer', name: '来源设备', address: '', online: false),
  ];
  @override
  String? selectedDeviceId;
  @override
  String? selectedCollectionKey = 'peer/camera';
  @override
  List<MediaCollection> get collections => [
    MediaCollection(
      deviceId: 'peer',
      sharedFolderId: 'camera',
      sharedFolderName: '相机',
      itemCount: media.length,
      thumbnail: Uint8List(0),
    ),
  ];
  @override
  final List<MediaView> media = [_photo(1), _photo(2)];
  @override
  final Map<String, TransferView> transfers = {};
  @override
  MediaSortOrder mediaSortOrder = MediaSortOrder.dateDescending;
  @override
  bool mediaSortOrderChanging = false;
  @override
  bool hasMoreMedia = false;
  final sortRequests = <MediaSortOrder>[];
  final downloads = <String>[];
  Completer<void>? sortGate;
  Completer<void>? deleteGate;
  Completer<void>? pageGate;
  bool failSort = false;

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
    selectedCollectionKey = null;
    notifyListeners();
  }

  @override
  Future<void> selectCollection(String? key) async {
    selectedCollectionKey = key;
    notifyListeners();
  }

  @override
  Future<void> setMediaSortOrder(MediaSortOrder order) async {
    sortRequests.add(order);
    mediaSortOrderChanging = true;
    notifyListeners();
    try {
      await sortGate?.future;
      if (failSort) throw StateError('catalog unavailable');
      mediaSortOrder = order;
    } finally {
      mediaSortOrderChanging = false;
      notifyListeners();
    }
  }

  @override
  Future<void> download(MediaView item) async => downloads.add(item.key);
  @override
  Future<void> share(MediaView item) async {}
  @override
  Future<bool> deleteLocalFile(MediaView item) async {
    await deleteGate?.future;
    transfers.remove(item.key);
    notifyListeners();
    return true;
  }

  @override
  Future<void> loadMoreMedia() async => await pageGate?.future;
  @override
  void clearError() {}

  void saveFirstPhoto() {
    final item = media.first;
    transfers[item.key] = TransferView(
      progress: 1,
      item: item,
      savedUri: 'content://saved/${item.id}',
    );
  }
}

Future<void> _show(
  WidgetTester tester,
  _Model model, {
  Size size = const Size(1000, 1100),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(TamayuraApp(model: model));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

PopupMenuButton<MediaSortOrder> _sortButton(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('album-sort')));

void main() {
  testWidgets('sort control appears only inside a collection', (tester) async {
    final model = _Model()..selectedCollectionKey = null;
    await _show(tester, model);
    expect(find.byKey(const Key('album-sort')), findsNothing);
    await _tap(tester, 'collection-peer/camera');
    expect(find.text('排序：日期降序'), findsOneWidget);
    expect(find.byTooltip('按名称或文件修改日期排序'), findsOneWidget);
    await _tap(tester, 'back-to-collections');
    expect(find.byKey(const Key('album-sort')), findsNothing);
  });

  testWidgets(
    'all four orders show their current check and never download',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      final labels = {
        MediaSortOrder.nameAscending: '名称升序',
        MediaSortOrder.nameDescending: '名称降序',
        MediaSortOrder.dateAscending: '日期升序',
        MediaSortOrder.dateDescending: '日期降序',
      };
      for (final order in MediaSortOrder.values) {
        await _tap(tester, 'album-sort');
        final entries = tester.widgetList<CheckedPopupMenuItem<MediaSortOrder>>(
          find.byWidgetPredicate(
            (widget) => widget is CheckedPopupMenuItem<MediaSortOrder>,
          ),
        );
        expect(entries, hasLength(4));
        expect(
          entries.where((entry) => entry.checked).single.value,
          model.mediaSortOrder,
        );
        await _tap(tester, 'album-sort-${order.name}');
        expect(model.mediaSortOrder, order);
        expect(find.text('排序：${labels[order]}'), findsOneWidget);
      }
      expect(model.sortRequests, MediaSortOrder.values);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('same order is a no-op and failure keeps the selected order', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model);
    await _tap(tester, 'album-sort');
    await _tap(tester, 'album-sort-dateDescending');
    expect(model.sortRequests, isEmpty);
    model.failSort = true;
    await _tap(tester, 'album-sort');
    await _tap(tester, 'album-sort-nameAscending');
    expect(find.text('操作未能完成，请检查网络与目录权限后重试。'), findsOneWidget);
    expect(find.text('排序：日期降序'), findsOneWidget);
    expect(_sortButton(tester).enabled, isTrue);
    expect(model.downloads, isEmpty);
  });

  testWidgets('changing order clears selection and blocks duplicate requests', (
    tester,
  ) async {
    final model = _Model()
      ..saveFirstPhoto()
      ..sortGate = Completer<void>();
    await _show(tester, model);
    await tester.longPress(find.byKey(const Key('media-peer/1')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    await _tap(tester, 'album-sort');
    await _tap(tester, 'album-sort-nameDescending');
    expect(find.text('已选择 1 项'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('正在排序…'), findsOneWidget);
    expect(_sortButton(tester).enabled, isFalse);
    await _tap(tester, 'album-sort');
    expect(find.byKey(const Key('album-sort-dateAscending')), findsNothing);
    expect(model.sortRequests, [MediaSortOrder.nameDescending]);
    model.sortGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('排序：名称降序'), findsOneWidget);
    expect(_sortButton(tester).enabled, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('deleting local files disables sorting until completion', (
    tester,
  ) async {
    final model = _Model()
      ..saveFirstPhoto()
      ..deleteGate = Completer<void>();
    await _show(tester, model);
    await _tap(tester, 'delete-local-files');
    await _tap(tester, 'select-local-peer/1');
    await _tap(tester, 'confirm-delete-local');
    expect(_sortButton(tester).enabled, isFalse);
    await _tap(tester, 'album-sort');
    expect(model.sortRequests, isEmpty);
    model.deleteGate!.complete();
    await tester.pumpAndSettle();
    expect(_sortButton(tester).enabled, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('sorting resets scroll and ignores an obsolete page failure', (
    tester,
  ) async {
    final model = _Model()
      ..hasMoreMedia = true
      ..pageGate = Completer<void>();
    await _show(tester, model);
    final loadMore = tester.widget<TextButton>(
      find.byKey(const Key('load-more-media')),
    );
    loadMore.onPressed!();
    await tester.pump();
    _sortButton(tester).onSelected!(MediaSortOrder.nameAscending);
    await tester.pumpAndSettle();
    model.pageGate!.completeError(StateError('old query failed'));
    await tester.pumpAndSettle();
    expect(find.text('更多照片暂时未能加载，请重试。'), findsNothing);
    expect(find.text('正在加载更多照片…'), findsNothing);

    model.hasMoreMedia = false;
    model.media.addAll(List.generate(40, (index) => _photo(index + 3)));
    await model.selectCollection('peer/camera');
    await tester.pumpAndSettle();
    final album = tester.widget<CustomScrollView>(
      find.byKey(const PageStorageKey('album-scroll')),
    );
    final changeOrder = _sortButton(tester).onSelected!;
    album.controller!.jumpTo(500);
    await tester.pump();
    expect(album.controller!.offset, greaterThan(0));
    changeOrder(MediaSortOrder.dateAscending);
    await tester.pumpAndSettle();
    expect(album.controller!.offset, 0);
    expect(model.downloads, isEmpty);
  });

  testWidgets(
    'sort menu fits narrow mobile and desktop windows with large text',
    (tester) async {
      final model = _Model();
      await _show(tester, model, size: const Size(360, 900), textScale: 1.6);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'album-sort');
      expect(
        find.byKey(const Key('album-sort-dateDescending')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'album-sort-dateAscending');
      expect(find.text('排序：日期升序'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
