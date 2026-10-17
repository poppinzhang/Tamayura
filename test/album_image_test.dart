import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/album_image.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
const _placeholderKey = Key('album-image-placeholder');

MediaView _item({
  String id = 'photo',
  bool video = false,
  Uint8List? thumbnail,
}) => MediaView(
  id: id,
  deviceId: 'peer',
  name: video ? '$id.mp4' : '$id.png',
  mimeType: video ? 'video/mp4' : 'image/png',
  size: 100,
  modified: DateTime(2026, 10, 17),
  thumbnail: thumbnail ?? _png,
);

class _PreviewRequest {
  _PreviewRequest(this.item, this.maxDimension, this.isCurrent);

  final MediaView item;
  final int maxDimension;
  final bool Function()? isCurrent;
  final result = Completer<Uint8List?>();
}

class _Model extends TamayuraModel {
  @override
  final Map<String, TransferView> transfers = {};
  final requests = <_PreviewRequest>[];
  bool get listening => hasListeners;

  void save(MediaView item, {String uri = 'content://saved/photo'}) {
    transfers[item.key] = TransferView(progress: 1, item: item, savedUri: uri);
    notifyListeners();
  }

  void remove(MediaView item) {
    transfers.remove(item.key);
    notifyListeners();
  }

  void changed() => notifyListeners();

  @override
  Future<Uint8List?> loadPreview(
    MediaView item, {
    int maxDimension = 2560,
    bool Function()? isCurrent,
  }) {
    final request = _PreviewRequest(item, maxDimension, isCurrent);
    requests.add(request);
    return request.result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _local(MediaView item) =>
    find.byKey(ValueKey('local-album-image-${item.key}'));
Finder _cached(MediaView item) =>
    find.byKey(ValueKey('cached-album-image-${item.key}'));

Future<void> _show(WidgetTester tester, _Model model, MediaView item) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 160,
        height: 160,
        child: AlbumImage(
          model: model,
          item: item,
          placeholder: const Icon(Icons.image, key: _placeholderKey),
        ),
      ),
    ),
  );
}

Uint8List _bytes(WidgetTester tester, Finder finder) {
  final image = tester.widget<Image>(finder);
  final provider = image.image;
  final memory = provider is ResizeImage ? provider.imageProvider : provider;
  return (memory as MemoryImage).bytes;
}

// Await the real codec so corrupt-byte tests exercise Image.errorBuilder.
Future<void> _decode(WidgetTester tester, Finder finder) async {
  final provider = tester.widget<Image>(finder).image;
  await tester.runAsync(() async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final decoded = Completer<void>();
    final listener = ImageStreamListener(
      (_, _) => decoded.complete(),
      onError: (Object _, StackTrace? _) => decoded.complete(),
    );
    stream.addListener(listener);
    await decoded.future;
    stream.removeListener(listener);
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unsaved photos and saved videos keep their cached thumbnails', (
    tester,
  ) async {
    final model = _Model();
    final photo = _item();
    await _show(tester, model, photo);
    expect(_cached(photo), findsOneWidget);
    expect(_bytes(tester, _cached(photo)), same(photo.thumbnail));
    expect(model.requests, isEmpty);

    final video = _item(id: 'video', video: true);
    model.save(video);
    await _show(tester, model, video);
    expect(_cached(video), findsOneWidget);
    expect(_local(video), findsNothing);
    expect(model.requests, isEmpty);
  });

  testWidgets(
    'saved photos show thumbnail while reading then bounded local image',
    (tester) async {
      final item = _item();
      final model = _Model()..save(item);
      final localBytes = Uint8List.fromList(_png);
      await _show(tester, model, item);
      expect(_cached(item), findsOneWidget);
      expect(model.requests, hasLength(1));
      expect(model.requests.single.item, same(item));
      expect(model.requests.single.maxDimension, 1024);

      model.requests.single.result.complete(localBytes);
      await tester.pumpAndSettle();
      expect(_local(item), findsOneWidget);
      expect(_cached(item), findsNothing);
      expect(_bytes(tester, _local(item)), same(localBytes));
      final provider = tester.widget<Image>(_local(item)).image as ResizeImage;
      expect(provider.width, 1024);
      expect(provider.height, 1024);
      expect(provider.policy, ResizeImagePolicy.fit);
      await _decode(tester, _local(item));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failure in ['missing', 'empty', 'oversized', 'exception']) {
    testWidgets('$failure local image falls back to cached thumbnail', (
      tester,
    ) async {
      final item = _item();
      final model = _Model()..save(item);
      await _show(tester, model, item);
      final result = model.requests.single.result;
      switch (failure) {
        case 'missing':
          result.complete(null);
        case 'empty':
          result.complete(Uint8List(0));
        case 'oversized':
          result.complete(Uint8List(8 * 1024 * 1024 + 1));
        case 'exception':
          result.completeError(StateError('saved file unavailable'));
      }
      await tester.pumpAndSettle();
      expect(_local(item), findsNothing);
      expect(_cached(item), findsOneWidget);
      expect(_bytes(tester, _cached(item)), same(item.thumbnail));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('corrupt local image decodes to the cached thumbnail fallback', (
    tester,
  ) async {
    final item = _item();
    final model = _Model()..save(item);
    await _show(tester, model, item);
    model.requests.single.result.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pumpAndSettle();
    await _decode(tester, _local(item));
    expect(_cached(item), findsOneWidget);
    await _decode(tester, _cached(item));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byKey(_placeholderKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty or corrupt thumbnail displays the placeholder', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model, _item(thumbnail: Uint8List(0)));
    expect(find.byKey(_placeholderKey), findsOneWidget);
    final corrupt = _item(thumbnail: Uint8List.fromList([4, 5, 6]));
    await _show(tester, model, corrupt);
    await _decode(tester, _cached(corrupt));
    expect(find.byKey(_placeholderKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download completion loads once and URI changes reload', (
    tester,
  ) async {
    final item = _item();
    final model = _Model();
    await _show(tester, model, item);
    model.save(item);
    await tester.pump();
    expect(model.requests, hasLength(1));
    model.changed();
    await tester.pump();
    expect(model.requests, hasLength(1));
    model.requests.first.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();

    model.changed();
    await tester.pump();
    expect(model.requests, hasLength(1));
    model.save(item, uri: 'content://saved/replacement');
    await tester.pump();
    expect(_cached(item), findsOneWidget);
    expect(_local(item), findsNothing);
    expect(model.requests, hasLength(2));
    final replacement = Uint8List.fromList(_png);
    model.requests.last.result.complete(replacement);
    await tester.pumpAndSettle();
    expect(_bytes(tester, _local(item)), same(replacement));
  });

  testWidgets('deleting a downloaded file immediately restores its thumbnail', (
    tester,
  ) async {
    final item = _item();
    final model = _Model()..save(item);
    await _show(tester, model, item);
    model.requests.single.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();
    expect(_local(item), findsOneWidget);

    model.remove(item);
    await tester.pump();
    expect(_local(item), findsNothing);
    expect(_cached(item), findsOneWidget);
    expect(model.requests, hasLength(1));
    expect(model.requests.single.isCurrent!(), isFalse);
  });

  testWidgets('deleting during a read ignores its late local image', (
    tester,
  ) async {
    final item = _item();
    final model = _Model()..save(item);
    await _show(tester, model, item);
    model.remove(item);
    await tester.pump();
    expect(model.requests.single.isCurrent!(), isFalse);
    model.requests.single.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();
    expect(_local(item), findsNothing);
    expect(_cached(item), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a previous URI cannot overwrite a newer local image', (
    tester,
  ) async {
    final item = _item();
    final model = _Model()..save(item);
    await _show(tester, model, item);
    model.save(item, uri: 'content://saved/replacement');
    await tester.pump();
    expect(model.requests.first.isCurrent!(), isFalse);
    expect(model.requests.last.isCurrent!(), isTrue);
    final replacement = Uint8List.fromList(_png);
    model.requests.last.result.complete(replacement);
    await tester.pumpAndSettle();
    model.requests.first.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();
    expect(_bytes(tester, _local(item)), same(replacement));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching media ignores the previous media read', (
    tester,
  ) async {
    final first = _item(id: 'first');
    final second = _item(id: 'second');
    final model = _Model()
      ..save(first)
      ..save(second);
    await _show(tester, model, first);
    await _show(tester, model, second);
    expect(model.requests, hasLength(2));
    expect(model.requests.first.isCurrent!(), isFalse);
    expect(model.requests.last.isCurrent!(), isTrue);
    model.requests.first.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();
    expect(_local(second), findsNothing);
    expect(_cached(second), findsOneWidget);
    final current = Uint8List.fromList(_png);
    model.requests.last.result.complete(current);
    await tester.pumpAndSettle();
    expect(_bytes(tester, _local(second)), same(current));
  });

  testWidgets(
    'switching models detaches old notifications and ignores old read',
    (tester) async {
      final item = _item();
      final oldModel = _Model()..save(item);
      final newModel = _Model()..save(item);
      await _show(tester, oldModel, item);
      await _show(tester, newModel, item);
      expect(oldModel.listening, isFalse);
      expect(newModel.listening, isTrue);
      expect(oldModel.requests.single.isCurrent!(), isFalse);
      expect(newModel.requests.single.isCurrent!(), isTrue);
      oldModel.requests.single.result.complete(Uint8List.fromList(_png));
      oldModel.save(item, uri: 'content://saved/obsolete');
      await tester.pumpAndSettle();
      expect(_local(item), findsNothing);
      expect(_cached(item), findsOneWidget);
      expect(newModel.requests, hasLength(1));
      final current = Uint8List.fromList(_png);
      newModel.requests.single.result.complete(current);
      await tester.pumpAndSettle();
      expect(_bytes(tester, _local(item)), same(current));
    },
  );

  testWidgets(
    'disposing detaches the model and ignores pending read completion',
    (tester) async {
      final item = _item();
      final model = _Model()..save(item);
      await _show(tester, model, item);
      await tester.pumpWidget(const SizedBox());
      expect(model.listening, isFalse);
      expect(model.requests.single.isCurrent!(), isFalse);
      model.requests.single.result.complete(Uint8List.fromList(_png));
      model.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resuming rechecks local files removed outside the app', (
    tester,
  ) async {
    final item = _item();
    final model = _Model()..save(item);
    await _show(tester, model, item);
    model.requests.single.result.complete(Uint8List.fromList(_png));
    await tester.pumpAndSettle();
    expect(_local(item), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(model.requests, hasLength(2));
    expect(model.requests.first.isCurrent!(), isFalse);
    expect(model.requests.last.isCurrent!(), isTrue);
    model.requests.last.result.complete(null);
    await tester.pumpAndSettle();
    expect(_local(item), findsNothing);
    expect(_cached(item), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
