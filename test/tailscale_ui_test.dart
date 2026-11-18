import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/tailscale_settings.dart';

class _Model extends TamayuraModel {
  @override
  bool tailscaleEnabled = false;
  @override
  TailscaleConnectionState tailscaleState = TailscaleConnectionState.signedOut;
  @override
  List<TailscaleDeviceView> tailscaleCandidates = [];
  @override
  bool get tailscaleCanOpenLogin =>
      tailscaleState == TailscaleConnectionState.needsLogin;
  int logins = 0, logouts = 0, opens = 0;
  final confirmations = <String>[];
  @override
  Future<void> loginTailscale() async {
    logins++;
  }

  @override
  Future<void> logoutTailscale() async {
    logouts++;
  }

  @override
  Future<void> openTailscaleLogin() async {
    opens++;
  }

  @override
  Future<void> confirmTailscaleDevice(String key) async {
    confirmations.add(key);
  }

  @override
  bool get loading => false;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  String get deviceName => 'local';
  @override
  List<String> get addresses => [];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> get sharedFolders => [];
  @override
  String? get downloadFolder => null;
  @override
  int get localMediaCount => 0;
  @override
  List<DeviceView> get devices => [];
  @override
  String? get selectedDeviceId => null;
  @override
  List<MediaCollection> get collections => [];
  @override
  String? get selectedCollectionKey => null;
  @override
  List<MediaView> get media => [];
  @override
  Map<String, TransferView> get transfers => {};
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
  Future<void> selectCollection(String? key) async {}
  @override
  Future<void> download(MediaView item) async {}
  @override
  Future<void> share(MediaView item) async {}
  @override
  void clearError() {}
}

Widget _app(Widget child, {String language = 'en'}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocale.localizationsDelegates,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets(
    'login requires acknowledging mobile data; cancel has no effect',
    (tester) async {
      final model = _Model();
      await tester.pumpWidget(_app(TailscaleSettings(model: model)));
      await tester.tap(find.byKey(const Key('tailscale-login')));
      await tester.pumpAndSettle();
      expect(find.textContaining('mobile data'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(model.logins, 0);
      await tester.tap(find.byKey(const Key('tailscale-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(model.logins, 1);
    },
  );

  testWidgets(
    'remote association requires explicit source sharing confirmation',
    (tester) async {
      final model = _Model()
        ..tailscaleCandidates = [
          const TailscaleDeviceView(
            key: 'candidate',
            deviceId: 'device-id',
            name: 'Remote',
            nodeId: 'node-id',
            existingDevice: true,
          ),
        ];
      await tester.pumpWidget(_app(TailscaleCandidates(model: model)));
      expect(model.confirmations, isEmpty);
      await tester.tap(find.byKey(const Key('tailscale-confirm-candidate')));
      await tester.pumpAndSettle();
      expect(find.textContaining('read media'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(model.confirmations, ['candidate']);
    },
  );

  for (final language in ['zh', 'ja', 'en']) {
    testWidgets(
      'a successor node states that it revokes the previous one in $language',
      (tester) async {
        final model = _Model()
          ..tailscaleCandidates = [
            const TailscaleDeviceView(
              key: 'successor',
              deviceId: 'device-id',
              name: 'Remote',
              nodeId: 'new-node-id',
              existingDevice: true,
              replacesAssociation: true,
            ),
          ];
        await tester.pumpWidget(
          _app(TailscaleCandidates(model: model), language: language),
        );
        final text = lookupAppLocalizations(Locale(language));
        expect(find.text(text.tailscaleReplacesNode), findsOneWidget);
        // The plain "existing device" note would understate the change.
        expect(find.text(text.tailscaleExistingDevice), findsNothing);
        await tester.tap(find.byKey(const Key('tailscale-confirm-successor')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(text.tailscaleReplaceConfirmMessage),
          findsOneWidget,
        );
        expect(find.textContaining(text.tailscaleConfirmMessage), findsNothing);
        expect(find.textContaining('new-node-id'), findsWidgets);
        expect(model.confirmations, isEmpty);
        await tester.tap(find.text(text.commonConfirm));
        await tester.pumpAndSettle();
        expect(model.confirmations, ['successor']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('logout explains preserved data and allows cancellation', (
    tester,
  ) async {
    final model = _Model()
      ..tailscaleEnabled = true
      ..tailscaleState = TailscaleConnectionState.connected;
    await tester.pumpWidget(_app(TailscaleSettings(model: model)));
    await tester.tap(find.byKey(const Key('tailscale-logout')));
    await tester.pumpAndSettle();
    expect(find.textContaining('resumable downloads are kept'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(model.logouts, 0);
  });

  for (final language in ['zh', 'ja', 'en']) {
    testWidgets(
      'waiting for approval is distinct from connected in $language',
      (tester) async {
        final model = _Model()
          ..tailscaleEnabled = true
          ..tailscaleState = TailscaleConnectionState.needsApproval;
        await tester.pumpWidget(
          _app(TailscaleSettings(model: model), language: language),
        );
        final text = lookupAppLocalizations(Locale(language));
        expect(find.text(text.tailscaleNeedsApproval), findsOneWidget);
        expect(find.text(text.tailscaleConnected), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('dual path presence can be represented independently', () {
    const remote = DeviceView(
      id: 'device',
      name: 'Remote',
      address: '',
      online: true,
      lanOnline: false,
      tailscaleOnline: true,
    );
    expect(remote.online, isTrue);
    expect(remote.lanOnline, isFalse);
    expect(remote.tailscaleOnline, isTrue);
  });
}
