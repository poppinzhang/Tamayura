import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
// Non-square fixtures exercise cover cropping in both orientations.
final _landscapePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAwAAAAGCAIAAAB4jOjWAAAAi0lEQVR4nA3KoRFEIQxF0a3kV0AFVICMooLXASYWnxkqYOZ6bAzdLUef32cUoxrN6IaMYUxjGds4xjV+nyiiiia6kBhiiiW2OOLqJac41WlOd+QMZzrL2c5xrr8UlKAGLeiBghHMYAU7OMGNl6BAhQYdBAMmLNhw4PJSUpKatKQnSkYyk5Xs5CQ3+QOBIW/NFkSIhgAAAABJRU5ErkJggg==',
);
final _portraitPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAYAAAAMCAIAAADONVt5AAAAjUlEQVR4nA3IoRFEIQxAwavkF5IqUBFoNCYGjWYmDv00sWhqu6zc31eQghas4IUo/L6KVLRiFa9EzWpIQxvW8Ea0rI50tGMd70TPGshABzbwQYysiUx0YhOfxMxayEIXtvBFrKyNbHRjG9/EzgIBBQOHIOsgBz3YwQ9xsi5y0Ytd/BI36yEPfdjDH/H4A7k8bz23O/WKAAAAAElFTkSuQmCC',
);

MediaView _photo(int index, {bool video = false}) => MediaView(
  id: '$index',
  deviceId: 'peer',
  name: video ? 'video-$index.mp4' : 'photo-$index.jpg',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  sharedFolderId: 'camera',
  sharedFolderName: '相机',
  size: 1024,
  modified: DateTime(2026, 10, 17),
  thumbnail: index.isOdd ? _landscapePng : _portraitPng,
);

class _Model extends TamayuraModel {
  @override
  bool loading = false;
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
      thumbnail: _png,
    ),
  ];
  @override
  final List<MediaView> media = List.generate(12, (index) => _photo(index + 1));
  @override
  final Map<String, TransferView> transfers = {};
  @override
  bool albumDetailedMode = false;
  @override
  bool albumDetailedModeSaving = false;
  @override
  bool backgroundSharingEnabled = false;
  @override
  bool backgroundSharingStarting = false;
  @override
  bool hasMoreMedia = false;
  final displayRequests = <bool>[];
  final downloads = <String>[];
  final deletions = <String>[];
  Completer<void>? displayGate;
  Completer<void>? pageGate;
  bool failDisplaySave = false;
  bool failPage = false;
  int pageRequests = 0;

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
  Future<void> setAlbumDetailedMode(bool enabled) async {
    displayRequests.add(enabled);
    albumDetailedModeSaving = true;
    notifyListeners();
    try {
      await displayGate?.future;
      if (failDisplaySave) throw StateError('settings unavailable');
      albumDetailedMode = enabled;
    } finally {
      albumDetailedModeSaving = false;
      notifyListeners();
    }
  }

  @override
  Future<void> download(MediaView item) async => downloads.add(item.key);
  @override
  Future<void> share(MediaView item) async {}
  @override
  Future<bool> deleteLocalFile(MediaView item) async {
    deletions.add(item.key);
    transfers.remove(item.key);
    notifyListeners();
    return true;
  }

  @override
  Future<void> loadMoreMedia() async {
    pageRequests++;
    await pageGate?.future;
    if (failPage) throw StateError('page unavailable');
    final nextId = media.length + 1;
    media.addAll(List.generate(8, (index) => _photo(nextId + index)));
    hasMoreMedia = false;
    notifyListeners();
  }

  @override
  void clearError() {}

  void savePhoto(int index) {
    final item = media[index];
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
  Size size = const Size(390, 1000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('album-capture'),
      child: TamayuraApp(model: model),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _openDisplaySetting(WidgetTester tester) async {
  await _tap(tester, 'settings-tab');
  await tester.scrollUntilVisible(
    find.byKey(const Key('album-detailed-mode')),
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

Finder get _grid => find.byKey(const Key('album-media-grid'));

SliverGridDelegateWithFixedCrossAxisCount _gridLayout(WidgetTester tester) =>
    tester.widget<SliverGrid>(_grid).gridDelegate
        as SliverGridDelegateWithFixedCrossAxisCount;

SwitchListTile _displaySetting(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('album-detailed-mode')));

Finder _gridText(String text) =>
    find.descendant(of: _grid, matching: find.text(text));

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets('default album uses four square columns at width $width', (
      tester,
    ) async {
      final model = _Model();
      await _show(tester, model, size: Size(width, 1000));
      final layout = _gridLayout(tester);
      expect(layout.crossAxisCount, 4);
      expect(layout.childAspectRatio, 1);
      expect(layout.mainAxisExtent, isNull);
      expect(layout.mainAxisSpacing, 2);
      expect(layout.crossAxisSpacing, 2);

      final first = tester.getRect(find.byKey(const Key('media-peer/1')));
      final second = tester.getRect(find.byKey(const Key('media-peer/2')));
      final fourth = tester.getRect(find.byKey(const Key('media-peer/4')));
      final fifth = tester.getRect(find.byKey(const Key('media-peer/5')));
      expect(first.width, closeTo(first.height, .01));
      expect(first.left, closeTo(2, .01));
      expect(fourth.right, closeTo(width - 2, .01));
      expect(first.top, closeTo(fourth.top, .01));
      expect(second.left - first.right, closeTo(2, .01));
      expect(fifth.top - first.bottom, closeTo(2, .01));
      expect(_gridText('photo-1.jpg'), findsNothing);
      expect(_gridText('来源设备'), findsNothing);
      expect(_gridText('10月17日'), findsNothing);
      for (final id in [1, 2]) {
        final thumbnail = tester.widget<Image>(
          find.byKey(ValueKey('cached-album-image-peer/$id')),
        );
        expect(thumbnail.fit, BoxFit.cover);
        final resized = thumbnail.image as ResizeImage;
        expect(
          (resized.imageProvider as MemoryImage).bytes,
          id.isOdd ? _landscapePng : _portraitPng,
        );
      }
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets(
    'display setting explains both modes and updates the open album',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      await _openDisplaySetting(tester);
      final setting = _displaySetting(tester);
      expect(setting.value, isFalse);
      expect(
        setting.title,
        isA<Text>().having((text) => text.data, 'title', '详细模式'),
      );
      final explanation = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byWidget(setting.subtitle!),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data ?? '')
          .join(' ');
      expect(explanation, contains('正方形'));
      expect(explanation, contains('文件名'));
      expect(explanation, contains('日期'));
      await _tap(tester, 'album-detailed-mode');
      expect(_displaySetting(tester).value, isTrue);
      await _tap(tester, 'album-tab');
      expect(model.selectedCollectionKey, 'peer/camera');
      expect(_gridLayout(tester).crossAxisCount, 2);
      expect(_gridLayout(tester).mainAxisSpacing, 14);
      expect(_gridLayout(tester).crossAxisSpacing, 12);
      expect(_gridText('photo-1.jpg'), findsOneWidget);
      expect(_gridText('来源设备'), findsWidgets);
      expect(_gridText('10月17日'), findsWidgets);

      await _openDisplaySetting(tester);
      await _tap(tester, 'album-detailed-mode');
      await _tap(tester, 'album-tab');
      expect(_gridLayout(tester).crossAxisCount, 4);
      expect(_gridText('photo-1.jpg'), findsNothing);
      expect(_gridText('来源设备'), findsNothing);
      expect(_gridText('10月17日'), findsNothing);
      expect(model.displayRequests, [true, false]);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'display setting blocks duplicate saves and initialization edits',
    (tester) async {
      final model = _Model()..displayGate = Completer<void>();
      await _show(tester, model);
      await _openDisplaySetting(tester);
      await tester.tap(find.byKey(const Key('album-detailed-mode')));
      await tester.pump();
      expect(_displaySetting(tester).onChanged, isNull);
      await tester.tap(find.byKey(const Key('album-detailed-mode')));
      await tester.pump();
      expect(model.displayRequests, [true]);
      model.displayGate!.complete();
      await tester.pumpAndSettle();
      expect(_displaySetting(tester).value, isTrue);
      expect(_displaySetting(tester).onChanged, isNotNull);
      model
        ..backgroundSharingEnabled = true
        ..backgroundSharingStarting = true
        ..loading = true;
      model.notifyListeners();
      await tester.pump();
      expect(_displaySetting(tester).onChanged, isNull);
      model.loading = false;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(_displaySetting(tester).onChanged, isNotNull);
    },
  );

  testWidgets('failed display save reports the error and keeps compact mode', (
    tester,
  ) async {
    final model = _Model()..failDisplaySave = true;
    await _show(tester, model);
    await _openDisplaySetting(tester);
    await _tap(tester, 'album-detailed-mode');
    expect(find.text('操作未能完成，请检查网络与目录权限后重试。'), findsOneWidget);
    expect(_displaySetting(tester).value, isFalse);
    expect(_displaySetting(tester).onChanged, isNotNull);
    await _tap(tester, 'album-tab');
    expect(_gridLayout(tester).childAspectRatio, 1);
    expect(_gridText('photo-1.jpg'), findsNothing);
  });

  testWidgets(
    'compact image tap opens preview and starts the original download',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      await _tap(tester, 'media-peer/1');
      expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
      expect(model.downloads, ['peer/1']);
      expect(find.text('photo-1.jpg'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact saved images support long press, selection and deletion',
    (tester) async {
      final model = _Model()
        ..savePhoto(0)
        ..savePhoto(1);
      await _show(tester, model);
      await tester.longPress(find.byKey(const Key('media-peer/1')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await _tap(tester, 'media-peer/2');
      expect(find.text('已选择 2 项'), findsOneWidget);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      await _tap(tester, 'confirm-delete-local');
      expect(model.deletions, containsAll(['peer/1', 'peer/2']));
      expect(model.transfers, isEmpty);
      expect(find.byType(Checkbox), findsNothing);
      expect(_gridText('photo-1.jpg'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'compact pagination loads more photos and reports retryable errors',
    (tester) async {
      final model = _Model()
        ..hasMoreMedia = true
        ..failPage = true;
      await _show(tester, model, size: const Size(390, 1100));
      await _tap(tester, 'load-more-media');
      expect(model.pageRequests, 1);
      expect(find.text('更多照片暂时未能加载，请重试。'), findsOneWidget);
      expect(find.text('重试加载'), findsOneWidget);
      model
        ..failPage = false
        ..pageGate = Completer<void>();
      await tester.tap(find.byKey(const Key('load-more-media')));
      await tester.pump();
      expect(model.pageRequests, 2);
      expect(find.text('正在加载更多照片…'), findsOneWidget);
      expect(find.byKey(const Key('load-more-media')), findsNothing);
      model.pageGate!.complete();
      await tester.pumpAndSettle();
      expect(model.media, hasLength(20));
      expect(find.text('20 个瞬间'), findsOneWidget);
      expect(find.text('更多照片暂时未能加载，请重试。'), findsNothing);
      expect(find.byKey(const Key('load-more-media')), findsNothing);
      expect(_gridLayout(tester).childAspectRatio, 1);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 1000), const Size(1440, 1100)]) {
    testWidgets(
      'both modes fit ${size.width} wide windows with large text',
      (tester) async {
        final model = _Model();
        await _show(tester, model, size: size, textScale: 1.6);
        expect(tester.takeException(), isNull);
        expect(_gridLayout(tester).childAspectRatio, 1);
        expect(_gridLayout(tester).crossAxisCount, inInclusiveRange(3, 12));
        await _openDisplaySetting(tester);
        expect(tester.takeException(), isNull);
        await _tap(tester, 'album-detailed-mode');
        await _tap(tester, 'album-tab');
        expect(_gridText('photo-1.jpg'), findsOneWidget);
        expect(_gridLayout(tester).crossAxisCount, inInclusiveRange(2, 5));
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

  // Optional local visual review; routine tests do not load system fonts or
  // write screenshots.
  const captureDirectory = String.fromEnvironment('TAMAYURA_ALBUM_SCREENSHOTS');
  if (captureDirectory.isNotEmpty) {
    testWidgets('capture both album display modes for visual review', (
      tester,
    ) async {
      await tester.runAsync(() async {
        const fontPath = String.fromEnvironment('TAMAYURA_SCREENSHOT_FONT');
        final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
        for (final family in ['Roboto', '.SF UI Text', '.SF UI Display']) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
        const iconPath = String.fromEnvironment('TAMAYURA_SCREENSHOT_ICONS');
        if (iconPath.isNotEmpty) {
          await (FontLoader('MaterialIcons')..addFont(
                Future.value(
                  ByteData.sublistView(await File(iconPath).readAsBytes()),
                ),
              ))
              .load();
        }
      });
      final model = _Model();
      model.media.addAll(List.generate(36, (index) => _photo(index + 13)));
      await _show(tester, model, size: const Size(390, 844));
      for (final detailed in [false, true]) {
        model.albumDetailedMode = detailed;
        model.notifyListeners();
        await tester.pumpAndSettle();
        final context = tester.element(_grid);
        final providers = tester
            .widgetList<Image>(find.byType(Image))
            .map((image) => image.image)
            .toSet();
        await tester.runAsync(() async {
          await Future.wait(
            providers.map((provider) => precacheImage(provider, context)),
          );
        });
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('album-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final name = detailed ? 'album-detailed.png' : 'album-compact.png';
            final file = File('$captureDirectory/$name');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
