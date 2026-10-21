import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app_theme.dart';
import 'package:tamayura/ui/device_order_dialog.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('device order dialog supports large text at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pendingSave = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocale.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: AppLocale.current,
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => DeviceOrderDialog(
                    devices: [
                      for (var index = 0; index < 8; index++)
                        DeviceView(
                          id: '$index',
                          name: '共享照片的设备 $index',
                          address: '192.0.2.${index + 1}:50728',
                          online: index.isEven,
                        ),
                    ],
                    onSave: (_) => pendingSave.future,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final save = find.byKey(const Key('device-order-save'));
      final cancel = find.byKey(const Key('device-order-cancel'));
      expect(save.hitTestable(), findsOneWidget);
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('正在保存…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final screen = Offset.zero & size;
      expect(screen.contains(tester.getTopLeft(save)), isTrue);
      expect(screen.contains(tester.getBottomRight(save)), isTrue);
      expect(screen.contains(tester.getTopLeft(cancel)), isTrue);
      expect(screen.contains(tester.getBottomRight(cancel)), isTrue);
      pendingSave.complete(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-order-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(save.hitTestable(), findsOneWidget);
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byType(DeviceOrderDialog), findsNothing);
    });
  }
}
