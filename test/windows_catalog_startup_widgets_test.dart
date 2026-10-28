import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/errors.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app.dart';

class _ScanningModel extends TamayuraModel {
  _ScanningModel(this.language);
  @override
  final AppLanguage language;
  @override
  bool get loading => false;
  @override
  bool get busy => false;
  @override
  bool localScanning = true;
  @override
  String? get error => null;
  @override
  String get deviceName => 'Windows';
  @override
  List<String> get addresses => const [];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> sharedFolders = [
    const SharedFolder(id: 'photos', uri: r'C:\Photos', name: 'Photos'),
  ];
  @override
  String? get downloadFolder => 'Received';
  @override
  int get localMediaCount => 10000;
  @override
  List<DeviceView> get devices => const [];
  @override
  String? get selectedDeviceId => null;
  @override
  List<MediaCollection> get collections => const [];
  @override
  String? get selectedCollectionKey => null;
  @override
  List<MediaView> get media => const [];
  @override
  Map<String, TransferView> get transfers => const {};

  var added = 0;
  final removed = <String>[];

  @override
  Future<void> chooseSharedFolder() async {
    added++;
    sharedFolders.add(
      const SharedFolder(id: 'other', uri: r'D:\Pictures', name: 'Pictures'),
    );
    notifyListeners();
  }

  @override
  Future<void> removeSharedFolder(String id) async {
    removed.add(id);
    sharedFolders.removeWhere((folder) => folder.id == id);
    notifyListeners();
  }

  void finishScan() {
    localScanning = false;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> chooseDownloadFolder() async {}
  @override
  Future<void> connect(String address) async {}
  @override
  Future<void> selectDevice(String? id) async {}
  @override
  Future<void> selectCollection(String? key) async {}
  @override
  Future<void> download(MediaView item) async {}
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {}
}

void main() {
  for (final language in [AppLanguage.zh, AppLanguage.ja, AppLanguage.en]) {
    testWidgets(
      'Windows shared-folder controls stay usable while scanning in ${language.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final model = _ScanningModel(language);
        addTearDown(model.dispose);
        await tester.pumpWidget(TamayuraApp(model: model));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('settings-tab')));
        await tester.pump(const Duration(milliseconds: 400));
        final add = find.byKey(const Key('add-shared-folder'));
        final scrollable = find
            .descendant(
              of: find.byKey(const PageStorageKey('settings-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(add, 200, scrollable: scrollable);
        await tester.ensureVisible(add);
        await tester.pump(const Duration(milliseconds: 400));
        final message = find.byKey(const Key('shared-folders-scanning'));
        final text = lookupAppLocalizations(Locale(language.name));
        expect(
          tester.widget<Text>(message).data,
          text.settingsSharedFoldersScanning,
        );
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
        await tester.tap(add);
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.added, 1);
        expect(model.localScanning, isTrue);
        final remove = find.byKey(const Key('remove-shared-folder-photos'));
        await tester.ensureVisible(remove);
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
        await tester.tap(remove);
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.removed, ['photos']);
        expect(find.byKey(const Key('shared-folder-photos')), findsNothing);
        expect(model.localScanning, isTrue);
        model.finishScan();
        await tester.pump(const Duration(milliseconds: 400));
        expect(message, findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    test(
      'local catalog failures use ${language.name} translations instead of native details',
      () {
        final previous = AppLocale.language;
        addTearDown(() => AppLocale.language = previous);
        AppLocale.language = language;
        final text = lookupAppLocalizations(Locale(language.name));
        final expected = {
          'LOCAL_CATALOG_VERSION': text.errorLocalCatalogVersion,
          'LOCAL_CATALOG_CORRUPT': text.errorLocalCatalogCorrupt,
          'LOCAL_CATALOG_IO': text.errorLocalCatalogIo,
        };
        for (final entry in expected.entries) {
          final result = describeError(
            PlatformException(code: entry.key, message: 'native diagnostic'),
          );
          expect(result, entry.value);
          expect(result, isNot(contains('native diagnostic')));
        }
      },
    );
  }
}
