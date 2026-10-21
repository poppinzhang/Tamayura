import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app_theme.dart';

Widget _localizedControls(Locale locale) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocale.localizationsDelegates,
  theme: AppTheme.light,
  home: Builder(
    builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.settingsTitle),
        leading: BackButton(onPressed: () {}),
        actions: [
          PopupMenuButton<void>(
            key: const Key('localized-menu'),
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                key: const Key('localized-dialog-item'),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    content: Text(context.l10n.detailFileName),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          MaterialLocalizations.of(context).cancelButtonLabel,
                        ),
                      ),
                    ],
                  ),
                ),
                child: Text(context.l10n.previewDetails),
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);

void main() {
  for (final labels in [
    (
      language: 'zh',
      settings: '你的相册，你来安排',
      back: '返回',
      showMenu: '显示菜单',
      popupMenu: '弹出菜单',
      dismissMenu: '关闭菜单',
      dialog: '提醒',
      dismissDialog: '关闭',
      cancel: '取消',
    ),
    (
      language: 'ja',
      settings: 'あなたのアルバムを、あなたらしく',
      back: '戻る',
      showMenu: 'メニューを表示',
      popupMenu: 'ポップアップ メニュー',
      dismissMenu: 'メニューを閉じる',
      dialog: '通知',
      dismissDialog: '閉じる',
      cancel: 'キャンセル',
    ),
    (
      language: 'en',
      settings: 'Your album, your way',
      back: 'Back',
      showMenu: 'Show menu',
      popupMenu: 'Popup menu',
      dismissMenu: 'Dismiss menu',
      dialog: 'Alert',
      dismissDialog: 'Dismiss',
      cancel: 'Cancel',
    ),
  ]) {
    testWidgets(
      '${labels.language} localizes Material controls, popup and dialog semantics',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(_localizedControls(Locale(labels.language)));
          await tester.pumpAndSettle();

          final material = MaterialLocalizations.of(
            tester.element(find.byType(Scaffold)),
          );
          expect(material, isA<GlobalMaterialLocalizations>());
          expect(material.cancelButtonLabel, labels.cancel);
          expect(find.text(labels.settings), findsOneWidget);
          expect(find.byTooltip(labels.back), findsOneWidget);
          expect(find.byTooltip(labels.showMenu), findsOneWidget);

          await tester.tap(find.byKey(const Key('localized-menu')));
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel(labels.popupMenu), findsOneWidget);
          expect(find.bySemanticsLabel(labels.dismissMenu), findsOneWidget);
          await tester.tap(find.byKey(const Key('localized-dialog-item')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.bySemanticsLabel(labels.dialog), findsOneWidget);
          expect(find.bySemanticsLabel(labels.dismissDialog), findsOneWidget);
          await tester.tap(find.widgetWithText(TextButton, labels.cancel));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byKey(const Key('localized-dialog-item')), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
