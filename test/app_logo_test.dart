import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/app_licenses.dart';
import 'package:tamayura/ui/app_logo.dart';
import 'package:tamayura/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both palettes bundle readable assets at 1x, 2x and 4x', () async {
    for (final background in ['black', 'white']) {
      final asset = AssetImage('assets/branding/hibiki/hibiki-$background.png');
      for (final scale in [1.0, 2.0, 4.0]) {
        final key = await asset.obtainKey(
          ImageConfiguration(devicePixelRatio: scale),
        );
        expect(key.scale, scale);
        final data = await rootBundle.load(key.name);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 64 * scale);
        expect(frame.image.height, frame.image.width);
        frame.image.dispose();
        codec.dispose();
      }
    }
  });

  for (final size in [22.4, 51.2]) {
    testWidgets(
      '$size logo follows live theme with rounded transparent corners',
      (tester) async {
        const captureKey = Key('logo-capture');
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;

        Future<void> show(ThemeMode mode) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: mode,
              home: Center(
                child: RepaintBoundary(
                  key: captureKey,
                  child: AppLogo(size: size),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> check(Brightness brightness) async {
          final logo = find.byType(AppLogo);
          final widget = tester.widget<Image>(
            find.descendant(of: logo, matching: find.byType(Image)),
          );
          final backgroundName = brightness == Brightness.light
              ? 'black'
              : 'white';
          expect(
            (widget.image as AssetImage).assetName,
            'assets/branding/hibiki/hibiki-$backgroundName.png',
          );
          expect(tester.getSize(logo), Size.square(size));
          await tester.runAsync(
            () => precacheImage(widget.image, tester.element(logo)),
          );
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final pixels = await tester.runAsync(() async {
            // Fractional logical sizes map to whole pixels at this scale.
            final image = await boundary.toImage(pixelRatio: 5);
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return data!;
          });
          final width = (size * 5).round();
          for (final (x, y) in [
            (0, 0),
            (width - 1, 0),
            (0, width - 1),
            (width - 1, width - 1),
          ]) {
            expect(pixels!.getUint8((y * width + x) * 4 + 3), 0);
          }
          final edge = (width ~/ 2) * 4;
          expect(pixels!.getUint8(edge + 3), 255);
          final background = brightness == Brightness.light ? 0 : 255;
          for (var channel = 0; channel < 3; channel++) {
            expect(pixels.getUint8(edge + channel), background);
          }
          expect(tester.takeException(), isNull);
        }

        await show(ThemeMode.system);
        await check(Brightness.light);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pumpAndSettle();
        await check(Brightness.dark);
        await show(ThemeMode.light);
        await check(Brightness.light);
        await show(ThemeMode.dark);
        await check(Brightness.dark);
      },
    );
  }

  test('icon attribution and OFL are available in offline licenses', () async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    registerBrandingLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final entry = entries.single;
    expect(entry.packages, contains('Nagino (響 icon)'));
    final text = entry.paragraphs.map((paragraph) => paragraph.text).join('\n');
    expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(text, contains('The Zen Maru Gothic Project Authors'));
    expect(text, contains('U+97FF'));
  });
}
