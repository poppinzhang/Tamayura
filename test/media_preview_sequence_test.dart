import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/media_preview.dart';

MediaView _item(String id, {String deviceId = 'camera'}) => MediaView(
  id: id,
  deviceId: deviceId,
  name: '$deviceId-$id.jpg',
  mimeType: 'image/jpeg',
  size: 1024,
  modified: DateTime.utc(2026, 10, 21),
  thumbnail: Uint8List(0),
);

MediaScrollEntry _entry(MediaView item) => MediaScrollEntry(
  id: item.id,
  deviceId: item.deviceId,
  name: item.name,
  modified: item.modified,
);

class _SequenceModel extends TamayuraModel {
  _SequenceModel(List<MediaView> items)
    : media = [items.first],
      mediaScrollEntries = items.map(_entry).toList(),
      catalog = {for (final item in items) item.key: item};

  @override
  List<MediaView> media;

  @override
  List<MediaScrollEntry> mediaScrollEntries;

  final Map<String, MediaView> catalog;
  final resolvedKeys = <String>[];
  final downloads = <String>[];
  final pending = <String, Completer<MediaView?>>{};

  @override
  final List<DeviceView> devices = [
    const DeviceView(id: 'camera', name: 'Camera', address: '', online: true),
  ];

  @override
  final Map<String, TransferView> transfers = {};

  @override
  String? get error => null;

  Completer<MediaView?> delay(MediaView item) =>
      pending[item.key] = Completer<MediaView?>();

  @override
  Future<MediaView?> resolvePreviewMedia(
    String deviceId,
    String mediaId,
  ) async {
    final key = '$deviceId/$mediaId';
    resolvedKeys.add(key);
    return pending[key]?.future ?? catalog[key];
  }

  @override
  Future<void> download(MediaView item) async => downloads.add(item.key);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected model access: ${invocation.memberName}');
}

Finder get _next => find.byKey(const Key('preview-next'));
Finder get _position => find.byKey(const Key('preview-position'));
Finder get _loading => find.byKey(const Key('preview-loading-media'));

Future<void> _show(WidgetTester tester, _SequenceModel model) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(model.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocale.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => MediaPreviewPage(
                  model: model,
                  item: model.media.first,
                  sequence: MediaPreviewSequence.album(model),
                ),
              ),
            ),
            child: const Text('Open preview'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open preview'));
  await tester.pumpAndSettle();
}

Future<void> _requestNext(WidgetTester tester) async {
  await tester.tap(_next);
  // Pending metadata keeps the progress animation running; wait only a frame.
  await tester.pump();
}

void main() {
  test(
    'album uses the complete lightweight index and resolves by identity',
    () async {
      final first = _item('photo-0');
      final sameIdOtherDevice = _item('photo-0', deviceId: 'phone');
      final last = _item('photo-2047', deviceId: 'phone');
      final model = _SequenceModel([first, sameIdOtherDevice, last]);
      addTearDown(model.dispose);
      model.mediaScrollEntries = [
        for (var index = 0; index < 4096; index++)
          MediaScrollEntry(
            id: 'photo-${index % 2048}',
            deviceId: index < 2048 ? 'camera' : 'phone',
            name: 'photo-$index.jpg',
            modified: DateTime.utc(2026, 10, 21),
          ),
      ];

      final sequence = MediaPreviewSequence.album(model);
      expect(sequence.length, 4096);
      expect(model.media, [first]);
      expect(sequence.indexOf(first), 0);
      expect(sequence.indexOf(sameIdOtherDevice), 2048);
      expect(sequence.indexOf(last), 4095);
      expect(model.resolvedKeys, isEmpty);

      expect(await sequence.resolve(model, 4095), same(last));
      expect(await sequence.resolve(model, 2048), same(sameIdOtherDevice));
      expect(await sequence.resolve(model, 0), same(first));
      expect(model.resolvedKeys, [last.key, sameIdOtherDevice.key, first.key]);
      expect(model.media, [first]);
      expect(model.mediaScrollEntries, hasLength(4096));
      expect(model.downloads, isEmpty);
    },
  );

  test(
    'album order remains a snapshot after the live index is reordered',
    () async {
      final items = [_item('first'), _item('second'), _item('third')];
      final model = _SequenceModel(items);
      addTearDown(model.dispose);
      final sequence = MediaPreviewSequence.album(model);

      model.mediaScrollEntries
        ..clear()
        ..addAll(items.reversed.map(_entry));
      model.media = [items.last];

      expect(sequence.length, items.length);
      for (var index = 0; index < items.length; index++) {
        expect(sequence.indexOf(items[index]), index);
        expect(await sequence.resolve(model, index), same(items[index]));
      }
      expect(model.resolvedKeys, items.map((item) => item.key).toList());
      expect(model.mediaScrollEntries.first.key, items.last.key);
      expect(model.media, [items.last]);
    },
  );

  test(
    'album without a lightweight index snapshots the available media',
    () async {
      final items = [_item('first'), _item('second')];
      final model = _SequenceModel(items)
        ..media = List.of(items)
        ..mediaScrollEntries = [];
      addTearDown(model.dispose);
      final sequence = MediaPreviewSequence.album(model);
      model.media.clear();

      expect(sequence.length, 2);
      expect(await sequence.resolve(model, 0), same(items[0]));
      expect(await sequence.resolve(model, 1), same(items[1]));
      expect(model.resolvedKeys, isEmpty);
    },
  );

  testWidgets(
    'rapid next requests show and download only the final resolved item',
    (tester) async {
      final items = [_item('first'), _item('second'), _item('third')];
      final model = _SequenceModel(items);
      final second = model.delay(items[1]);
      final third = model.delay(items[2]);
      await _show(tester, model);

      await _requestNext(tester);
      await _requestNext(tester);
      expect(model.resolvedKeys, [items[1].key, items[2].key]);
      expect(find.text(items[0].name), findsOneWidget);
      expect(tester.widget<Text>(_position).data, '1 of 3');
      expect(_loading, findsOneWidget);
      expect(model.downloads, isEmpty);

      third.complete(items[2]);
      await tester.pumpAndSettle();
      expect(find.text(items[2].name), findsOneWidget);
      expect(tester.widget<Text>(_position).data, '3 of 3');
      expect(_loading, findsNothing);
      expect(model.downloads, [items[2].key]);

      second.complete(items[1]);
      await tester.pumpAndSettle();
      expect(find.text(items[2].name), findsOneWidget);
      expect(find.text(items[1].name), findsNothing);
      expect(model.downloads, [items[2].key]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a superseded resolver failure never replaces or warns on the final item',
    (tester) async {
      final items = [_item('first'), _item('second'), _item('third')];
      final model = _SequenceModel(items);
      final second = model.delay(items[1]);
      final third = model.delay(items[2]);
      await _show(tester, model);
      await _requestNext(tester);
      await _requestNext(tester);

      third.complete(items[2]);
      await tester.pumpAndSettle();
      second.completeError(StateError('Superseded metadata unavailable'));
      await tester.pumpAndSettle();

      expect(find.text(items[2].name), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<Text>(_position).data, '3 of 3');
      expect(model.downloads, [items[2].key]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing during metadata resolution never starts a download', (
    tester,
  ) async {
    final items = [_item('first'), _item('second')];
    final model = _SequenceModel(items);
    final second = model.delay(items[1]);
    await _show(tester, model);
    await _requestNext(tester);

    await tester.tap(find.byKey(const Key('close-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsNothing);
    second.complete(items[1]);
    await tester.pumpAndSettle();

    expect(find.text('Open preview'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'metadata resolving during the closing transition never downloads',
    (tester) async {
      final items = [_item('first'), _item('second')];
      final model = _SequenceModel(items);
      final second = model.delay(items[1]);
      await _show(tester, model);
      await _requestNext(tester);

      await tester.tap(find.byKey(const Key('close-preview')));
      await tester.pump();
      // The route is still mounted while its exit transition is running.
      expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
      second.complete(items[1]);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(find.text('Open preview'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(model.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final missing in [false, true]) {
    testWidgets(
      'a ${missing ? 'missing' : 'failed'} current resolution preserves the item and allows retry',
      (tester) async {
        final items = [_item('first'), _item('second')];
        final model = _SequenceModel(items);
        final second = model.delay(items[1]);
        await _show(tester, model);
        await _requestNext(tester);
        if (missing) {
          second.complete(null);
        } else {
          second.completeError(StateError('Metadata temporarily unavailable'));
        }
        await tester.pumpAndSettle();

        expect(find.text(items[0].name), findsOneWidget);
        expect(tester.widget<Text>(_position).data, '1 of 2');
        expect(_loading, findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(tester.widget<IconButton>(_next).onPressed, isNotNull);
        expect(model.downloads, isEmpty);

        model.pending.remove(items[1].key);
        await _requestNext(tester);
        await tester.pumpAndSettle();
        expect(find.text(items[1].name), findsOneWidget);
        expect(tester.widget<Text>(_position).data, '2 of 2');
        expect(model.resolvedKeys, [items[1].key, items[1].key]);
        expect(model.downloads, [items[1].key]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
