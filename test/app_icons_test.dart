import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app_icons.dart';
import 'package:tamayura/ui/transfer_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Lucide font is bundled for offline rendering', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    final lucide = manifest.cast<Map<String, dynamic>>().singleWhere(
      (entry) => entry['family'] == 'packages/lucide_icons_flutter/Lucide',
    );
    final fonts = lucide['fonts'] as List;
    final asset = (fonts.single as Map<String, dynamic>)['asset'] as String;
    final font = await rootBundle.load(asset);
    expect(font.lengthInBytes, greaterThan(4));
    expect(font.getUint32(0), 0x00010000);
  });

  testWidgets('transfer status and action icons use the bundled Lucide font', (
    tester,
  ) async {
    final item = MediaView(
      id: 'photo',
      deviceId: 'peer',
      name: 'photo.jpg',
      mimeType: 'image/jpeg',
      size: 100,
      modified: DateTime(2026),
      thumbnail: Uint8List(0),
    );
    final cases = <(TransferView, IconData)>[
      (
        const TransferView(progress: .5, status: TransferStatus.downloading),
        AppIcons.downloads,
      ),
      (
        const TransferView(progress: .5, status: TransferStatus.cancelled),
        AppIcons.paused,
      ),
      (
        const TransferView(progress: .5, status: TransferStatus.failed),
        AppIcons.error,
      ),
      (
        const TransferView(progress: 1, savedUri: 'received-photo.jpg'),
        AppIcons.success,
      ),
    ];
    for (final (transfer, statusIcon) in cases) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocale.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: AppLocale.current,
          home: Scaffold(
            body: TransferControls(
              item: item,
              transfer: transfer,
              onDownload: () {},
              onCancel: () {},
              onDiscard: () {},
              onShare: () {},
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.byIcon(statusIcon), findsOneWidget);
      final icons = tester.widgetList<Icon>(find.byType(Icon));
      expect(icons.length, greaterThan(1));
      for (final icon in icons) {
        expect(icon.icon?.fontFamily, 'Lucide');
        expect(icon.icon?.fontPackage, 'lucide_icons_flutter');
      }
      expect(tester.takeException(), isNull);
    }
  });
}
