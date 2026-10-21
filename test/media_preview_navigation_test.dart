import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:animations/animations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/media_preview.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

MediaView _item(String id, {bool video = false, String? name}) => MediaView(
  id: id,
  deviceId: 'peer',
  name: name ?? '$id.${video ? 'mp4' : 'jpg'}',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  size: 1024,
  modified: DateTime(2026, 10, 21),
  thumbnail: Uint8List.fromList(_pixel),
);

class _Model extends TamayuraModel {
  _Model(this.media);

  @override
  final List<MediaView> media;

  @override
  final List<DeviceView> devices = [
    const DeviceView(id: 'peer', name: 'Camera', address: '', online: true),
  ];

  @override
  final Map<String, TransferView> transfers = {};

  @override
  String? get error => reportedError;

  final downloads = <String>[];
  final reads = <String>[];
  final opens = <String>[];
  final cancelled = <String>[];
  final pendingReads = <String, Completer<Uint8List?>>{};
  final currentChecks = <String, bool Function()>{};
  final previewBytes = <String, Uint8List>{};
  bool failDownload = false;
  String? reportedError;
  String? downloadError;

  @override
  Future<void> download(MediaView item) async {
    downloads.add(item.key);
    if (failDownload) throw StateError('Download unavailable');
    if (downloadError != null) {
      reportedError = downloadError;
      notifyListeners();
    }
  }

  @override
  Future<Uint8List?> loadPreview(
    MediaView item, {
    int maxDimension = 2560,
    bool Function()? isCurrent,
  }) async {
    reads.add(item.key);
    if (isCurrent != null) currentChecks[item.key] = isCurrent;
    return pendingReads[item.key]?.future ?? previewBytes[item.key] ?? _pixel;
  }

  @override
  Future<void> open(MediaView item) async => opens.add(item.key);

  @override
  Future<void> cancelDownload(String key) async => cancelled.add(key);

  void complete(MediaView item) {
    transfers[item.key] = TransferView(
      progress: 1,
      item: item,
      savedUri: 'content://saved/${item.id}',
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected model access: ${invocation.memberName}');
}

Finder get _area => find.byKey(const Key('preview-gesture-area'));
Finder get _next => find.byKey(const Key('preview-next'));
Finder get _previous => find.byKey(const Key('preview-previous'));
Finder get _clockwise => find.byKey(const Key('preview-rotate-clockwise'));
Finder get _counterclockwise =>
    find.byKey(const Key('preview-rotate-counterclockwise'));

int _turns(WidgetTester tester) => tester
    .widget<RotatedBox>(find.byKey(const Key('preview-rotation')))
    .quarterTurns;

Uint8List _imageBytes(Image image) =>
    ((image.image as ResizeImage).imageProvider as MemoryImage).bytes;

Future<void> _show(
  WidgetTester tester,
  _Model model, {
  int index = 0,
  bool sequence = true,
  Locale locale = const Locale('en'),
  Size size = const Size(800, 900),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(model.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocale.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => MediaPreviewPage(
                  model: model,
                  item: model.media[index],
                  sequence: sequence
                      ? MediaPreviewSequence.items(model.media)
                      : null,
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

Future<void> _tapNext(WidgetTester tester) async {
  await tester.tap(_next);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('interrupting an edge rebound preserves direction and position', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    await _show(tester, model);
    double offset() =>
        tester.getTopLeft(find.byKey(const Key('preview-rotation'))).dx -
        tester.getTopLeft(_area).dx;
    final edge = await tester.startGesture(tester.getCenter(_area));
    await edge.moveBy(const Offset(400, 0));
    await tester.pump();
    expect(offset(), closeTo(80, .01));
    await edge.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final returning = offset();
    final next = await tester.startGesture(tester.getCenter(_area));
    await next.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(offset(), closeTo(returning + 4, .01));
    await next.up();
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(model.downloads, isEmpty);
    expect(offset(), closeTo(0, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation works in both directions without changing files', (
    tester,
  ) async {
    final model = _Model([_item('photo')]);
    model.complete(model.media.single);
    await _show(tester, model);
    final image = _imageBytes(
      tester.widget<Image>(find.byKey(const ValueKey('full-preview'))),
    );
    expect(_turns(tester), 0);
    await tester.tap(_counterclockwise);
    await tester.pumpAndSettle();
    expect(_turns(tester), 3);
    await tester.tap(_clockwise);
    await tester.pumpAndSettle();
    expect(_turns(tester), 0);
    for (var i = 1; i <= 4; i++) {
      await tester.tap(_clockwise);
      await tester.pumpAndSettle();
      expect(_turns(tester), i % 4);
    }
    expect(
      _imageBytes(tester.widget<Image>(find.byKey(const Key('full-preview')))),
      same(image),
    );
    expect(model.reads, [model.media.single.key]);
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('buttons and horizontal swipes respect sequence boundaries', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('middle'), _item('last')]);
    await _show(tester, model);
    expect(tester.widget<IconButton>(_previous).onPressed, isNull);
    expect(tester.widget<IconButton>(_next).onPressed, isNotNull);
    await tester.drag(_area, const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(model.downloads, isEmpty);

    await tester.drag(_area, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('middle.jpg'), findsOneWidget);
    expect(model.downloads, [model.media[1].key]);
    await _tapNext(tester);
    expect(find.text('last.jpg'), findsOneWidget);
    expect(tester.widget<IconButton>(_next).onPressed, isNull);
    await tester.drag(_area, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('last.jpg'), findsOneWidget);
    expect(model.downloads, [model.media[1].key, model.media[2].key]);
    await tester.drag(_area, const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(find.text('middle.jpg'), findsOneWidget);
    await tester.tap(_previous);
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'visiting a new item downloads only that item and shows completion',
    (tester) async {
      final model = _Model([_item('first'), _item('second'), _item('third')]);
      await _show(tester, model);
      expect(model.downloads, isEmpty);
      await _tapNext(tester);
      expect(model.downloads, [model.media[1].key]);
      expect(find.byKey(const ValueKey('cached-preview')), findsOneWidget);
      model.complete(model.media[1]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('full-preview')), findsOneWidget);
      expect(model.reads, [model.media[1].key]);
      await tester.tap(_previous);
      await tester.pumpAndSettle();
      await _tapNext(tester);
      expect(model.downloads, [model.media[1].key, model.media[0].key]);
      expect(model.downloads, isNot(contains(model.media[2].key)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved and active transfers are reused when browsing', (
    tester,
  ) async {
    final model = _Model([
      _item('first'),
      _item('saved'),
      _item('queued'),
      _item('downloading'),
      _item('saving'),
    ]);
    model.complete(model.media[1]);
    for (var index = 2; index < model.media.length; index++) {
      final item = model.media[index];
      model.transfers[item.key] = TransferView(
        progress: .5,
        item: item,
        status: TransferStatus.values[index - 2],
      );
    }
    await _show(tester, model);
    await _tapNext(tester);
    expect(find.byKey(const Key('full-preview')), findsOneWidget);
    for (var index = 2; index < model.media.length; index++) {
      await tester.tap(_next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(model.media[index].name), findsOneWidget);
    }
    expect(model.downloads, isEmpty);
    await tester.tap(find.byKey(const Key('close-preview')));
    await tester.pumpAndSettle();
    expect(model.cancelled, isEmpty);
    expect(model.transfers.values.where((item) => item.running), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  for (final status in [
    TransferStatus.failed,
    TransferStatus.cancelled,
    TransferStatus.discarded,
  ]) {
    testWidgets(
      'visiting $status transfer automatically retries the original',
      (tester) async {
        final model = _Model([_item('first'), _item('retry')]);
        final item = model.media[1];
        model.transfers[item.key] = TransferView(
          progress: .4,
          item: item,
          status: status,
        );
        await _show(tester, model);
        await _tapNext(tester);
        expect(model.downloads, [item.key]);
        expect(find.text(item.name), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a failed automatic download remains visible and retryable', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('offline')]);
    model.failDownload = true;
    await _show(tester, model);
    await _tapNext(tester);
    expect(find.text('offline.jpg'), findsOneWidget);
    expect(model.downloads, [model.media[1].key]);
    expect(find.byKey(Key('retry-${model.media[1].key}')), findsOneWidget);
    expect(
      find.text(lookupAppLocalizations(const Locale('en')).previewActionFailed),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    model.failDownload = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('retry-${model.media[1].key}')));
    await tester.pumpAndSettle();
    expect(model.downloads, [model.media[1].key, model.media[1].key]);
  });

  testWidgets('automatic download shows model errors without a transfer row', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    model.downloadError = 'Select a receiving folder before downloading.';
    await _show(tester, model);
    await _tapNext(tester);
    expect(model.downloads, [model.media[1].key]);
    expect(model.transfers, isEmpty);
    expect(find.text(model.downloadError!), findsOneWidget);
    expect(find.byKey(Key('retry-${model.media[1].key}')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visiting another media does not repeat an old model error', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    model.reportedError = 'An earlier synchronization failed.';
    await _show(tester, model);
    await _tapNext(tester);
    expect(model.downloads, [model.media[1].key]);
    expect(find.text(model.reportedError!), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late original reads cannot replace the newly selected image', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    final first = model.media[0];
    final second = model.media[1];
    final delayed = Completer<Uint8List?>();
    model.pendingReads[first.key] = delayed;
    final secondBytes = Uint8List.fromList(_pixel);
    model.previewBytes[second.key] = secondBytes;
    model.complete(first);
    model.complete(second);
    await _show(tester, model);
    expect(model.currentChecks[first.key]!(), isTrue);
    await _tapNext(tester);
    expect(model.currentChecks[first.key]!(), isFalse);
    expect(model.currentChecks[second.key]!(), isTrue);
    delayed.complete(Uint8List.fromList(_pixel));
    await tester.pumpAndSettle();
    expect(find.text(second.name), findsOneWidget);
    expect(
      _imageBytes(tester.widget<Image>(find.byKey(const Key('full-preview')))),
      same(secondBytes),
    );
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late read failure cannot add an error to the new item', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    final delayed = Completer<Uint8List?>();
    model.pendingReads[model.media[0].key] = delayed;
    model.complete(model.media[0]);
    model.complete(model.media[1]);
    await _show(tester, model);
    await _tapNext(tester);
    delayed.completeError(StateError('Old file unreadable'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('full-preview')), findsOneWidget);
    expect(find.text('second.jpg'), findsOneWidget);
    expect(
      find.text(lookupAppLocalizations(const Locale('en')).previewReadFailed),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'zoom blocks swipe navigation and changing item resets transforms',
    (tester) async {
      final model = _Model([_item('first'), _item('second')]);
      await _show(tester, model);
      await tester.tap(_clockwise);
      await tester.tap(find.byKey(const Key('preview-zoom')));
      await tester.pumpAndSettle();
      expect(_turns(tester), 1);
      await tester.drag(_area, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(find.text('first.jpg'), findsOneWidget);
      expect(model.downloads, isEmpty);
      await _tapNext(tester);
      final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const Key('preview-zoom-view')),
      );
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
      expect(_turns(tester), 0);
      await tester.drag(_area, const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.text('first.jpg'), findsOneWidget);
      expect(_turns(tester), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('multiple pointers and cancelled gestures never navigate', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    await _show(tester, model);
    final center = tester.getCenter(_area);
    final first = await tester.startGesture(center, pointer: 1);
    final second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-180, 0));
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(model.downloads, isEmpty);
    // Reset any pinch scale before exercising cancellation independently.
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const Key('preview-zoom-view')),
    );
    viewer.transformationController!.value = Matrix4.identity();
    await tester.pump();
    final cancelled = await tester.startGesture(center);
    await cancelled.moveBy(const Offset(-180, 0));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(model.downloads, isEmpty);
    await tester.drag(_area, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('second.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vertical dismissal still closes without downloading a neighbor',
    (tester) async {
      final model = _Model([_item('first'), _item('second')]);
      await _show(tester, model);
      await tester.drag(_area, const Offset(30, 160));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-preview-page')), findsNothing);
      expect(model.downloads, isEmpty);
      expect(model.cancelled, isEmpty);
    },
  );

  testWidgets('left swipe during vertical return uses the new gesture axis', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    await _show(tester, model);
    final initial = await tester.startGesture(tester.getCenter(_area));
    await initial.moveBy(
      const Offset(0, 100),
      timeStamp: const Duration(milliseconds: 200),
    );
    await initial.up(timeStamp: const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final returningOffset =
        tester.getTopLeft(find.byKey(const Key('preview-zoom-view'))).dy -
        tester.getTopLeft(_area).dy;
    expect(returningOffset, greaterThan(55));

    final next = await tester.startGesture(tester.getCenter(_area));
    await next.moveBy(
      const Offset(-15, 0),
      timeStamp: const Duration(milliseconds: 20),
    );
    await tester.pump();
    await next.moveBy(
      const Offset(-165, 0),
      timeStamp: const Duration(milliseconds: 200),
    );
    await next.up(timeStamp: const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('second.jpg'), findsOneWidget);
    expect(model.downloads, [model.media[1].key]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('downward swipe during horizontal return can dismiss the page', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    await _show(tester, model);
    final initial = await tester.startGesture(tester.getCenter(_area));
    await initial.moveBy(
      const Offset(-100, 0),
      timeStamp: const Duration(milliseconds: 200),
    );
    await initial.up(timeStamp: const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('first.jpg'), findsOneWidget);
    final imageLeft = tester
        .getTopLeft(find.byKey(const Key('preview-rotation')))
        .dx;
    expect(imageLeft - tester.getTopLeft(_area).dx, lessThan(-55));

    final next = await tester.startGesture(tester.getCenter(_area));
    await next.moveBy(
      const Offset(0, 15),
      timeStamp: const Duration(milliseconds: 20),
    );
    await tester.pump();
    await next.moveBy(
      const Offset(0, 145),
      timeStamp: const Duration(milliseconds: 200),
    );
    await next.up(timeStamp: const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsNothing);
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid navigation keeps only the latest media active', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second'), _item('third')]);
    await _show(tester, model);
    await tester.tap(_next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_previous);
    await tester.pumpAndSettle();
    expect(find.text('second.jpg'), findsOneWidget);
    expect(find.byKey(const Key('cached-preview')), findsOneWidget);
    expect(
      _imageBytes(
        tester.widget<Image>(find.byKey(const Key('cached-preview'))),
      ),
      same(model.media[1].thumbnail),
    );
    expect(model.downloads, [
      model.media[1].key,
      model.media[2].key,
      model.media[1].key,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation has a directional slide and fade before settling', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('second')]);
    await _show(tester, model);
    await tester.tap(_next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    final transitions = tester.widgetList<SharedAxisTransition>(
      find.descendant(of: _area, matching: find.byType(SharedAxisTransition)),
    );
    expect(transitions.length, greaterThanOrEqualTo(2));
    expect(
      transitions.every(
        (transition) =>
            transition.transitionType == SharedAxisTransitionType.horizontal,
      ),
      isTrue,
    );
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(of: _area, matching: find.byType(FadeTransition)),
    );
    expect(
      fades.any((fade) => fade.opacity.value > 0 && fade.opacity.value < 1),
      isTrue,
    );
    final translations = tester.widgetList<Transform>(
      find.descendant(of: _area, matching: find.byType(Transform)),
    );
    expect(
      translations.any((transform) => transform.transform.entry(0, 3) != 0),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 140));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cached-preview')), findsOneWidget);
    expect(find.text('second.jpg'), findsOneWidget);
    await tester.tap(_previous);
    await tester.pump();
    expect(
      tester
          .widget<PageTransitionSwitcher>(find.byType(PageTransitionSwitcher))
          .reverse,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.text('first.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final features in [
    const FakeAccessibilityFeatures(disableAnimations: true),
    const FakeAccessibilityFeatures(accessibleNavigation: true),
  ]) {
    testWidgets('reduced motion switches media immediately: $features', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = features;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final model = _Model([_item('first'), _item('second')]);
      await _show(tester, model);
      await tester.tap(_next);
      await tester.pump();
      expect(find.text('second.jpg'), findsOneWidget);
      expect(find.byKey(const Key('cached-preview')), findsOneWidget);
      final fades = tester.widgetList<FadeTransition>(
        find.descendant(of: _area, matching: find.byType(FadeTransition)),
      );
      expect(
        fades.any((fade) => fade.opacity.value > 0 && fade.opacity.value < 1),
        isFalse,
      );
      expect(model.downloads, [model.media[1].key]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('videos keep external playback and do not offer image rotation', (
    tester,
  ) async {
    final model = _Model([_item('first'), _item('clip', video: true)]);
    model.complete(model.media[1]);
    await _show(tester, model);
    await _tapNext(tester);
    expect(_clockwise, findsNothing);
    expect(_counterclockwise, findsNothing);
    expect(find.byKey(const Key('cached-preview')), findsOneWidget);
    expect(find.byKey(const Key('full-preview')), findsNothing);
    expect(model.reads, isEmpty);
    await tester.tap(find.byKey(Key('open-${model.media[1].key}')));
    await tester.pumpAndSettle();
    expect(model.opens, [model.media[1].key]);
    await tester.tap(_previous);
    await tester.pumpAndSettle();
    expect(_clockwise, findsOneWidget);
    expect(_turns(tester), 0);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['zh', 'ja', 'en']) {
    testWidgets('preview controls fit narrow large-text screens in $language', (
      tester,
    ) async {
      final model = _Model([
        _item(
          'first',
          name: '${List.filled(12, 'long-photo-name').join()}.jpg',
        ),
        _item('second'),
      ]);
      model.complete(model.media[0]);
      model.complete(model.media[1]);
      await _show(
        tester,
        model,
        locale: Locale(language),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_area).height, greaterThan(100));
      expect(_clockwise.hitTestable(), findsOneWidget);
      expect(_counterclockwise.hitTestable(), findsOneWidget);
      expect(_next.hitTestable(), findsOneWidget);
      final l10n = lookupAppLocalizations(Locale(language));
      expect(
        tester.widget<IconButton>(_clockwise).tooltip,
        l10n.previewRotateClockwise,
      );
      expect(
        tester.widget<IconButton>(_counterclockwise).tooltip,
        l10n.previewRotateCounterclockwise,
      );
      expect(tester.widget<IconButton>(_next).tooltip, l10n.previewNext);
      await tester.tap(_clockwise);
      await tester.pumpAndSettle();
      expect(_turns(tester), 1);
      await _tapNext(tester);
      expect(find.text('second.jpg'), findsOneWidget);
      expect(_previous.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a standalone preview stays usable without a sequence', (
    tester,
  ) async {
    final model = _Model([_item('single')]);
    await _show(tester, model, sequence: false);
    expect(_next, findsNothing);
    expect(_previous, findsNothing);
    await tester.tap(_clockwise);
    await tester.pumpAndSettle();
    expect(_turns(tester), 1);
    await tester.drag(_area, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('single.jpg'), findsOneWidget);
    expect(model.downloads, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
