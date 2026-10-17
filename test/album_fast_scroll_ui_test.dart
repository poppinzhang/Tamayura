import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

MediaView _photo(int index, {String? name}) {
  final prefix = index < 32
      ? '0'
      : index >= 240
      ? '相'
      : String.fromCharCode(65 + (index - 32) ~/ 8);
  return MediaView(
    id: '$index',
    deviceId: 'peer',
    name: name ?? '$prefix-${index.toString().padLeft(3, '0')}.jpg',
    mimeType: 'image/jpeg',
    sharedFolderId: 'camera',
    sharedFolderName: '相机',
    size: 1024,
    modified: DateTime(2026, 10, 17).subtract(Duration(days: index ~/ 4 * 9)),
    thumbnail: Uint8List(0),
  );
}

class _Model extends TamayuraModel {
  _Model({int count = 272}) : media = List.generate(count, _photo);

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
    for (final folder in ['camera', 'travel'])
      MediaCollection(
        deviceId: 'peer',
        sharedFolderId: folder,
        sharedFolderName: folder == 'camera' ? '相机' : '旅行',
        itemCount: media.length,
        thumbnail: Uint8List(0),
      ),
  ];
  @override
  final List<MediaView> media;
  @override
  final Map<String, TransferView> transfers = {};
  @override
  bool albumDetailedMode = false;
  @override
  MediaSortOrder mediaSortOrder = MediaSortOrder.dateDescending;
  final downloads = <String>[];
  final deletions = <String>[];

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
    mediaSortOrder = order;
    final byName =
        order == MediaSortOrder.nameAscending ||
        order == MediaSortOrder.nameDescending;
    final ascending =
        order == MediaSortOrder.nameAscending ||
        order == MediaSortOrder.dateAscending;
    media.sort((left, right) {
      final comparison = byName
          ? left.name.compareTo(right.name)
          : left.modified.compareTo(right.modified);
      return comparison == 0
          ? left.id.compareTo(right.id)
          : ascending
          ? comparison
          : -comparison;
    });
    notifyListeners();
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
  void clearError() {}
}

class _IndexedModel extends _Model {
  _IndexedModel() : super(count: 60) {
    for (var index = 0; index < media.length; index++) {
      loaded[index] = media[index];
    }
  }

  final allItems = List.generate(1600, _photo);
  final loaded = <int, MediaView>{};
  final requests = <(int, int)>[];
  late final entries = [
    for (final item in allItems)
      MediaScrollEntry(
        id: item.id,
        deviceId: item.deviceId,
        name: item.name,
        modified: item.modified,
      ),
  ];
  int pageRequests = 0;
  bool failRanges = false;
  String? rangeError;

  @override
  String? get error => rangeError;
  @override
  List<MediaScrollEntry> get mediaScrollEntries => entries;
  @override
  int get totalMediaCount => allItems.length;
  @override
  bool get hasMoreMedia => true;
  @override
  MediaView? mediaAtScrollIndex(int index) => loaded[index];

  @override
  Future<void> ensureMediaScrollRange(int first, int last) async {
    requests.add((first, last));
    if (failRanges) {
      rangeError = '缩略图暂时未能加载，请重试。';
      notifyListeners();
      throw StateError('catalog unavailable');
    }
    rangeError = null;
    loaded.clear();
    for (var index = first; index <= last; index++) {
      loaded[index] = allItems[index];
    }
    media
      ..clear()
      ..addAll(loaded.values);
    notifyListeners();
  }

  @override
  Future<void> loadMoreMedia() async => pageRequests++;
}

const _mobilePlatforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});
Finder get _scroll => find.byKey(const PageStorageKey('album-scroll'));
Finder get _thumb => find.byKey(const Key('album-fast-scroll-thumb'));
Finder get _date => find.byKey(const Key('album-fast-scroll-date'));
Finder get _label => find.byKey(const Key('album-fast-scroll-label'));

Future<void> _show(
  WidgetTester tester,
  _Model model, {
  Size size = const Size(390, 844),
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
      key: const Key('fast-scroll-capture'),
      child: TamayuraApp(model: model),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _controller(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_scroll).controller!;

double _opacity(WidgetTester tester) {
  final finder = find.byKey(const Key('album-fast-scroll-opacity'));
  return finder.evaluate().isEmpty
      ? 0
      : tester.widget<AnimatedOpacity>(finder).opacity;
}

Future<void> _scrollDown(WidgetTester tester, {double distance = 400}) async {
  await tester.drag(_scroll, Offset(0, -distance));
  await tester.pumpAndSettle();
}

Future<void> _dragThumbTo(WidgetTester tester, double fraction) async {
  final track = tester.getRect(
    find.byKey(const Key('album-fast-scroll-track')),
  );
  final start = tester.getCenter(_thumb);
  final gesture = await tester.startGesture(start);
  await gesture.moveBy(Offset(0, fraction == 0 ? -20 : 20));
  await tester.pump();
  final targetY = switch (fraction) {
    <= 0 => track.top - 40,
    >= 1 => track.bottom + 40,
    _ => track.top + track.height * fraction,
  };
  await gesture.moveTo(Offset(start.dx, targetY));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

MediaView _centerPhoto(WidgetTester tester, _Model model) {
  final center = tester.getRect(_scroll).center;
  final visible = model.media.where((item) {
    final card = find.byKey(Key('media-${item.key}'));
    return card.evaluate().isNotEmpty &&
        tester.getRect(card).overlaps(tester.getRect(_scroll));
  }).toList();
  visible.sort((left, right) {
    double distance(MediaView item) =>
        (tester.getCenter(find.byKey(Key('media-${item.key}'))) - center)
            .distanceSquared;
    return distance(left).compareTo(distance(right));
  });
  return visible.first;
}

String _fullDate(DateTime date) =>
    '${date.year}年${date.month}月${date.day}日 '
    '周${const ['一', '二', '三', '四', '五', '六', '日'][date.weekday - 1]}';

void main() {
  testWidgets(
    'mobile album reveals the handle while scrolling and fades after 3 seconds',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      expect(_opacity(tester), 0);
      final gesture = await tester.startGesture(tester.getCenter(_scroll));
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -380));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_opacity(tester), 1);
      expect(_thumb.hitTestable(), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2900));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 150));
      final fading = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const Key('album-fast-scroll-opacity')),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fading.opacity.value, greaterThan(0));
      expect(fading.opacity.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_thumb.hitTestable(), findsNothing);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'scrolling again restarts the visibility delay and dragging stays visible',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      await _scrollDown(tester);
      await tester.pump(const Duration(seconds: 2));
      await _scrollDown(tester, distance: 100);
      await tester.pump(const Duration(seconds: 2));
      expect(_opacity(tester), 1);

      final gesture = await tester.startGesture(tester.getCenter(_thumb));
      await tester.pump(const Duration(seconds: 5));
      expect(_opacity(tester), 1);
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(seconds: 5));
      expect(_opacity(tester), 1);
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'dragging the handle reaches both ends without opening or downloading media',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      await _scrollDown(tester);
      await _dragThumbTo(tester, 1);
      final position = _controller(tester).position;
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
      expect(find.byKey(Key('media-${model.media.last.key}')), findsOneWidget);
      await _dragThumbTo(tester, 0);
      expect(position.pixels, closeTo(position.minScrollExtent, 1));
      expect(find.byKey(Key('media-${model.media.first.key}')), findsOneWidget);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  for (final order in [
    MediaSortOrder.dateDescending,
    MediaSortOrder.nameAscending,
  ]) {
    testWidgets(
      '$order keeps one continuous thumb drag through changing section markers',
      (tester) async {
        final model = _Model();
        await model.setMediaSortOrder(order);
        await _show(tester, model);
        await _scrollDown(tester);
        final track = tester.getRect(
          find.byKey(const Key('album-fast-scroll-track')),
        );
        final thumb = tester.getRect(_thumb);
        final travel = track.height - thumb.height;
        final gesture = await tester.startGesture(thumb.center);
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump();
        for (final fraction in [.15, .3, .5, .7, .9, .65, .35, .1]) {
          final target = Offset(
            thumb.center.dx,
            track.top + travel * fraction + thumb.height / 2,
          );
          await gesture.moveTo(target);
          await tester.pump();
          final position = _controller(tester).position;
          expect(
            position.pixels,
            closeTo(position.maxScrollExtent * fraction, 1),
            reason: 'the same gesture must follow the finger at $fraction',
          );
          expect(tester.getCenter(_thumb).dy, closeTo(target.dy, 1));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(model.downloads, isEmpty);
        expect(find.byKey(const Key('media-preview-page')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: _mobilePlatforms,
    );

    testWidgets(
      '$order hides after releasing a thumb drag that changes section markers',
      (tester) async {
        final model = _Model();
        await model.setMediaSortOrder(order);
        await _show(tester, model);
        await _scrollDown(tester);
        await _dragThumbTo(tester, .5);
        expect(_opacity(tester), 1);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(_opacity(tester), 0);
        expect(_thumb.hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: _mobilePlatforms,
    );
  }

  for (final detailed in [false, true]) {
    testWidgets(
      '${detailed ? 'detailed' : 'compact'} dates follow the actual center image with large text',
      (tester) async {
        final model = _Model()..albumDetailedMode = detailed;
        await _show(tester, model, size: const Size(320, 900), textScale: 1.6);
        await _scrollDown(tester, distance: 600);
        final item = _centerPhoto(tester, model);
        expect(tester.widget<Text>(_date).data, _fullDate(item.modified));
        expect(
          tester.widget<Text>(_label).data,
          '${item.modified.year}年${item.modified.month}月',
        );
        final viewport = tester.getRect(_scroll);
        expect(viewport.contains(tester.getRect(_date).center), isTrue);
        expect(viewport.contains(tester.getRect(_thumb).center), isTrue);
        expect(tester.takeException(), isNull);
        expect(model.downloads, isEmpty);
      },
      variant: _mobilePlatforms,
    );
  }

  for (final order in [
    MediaSortOrder.nameAscending,
    MediaSortOrder.nameDescending,
  ]) {
    testWidgets(
      '$order shows uppercase letters and # for non-letter filenames',
      (tester) async {
        final model = _Model();
        await model.setMediaSortOrder(order);
        await _show(tester, model);
        await _scrollDown(tester);
        await _dragThumbTo(tester, .5);
        final item = _centerPhoto(tester, model);
        expect(_date, findsNothing);
        expect(tester.widget<Text>(_label).data, item.name[0].toUpperCase());
        expect(tester.widget<Text>(_label).data, matches(RegExp('^[A-Z]')));
        await _dragThumbTo(tester, 1);
        expect(tester.widget<Text>(_label).data, '#');
        await _dragThumbTo(tester, 0);
        expect(tester.widget<Text>(_label).data, '#');
        expect(model.downloads, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: _mobilePlatforms,
    );
  }

  testWidgets('lowercase ASCII names use uppercase section labels', (
    tester,
  ) async {
    final model = _Model();
    model.media
      ..clear()
      ..addAll(
        List.generate(160, (index) => _photo(index, name: 'apple-$index.jpg')),
      );
    await model.setMediaSortOrder(MediaSortOrder.nameAscending);
    await _show(tester, model);
    await _scrollDown(tester);
    await _dragThumbTo(tester, .5);
    expect(tester.widget<Text>(_label).data, 'A');
    expect(_date, findsNothing);
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: _mobilePlatforms);

  testWidgets(
    'changing order and returning to collections resets the scrollbar',
    (tester) async {
      final model = _Model();
      await _show(tester, model);
      final changeOrder = tester
          .widget<PopupMenuButton<MediaSortOrder>>(
            find.byKey(const Key('album-sort')),
          )
          .onSelected!;
      final goBack = tester
          .widget<TextButton>(find.byKey(const Key('back-to-collections')))
          .onPressed!;
      await _scrollDown(tester);
      await _dragThumbTo(tester, .6);
      expect(_controller(tester).offset, greaterThan(0));
      changeOrder(MediaSortOrder.dateAscending);
      await tester.pumpAndSettle();
      expect(_controller(tester).offset, 0);
      expect(_opacity(tester), 0);
      await _scrollDown(tester);
      goBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album-fast-scroll')), findsNothing);
      await tester.tap(find.byKey(const Key('collection-peer/travel')));
      await tester.pumpAndSettle();
      expect(model.selectedCollectionKey, 'peer/travel');
      expect(_controller(tester).offset, 0);
      expect(_opacity(tester), 0);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'short albums and the collection list do not display a fast-scroll handle',
    (tester) async {
      final model = _Model(count: 2);
      await _show(tester, model, size: const Size(390, 1100));
      await _scrollDown(tester, distance: 80);
      expect(_opacity(tester), 0);
      expect(_thumb.hitTestable(), findsNothing);
      await model.selectCollection(null);
      await tester.pumpAndSettle();
      await _scrollDown(tester, distance: 80);
      expect(find.byKey(const Key('album-fast-scroll')), findsNothing);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'a virtual album loads its distant end directly without old pagination',
    (tester) async {
      final model = _IndexedModel();
      await _show(tester, model);
      await _scrollDown(tester);
      await _dragThumbTo(tester, 1);
      expect(
        find.byKey(Key('media-${model.allItems.last.key}')),
        findsOneWidget,
      );
      expect(model.requests.any((range) => range.$1 > 1400), isTrue);
      expect(
        model.requests.every((range) => range.$2 - range.$1 < 200),
        isTrue,
      );
      expect(model.pageRequests, 0);
      expect(model.downloads, isEmpty);
      await _dragThumbTo(tester, 0);
      expect(find.byKey(const Key('media-peer/0')), findsOneWidget);
      expect(model.pageRequests, 0);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'a failed virtual range can be retried without downloading the original',
    (tester) async {
      final model = _IndexedModel();
      await _show(tester, model);
      await _scrollDown(tester);
      model.failRanges = true;
      await _dragThumbTo(tester, 1);
      final placeholder = find.byKey(const ValueKey('album-placeholder-1598'));
      expect(placeholder, findsOneWidget);
      expect(find.byTooltip('重试加载缩略图'), findsWidgets);
      model.failRanges = false;
      final retry = find.byTooltip('重试加载缩略图').hitTestable().first;
      final selectedPlaceholder = find.ancestor(
        of: retry,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'album-placeholder-',
              ),
        ),
      );
      final key = tester.widget(selectedPlaceholder).key! as ValueKey<String>;
      final index = key.value.substring('album-placeholder-'.length);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('media-peer/$index')), findsOneWidget);
      expect(model.rangeError, isNull);
      expect(model.pageRequests, 0);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  for (final size in [const Size(1024, 1366), const Size(390, 6000)]) {
    testWidgets(
      'a ${size.width}x${size.height} virtual range contains every on-screen tile',
      (tester) async {
        final model = _IndexedModel();
        await _show(tester, model, size: size);
        await _scrollDown(tester);
        await _dragThumbTo(tester, .5);
        final viewport = tester.getRect(_scroll);
        final placeholders = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'album-placeholder-',
              ),
        );
        for (final element in placeholders.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.overlaps(viewport), isFalse);
        }
        if (size.height < 6000) {
          expect(
            model.requests.every((range) => range.$2 - range.$1 < 200),
            isTrue,
          );
          expect(model.loaded.length, lessThanOrEqualTo(200));
        }
        expect(model.downloads, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: _mobilePlatforms,
    );
  }

  testWidgets(
    'selected saved media remains deletable after its virtual window is evicted',
    (tester) async {
      final model = _IndexedModel();
      final selected = model.allItems[1598];
      model.transfers[selected.key] = TransferView(
        progress: 1,
        item: selected,
        savedUri: 'content://saved/${selected.id}',
      );
      await _show(tester, model);
      await _scrollDown(tester);
      await _dragThumbTo(tester, 1);
      await tester.longPress(find.byKey(Key('media-${selected.key}')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await _dragThumbTo(tester, 0);
      expect(model.loaded.containsKey(1598), isFalse);
      expect(model.media.any((item) => item.key == selected.key), isFalse);
      await tester.tap(find.byKey(const Key('confirm-delete-local')));
      await tester.pumpAndSettle();
      expect(model.deletions, [selected.key]);
      expect(model.transfers, isEmpty);
      expect(model.downloads, isEmpty);
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: _mobilePlatforms,
  );

  testWidgets(
    'desktop collections keep their existing scroll controls',
    (tester) async {
      final model = _Model();
      await _show(tester, model, size: const Size(1000, 900));
      await _scrollDown(tester);
      expect(find.byKey(const Key('album-fast-scroll')), findsNothing);
      expect(_thumb, findsNothing);
      expect(_date, findsNothing);
      expect(_label, findsNothing);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  const captureDirectory = String.fromEnvironment(
    'TAMAYURA_FAST_SCROLL_SCREENSHOTS',
  );
  if (captureDirectory.isNotEmpty) {
    testWidgets('capture date and name fast-scroll overlays for visual review', (
      tester,
    ) async {
      final thumbnails = <Uint8List>[];
      await tester.runAsync(() async {
        const fontPath = String.fromEnvironment('TAMAYURA_SCREENSHOT_FONT');
        final font = ByteData.sublistView(await File(fontPath).readAsBytes());
        for (final family in ['Roboto', '.SF UI Text', '.SF UI Display']) {
          await (FontLoader(family)..addFont(Future.value(font))).load();
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
        // Generated landscape thumbnails give the overlays a varied background
        // without copying personal photos into the repository.
        for (final color in [
          Colors.teal,
          Colors.indigo,
          Colors.orange,
          Colors.blue,
          Colors.deepPurple,
          Colors.green,
        ]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 160, 160),
            Paint()..color = color.shade200,
          );
          canvas.drawCircle(
            const Offset(120, 38),
            21,
            Paint()..color = Colors.amber.shade100,
          );
          canvas.drawPath(
            Path()
              ..moveTo(0, 126)
              ..lineTo(48, 46)
              ..lineTo(111, 160)
              ..lineTo(0, 160)
              ..close(),
            Paint()..color = color.shade700,
          );
          canvas.drawPath(
            Path()
              ..moveTo(44, 160)
              ..lineTo(114, 78)
              ..lineTo(160, 132)
              ..lineTo(160, 160)
              ..close(),
            Paint()..color = color.shade500,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(160, 160);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          thumbnails.add(data!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
      });
      final model = _Model();
      for (var index = 0; index < model.media.length; index++) {
        final item = model.media[index];
        model.media[index] = MediaView(
          id: item.id,
          deviceId: item.deviceId,
          name: item.name,
          mimeType: item.mimeType,
          sharedFolderId: item.sharedFolderId,
          sharedFolderName: item.sharedFolderName,
          size: item.size,
          modified: item.modified,
          thumbnail: thumbnails[index % thumbnails.length],
        );
      }
      await _show(tester, model);
      for (final byName in [false, true]) {
        if (byName) {
          await model.setMediaSortOrder(MediaSortOrder.nameAscending);
          await tester.pumpAndSettle();
        }
        await _scrollDown(tester);
        await _dragThumbTo(tester, .45);
        final context = tester.element(_scroll);
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
        expect(_opacity(tester), 1);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('fast-scroll-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final kind = byName ? 'name' : 'date';
            final file = File('$captureDirectory/album-fast-scroll-$kind.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
