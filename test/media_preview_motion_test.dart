import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/media_preview.dart';

class _Model extends TamayuraModel {
  @override
  final List<DeviceView> devices = [];

  @override
  final Map<String, TransferView> transfers = {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected model access: ${invocation.memberName}');
}

Finder get _area => find.byKey(const Key('preview-gesture-area'));

double _offset(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const Key('preview-zoom-view'))).dy -
    tester.getTopLeft(_area).dy;

Future<void> _show(WidgetTester tester) async {
  final model = _Model();
  addTearDown(model.dispose);
  final item = MediaView(
    id: 'photo',
    deviceId: 'peer',
    name: 'photo.jpg',
    mimeType: 'image/jpeg',
    size: 1024,
    modified: DateTime(2026, 10, 21),
    thumbnail: Uint8List(0),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocale.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: AppLocale.current,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => MediaPreviewPage(model: model, item: item),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('preview tracks drag immediately and returns within 180 ms', (
    tester,
  ) async {
    await _show(tester);
    final gesture = await tester.startGesture(tester.getCenter(_area));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(_offset(tester), closeTo(40, .01));
    await gesture.up();
    await tester.pump();
    expect(_offset(tester), closeTo(40, .01));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_offset(tester), greaterThan(0));
    expect(_offset(tester), lessThan(40));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_offset(tester), closeTo(0, .01));
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new drag interrupts the return at its current position', (
    tester,
  ) async {
    await _show(tester);
    final gesture = await tester.startGesture(tester.getCenter(_area));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final returningOffset = _offset(tester);
    expect(returningOffset, greaterThan(0));
    expect(returningOffset, lessThan(40));

    final next = await tester.startGesture(tester.getCenter(_area));
    await tester.pump();
    expect(_offset(tester), closeTo(returningOffset, .01));
    await next.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(_offset(tester), closeTo(returningOffset + 20, .01));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_offset(tester), closeTo(returningOffset + 20, .01));
    await next.up();
    await tester.pumpAndSettle();
    expect(_offset(tester), closeTo(0, .01));
    expect(tester.takeException(), isNull);
  });

  for (final cancelled in [false, true]) {
    testWidgets(
      'a quick tap during return does not dismiss the preview (cancelled: $cancelled)',
      (tester) async {
        await _show(tester);
        final gesture = await tester.startGesture(tester.getCenter(_area));
        await gesture.moveBy(
          Offset(0, cancelled ? 160 : 100),
          timeStamp: const Duration(milliseconds: 200),
        );
        await tester.pump();
        if (cancelled) {
          await gesture.cancel(timeStamp: const Duration(milliseconds: 200));
        } else {
          await gesture.up(timeStamp: const Duration(milliseconds: 200));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        final returningOffset = _offset(tester);
        expect(returningOffset, greaterThan(cancelled ? 110 : 55));

        final tap = await tester.startGesture(tester.getCenter(_area));
        await tester.pump();
        expect(_offset(tester), closeTo(returningOffset, .01));
        await tap.up(timeStamp: const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
        expect(_offset(tester), closeTo(0, .01));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final features in [
    const FakeAccessibilityFeatures(disableAnimations: true),
    const FakeAccessibilityFeatures(accessibleNavigation: true),
  ]) {
    testWidgets(
      'reduced motion keeps drag and dismiss interactive: $features',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue = features;
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await _show(tester);
        final gesture = await tester.startGesture(tester.getCenter(_area));
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(_offset(tester), closeTo(40, .01));
        await gesture.up();
        await tester.pump();
        expect(_offset(tester), closeTo(0, .01));
        await tester.drag(_area, const Offset(0, 160));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('media-preview-page')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
