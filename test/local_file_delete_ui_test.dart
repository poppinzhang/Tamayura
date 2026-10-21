import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

final _image = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

MediaView _item(String id, {bool video = false}) => MediaView(
  id: id,
  deviceId: 'peer',
  name: video ? '$id.mp4' : '$id.jpg',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  sharedFolderId: 'camera',
  sharedFolderName: '相机',
  size: 100,
  modified: DateTime(2026, 10, 17),
  thumbnail: _image,
);

class _Model extends TamayuraModel {
  _Model() {
    for (final item in media.take(2)) {
      transfers[item.key] = TransferView(
        progress: 1,
        item: item,
        savedUri: 'content://saved/${item.id}',
      );
    }
  }
  @override
  bool get loading => false;
  @override
  bool get busy => false;
  @override
  String? error;
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
      thumbnail: _image,
    ),
  ];
  @override
  final List<MediaView> media = [
    _item('photo'),
    _item('video', video: true),
    _item('unsaved'),
  ];
  @override
  final Map<String, TransferView> transfers = {};
  final deleted = <String>[];
  final downloads = <String>[];
  final failures = <String>{};
  final exceptions = <String>{};
  Completer<void>? deletionGate;
  Completer<Uint8List?>? previewGate;

  void changed() => notifyListeners();
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
  Future<void> download(MediaView item) async => downloads.add(item.key);
  @override
  Future<void> share(MediaView item) async {}
  @override
  Future<Uint8List?> loadPreview(
    MediaView item, {
    int maxDimension = 2560,
    bool Function()? isCurrent,
  }) async => previewGate == null ? _image : await previewGate!.future;
  @override
  Future<bool> deleteLocalFile(MediaView item) async {
    deleted.add(item.key);
    await deletionGate?.future;
    if (exceptions.contains(item.key)) throw StateError('provider unavailable');
    if (failures.contains(item.key)) {
      error = '无法删除本地文件，请检查目录权限。';
      notifyListeners();
      return false;
    }
    transfers.remove(item.key);
    error = null;
    notifyListeners();
    return true;
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

Future<void> _show(
  WidgetTester tester,
  _Model model, {
  bool small = false,
}) async {
  tester.view.physicalSize = small
      ? const Size(360, 780)
      : const Size(1000, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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

Future<void> _longPress(WidgetTester tester, String key) async {
  final target = find.byKey(Key('media-$key'));
  await tester.ensureVisible(target);
  await tester.longPress(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'mobile long press selects saved photo and video only',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      expect(find.byKey(const Key('delete-local-files')), findsNothing);
      await _longPress(tester, 'peer/unsaved');
      expect(find.byType(Checkbox), findsNothing);
      await _longPress(tester, 'peer/photo');
      expect(find.text('已选择 1 项'), findsOneWidget);
      expect(find.text('删除本地文件'), findsOneWidget);
      expect(model.downloads, isEmpty);
      await _tap(tester, 'media-peer/video');
      expect(find.text('已选择 2 项'), findsOneWidget);
      await _tap(tester, 'media-peer/unsaved');
      expect(find.text('已选择 2 项'), findsOneWidget);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('select-local-peer/unsaved')),
            )
            .onChanged,
        isNull,
      );
      await _tap(tester, 'confirm-delete-local');
      expect(model.deleted, ['peer/photo', 'peer/video']);
      expect(model.transfers, isEmpty);
      expect(model.media, hasLength(3));
      expect(find.byType(Checkbox), findsNothing);
      expect(find.textContaining('已删除 2 个本地文件'), findsOneWidget);
      await _tap(tester, 'media-peer/photo');
      expect(model.downloads, ['peer/photo']);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'desktop button enters selection then confirms deletion',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      expect(find.text('删除本地文件'), findsOneWidget);
      await _longPress(tester, 'peer/photo');
      expect(find.byType(Checkbox), findsNothing);
      await _tap(tester, 'close-preview');
      await _tap(tester, 'delete-local-files');
      expect(find.text('确认'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('confirm-delete-local')))
            .onPressed,
        isNull,
      );
      await _tap(tester, 'select-local-peer/video');
      expect(find.text('已选择 1 项'), findsOneWidget);
      await _tap(tester, 'confirm-delete-local');
      expect(model.deleted, ['peer/video']);
      expect(model.transfers.keys, ['peer/photo']);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('delete-local-files')), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'desktop delete entry stays visible but disabled without saved files',
    (tester) async {
      final model = _Model()..transfers.clear();
      await _show(tester, model);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('delete-local-files')))
            .onPressed,
        isNull,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'batch partial failure retains failed selection for retry and blocks duplicate actions',
    (tester) async {
      final model = _Model()..exceptions.add('peer/video');
      await _show(tester, model);
      await _longPress(tester, 'peer/photo');
      await _tap(tester, 'media-peer/video');
      model.deletionGate = Completer<void>();
      await _tap(tester, 'confirm-delete-local');
      expect(find.text('正在删除…'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('cancel-delete-local')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const Key('select-local-peer/photo')))
            .onChanged,
        isNull,
      );
      await _tap(tester, 'confirm-delete-local');
      expect(model.deleted, ['peer/photo']);
      model.deletionGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      expect(find.textContaining('1 个未能删除'), findsOneWidget);
      expect(model.transfers.keys, ['peer/video']);
      model.exceptions.clear();
      await _tap(tester, 'confirm-delete-local');
      expect(model.deleted, ['peer/photo', 'peer/video', 'peer/video']);
      expect(model.transfers, isEmpty);
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets('cancel, back and navigation clear selection without deleting', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model);
    await _longPress(tester, 'peer/photo');
    await _tap(tester, 'cancel-delete-local');
    expect(find.byType(Checkbox), findsNothing);
    await _longPress(tester, 'peer/photo');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(model.selectedCollectionKey, 'peer/camera');
    await _longPress(tester, 'peer/photo');
    await _tap(tester, 'back-to-collections');
    expect(find.byType(Checkbox), findsNothing);
    await _tap(tester, 'collection-peer/camera');
    expect(find.byType(Checkbox), findsNothing);
    expect(model.deleted, isEmpty);
  });

  testWidgets('selection drops saved files removed by a model update', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model);
    await _longPress(tester, 'peer/photo');
    model.transfers.remove('peer/photo');
    model.changed();
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirm-delete-local')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'preview deletion clears original image and supports downloading again on every platform',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      expect(
        find.byKey(const ValueKey('local-album-image-peer/photo')),
        findsOneWidget,
      );
      await _tap(tester, 'media-peer/photo');
      expect(find.byKey(const ValueKey('full-preview')), findsOneWidget);
      await _tap(tester, 'preview-delete-local');
      expect(model.deleted, ['peer/photo']);
      expect(find.byKey(const ValueKey('full-preview')), findsNothing);
      expect(find.byKey(const ValueKey('cached-preview')), findsOneWidget);
      expect(find.byKey(const Key('preview-delete-local')), findsNothing);
      expect(find.byKey(const Key('share-peer/photo')), findsNothing);
      expect(find.text('原文件尚未下载'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await _tap(tester, 'retry-peer/photo');
      expect(model.downloads, ['peer/photo']);
      await _tap(tester, 'close-preview');
      expect(
        find.byKey(const ValueKey('local-album-image-peer/photo')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('cached-album-image-peer/photo')),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('failed preview deletion preserves original and allows retry', (
    tester,
  ) async {
    final model = _Model()..failures.add('peer/photo');
    await _show(tester, model);
    await _tap(tester, 'media-peer/photo');
    await _tap(tester, 'preview-delete-local');
    expect(find.byKey(const ValueKey('full-preview')), findsOneWidget);
    expect(find.byKey(const Key('preview-delete-local')), findsOneWidget);
    expect(find.text('无法删除本地文件，请检查目录权限。'), findsOneWidget);
    model.failures.clear();
    await _tap(tester, 'preview-delete-local');
    expect(find.byKey(const Key('preview-delete-local')), findsNothing);
  });

  testWidgets('deleting during preview loading ignores late original bytes', (
    tester,
  ) async {
    final model = _Model()..previewGate = Completer<Uint8List?>();
    await _show(tester, model);
    await _tap(tester, 'media-peer/photo');
    await _tap(tester, 'preview-delete-local');
    model.previewGate!.complete(_image);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('full-preview')), findsNothing);
    expect(find.byKey(const ValueKey('cached-preview')), findsOneWidget);
    expect(find.text('正在读取本机原图…'), findsNothing);
  });

  testWidgets('saved video preview has deletion and unsaved preview does not', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model);
    await _tap(tester, 'media-peer/video');
    await _tap(tester, 'preview-delete-local');
    expect(model.deleted, ['peer/video']);
    await _tap(tester, 'close-preview');
    await _tap(tester, 'media-peer/unsaved');
    expect(find.byKey(const Key('preview-delete-local')), findsNothing);
  });

  testWidgets('mobile selection and preview deletion fit a narrow screen', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model, small: true);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await _longPress(tester, 'peer/photo');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'cancel-delete-local');
    await _tap(tester, 'media-peer/photo');
    expect(find.byKey(const Key('preview-delete-local')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
