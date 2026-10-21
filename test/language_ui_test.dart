import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app.dart';

class _Model extends TamayuraModel {
  @override
  AppLanguage language = AppLanguage.system;
  @override
  bool languageSaving = false;
  final List<AppLanguage> requests = [];
  @override
  bool albumDetailedMode = false;
  @override
  bool loading = false;
  @override
  bool busy = false;
  @override
  String? error;
  @override
  String deviceName = 'Pixel';
  @override
  List<String> addresses = ['192.168.1.10'];
  @override
  int port = 50728;
  @override
  List<SharedFolder> sharedFolders = [
    const SharedFolder(id: 'camera', uri: 'content://camera', name: 'Camera'),
  ];
  @override
  String? downloadFolder = 'Downloads';
  @override
  int localMediaCount = 3;
  @override
  List<DeviceView> devices = [
    const DeviceView(
      id: 'mac',
      name: 'MacBook',
      address: '192.168.1.20:50728',
      online: true,
    ),
    const DeviceView(
      id: 'tablet',
      name: 'Tablet',
      address: '192.168.1.21:50728',
      online: false,
      syncApproval: PeerSyncApproval.pending,
    ),
  ];
  @override
  String? selectedDeviceId;
  @override
  String? selectedCollectionKey;
  final items = [
    MediaView(
      id: 'photo',
      deviceId: 'mac',
      name: 'IMG_0001.jpg',
      mimeType: 'image/jpeg',
      size: 2048,
      modified: DateTime(2026, 10, 17, 9),
      thumbnail: Uint8List(0),
      sharedFolderId: 'trip',
      sharedFolderName: 'Trip',
    ),
  ];
  @override
  List<MediaCollection> get collections => [
    MediaCollection(
      deviceId: 'mac',
      sharedFolderId: 'trip',
      sharedFolderName: 'Trip',
      itemCount: items.length,
      thumbnail: Uint8List(0),
    ),
  ];
  @override
  List<MediaView> get media => selectedCollectionKey == null ? [] : items;
  @override
  Map<String, TransferView> transfers = {};

  void show(AppLanguage value) {
    language = value;
    notifyListeners();
  }

  @override
  Future<void> setLanguage(AppLanguage language) async {
    requests.add(language);
    show(language);
  }

  @override
  Future<void> selectCollection(String? key) async {
    selectedCollectionKey = key;
    notifyListeners();
  }

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
  Future<void> selectDevice(String? id) async {}
  @override
  Future<void> download(MediaView item) async {}
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {}
}

Finder _settingsScroll() => find
    .descendant(
      of: find.byKey(const PageStorageKey('settings-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settings-tab')));
  await tester.pumpAndSettle();
}

Future<void> _showLanguage(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('language-selector')),
    200,
    scrollable: _settingsScroll(),
  );
  await tester.pumpAndSettle();
}

/// Drag the settings list until [target] is built, settling between drags.
/// Drags start in the page padding, away from selectable text.
Future<void> _scrollSettingsTo(WidgetTester tester, Finder target) async {
  for (var drags = 0; target.evaluate().isEmpty && drags < 60; drags++) {
    final area = tester.getRect(_settingsScroll());
    await tester.dragFrom(
      Offset(area.left + 8, area.center.dy),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
}

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('language-status'))).data!;

void main() {
  testWidgets('settings offers each language by its own name', (tester) async {
    final model = _Model();
    await tester.pumpWidget(TamayuraApp(model: model));
    await _openSettings(tester);
    await _showLanguage(tester);
    expect(find.text('语言'), findsOneWidget);
    expect(_status(tester), '跟随系统语言，当前显示简体中文。系统语言不是中文或日文时显示英文。');

    await tester.tap(find.byKey(const Key('language-selector')));
    await tester.pumpAndSettle();
    final labels = {
      AppLanguage.system: '跟随系统',
      AppLanguage.zh: '简体中文',
      AppLanguage.ja: '日本語',
      AppLanguage.en: 'English',
    };
    for (final MapEntry(key: language, value: label) in labels.entries) {
      final item = find.byKey(Key('language-${language.name}'));
      expect(
        find.descendant(of: item, matching: find.text(label)),
        findsOneWidget,
      );
      expect(
        tester.widget<CheckedPopupMenuItem<AppLanguage>>(item).checked,
        language == AppLanguage.system,
      );
    }

    await tester.tap(find.byKey(const Key('language-ja')));
    await tester.pumpAndSettle();
    expect(model.requests, [AppLanguage.ja]);
    expect(find.text('設定'), findsOneWidget);
    expect(find.text('言語'), findsOneWidget);
    expect(_status(tester), 'システムの言語にかかわらず、常に日本語で表示します。');

    // The language names stay readable after switching.
    await tester.tap(find.byKey(const Key('language-selector')));
    await tester.pumpAndSettle();
    expect(find.text('システムに従う'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(const Key('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(
      _status(tester),
      'Always uses English, regardless of the system language.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving disables the language menu', (tester) async {
    final model = _Model()..languageSaving = true;
    await tester.pumpWidget(TamayuraApp(model: model));
    await _openSettings(tester);
    await _showLanguage(tester);
    expect(_status(tester), '正在保存语言…');
    await tester.tap(find.byKey(const Key('language-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('language-en')), findsNothing);
    expect(model.requests, isEmpty);
  });

  testWidgets('following the system uses its first supported language', (
    tester,
  ) async {
    AppLocale.systemLocales = () => const [Locale('fr'), Locale('ja', 'JP')];
    final model = _Model();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('アルバム'), findsWidgets);
    expect(find.text('すべてのデバイス'), findsOneWidget);

    AppLocale.systemLocales = () => const [Locale('de')];
    model.systemLocalesChanged();
    await tester.pumpAndSettle();
    expect(find.text('Album'), findsWidgets);
    expect(find.text('All devices'), findsOneWidget);

    // A chosen language no longer follows the system.
    model.show(AppLanguage.zh);
    AppLocale.systemLocales = () => const [Locale('ja')];
    model.systemLocalesChanged();
    await tester.pumpAndSettle();
    expect(find.text('全部设备'), findsOneWidget);
  });

  testWidgets('open pages and Material controls switch with the app', (
    tester,
  ) async {
    final model = _Model();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.tap(find.byKey(const Key('downloads-entry')));
    await tester.pumpAndSettle();
    expect(find.text('下载任务'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);

    model.show(AppLanguage.en);
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    model.show(AppLanguage.ja);
    await tester.pumpAndSettle();
    expect(find.text('ダウンロード'), findsOneWidget);
    expect(find.byTooltip('戻る'), findsOneWidget);
  });

  testWidgets('open media details follow system language changes', (
    tester,
  ) async {
    final model = _Model();
    await tester.pumpWidget(TamayuraApp(model: model));
    await tester.tap(find.byKey(const Key('collection-mac/trip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('media-mac/photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preview-details')));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const Key('media-details-sheet'));
    final sheetElement = tester.element(sheet);
    for (final (locale, title, fileName, online, close) in [
      (const Locale('zh'), '详细信息', '文件名', '在线', '关闭详细信息'),
      (const Locale('en'), 'Details', 'File name', 'Online', 'Close details'),
      (const Locale('ja'), '詳細情報', 'ファイル名', 'オンライン', '詳細情報を閉じる'),
    ]) {
      AppLocale.systemLocales = () => [locale];
      model.systemLocalesChanged();
      await tester.pumpAndSettle();
      expect(tester.element(sheet), same(sheetElement));
      for (final label in [title, fileName, online]) {
        expect(
          find.descendant(of: sheet, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(find.byTooltip(close), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.byKey(const Key('close-media-details')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
  });

  for (final (language, date, count) in [
    (AppLanguage.zh, '10月17日', '1 个瞬间'),
    (AppLanguage.ja, '10月17日', '1 件の思い出'),
    (AppLanguage.en, 'Oct 17', '1 moment'),
  ]) {
    testWidgets('album counts and dates use ${language.name} formats', (
      tester,
    ) async {
      final model = _Model()
        ..language = language
        ..albumDetailedMode = true;
      await tester.pumpWidget(TamayuraApp(model: model));
      await tester.pumpAndSettle();
      expect(find.text(count), findsOneWidget);
      await tester.tap(find.byKey(const Key('collection-mac/trip')));
      await tester.pumpAndSettle();
      expect(find.text(date), findsOneWidget);
    });
  }

  for (final language in AppLanguage.values.skip(1)) {
    for (final size in const [Size(320, 640), Size(640, 320)]) {
      testWidgets(
        '${language.name} empty downloads fit $size with large text',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.platformDispatcher.textScaleFactorTestValue = 1.6;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final model = _Model()..language = language;
          await tester.pumpWidget(TamayuraApp(model: model));
          await tester.tap(find.byKey(const Key('downloads-entry')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final page = find.byKey(const Key('downloads-page'));
          final back = find.descendant(
            of: page,
            matching: find.byType(TextButton),
          );
          await tester.ensureVisible(back);
          await tester.pumpAndSettle();
          expect(back.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(page, findsNothing);
          expect(find.byKey(const Key('downloads-entry')), findsOneWidget);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );

      testWidgets('${language.name} pages fit $size with large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final model = _Model()..language = language;
        await tester.pumpWidget(TamayuraApp(model: model));
        await tester.pumpAndSettle();
        for (final tab in ['album-tab', 'devices-tab', 'settings-tab']) {
          await tester.tap(find.byKey(Key(tab)).first);
          await tester.pumpAndSettle();
        }
        await _showLanguage(tester);
        await tester.tap(find.byKey(const Key('language-selector')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('language-zh')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('language-zh')), findsNothing);
        await _scrollSettingsTo(tester, find.byKey(const Key('about-entry')));
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }
}
