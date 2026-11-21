import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/app.dart';
import 'package:tamayura/ui/tailscale_settings.dart';

const _candidate = TailscaleDeviceView(
  key: 'candidate',
  deviceId: 'device-id',
  name: 'Tablet',
  nodeId: 'node-id',
  existingDevice: false,
);

class _Model extends TamayuraModel {
  @override
  bool tailscaleEnabled = false;
  @override
  TailscaleConnectionState tailscaleState = TailscaleConnectionState.signedOut;
  @override
  TailscaleDiagnostics? tailscaleDiagnostics;
  @override
  List<TailscaleDeviceView> tailscaleCandidates = [];
  @override
  Map<String, String> tailscaleAuthorizedDevices = {};
  @override
  String? tailscaleError;
  @override
  bool get tailscaleCanOpenLogin =>
      tailscaleState == TailscaleConnectionState.needsLogin;
  int logins = 0, logouts = 0, opens = 0, retries = 0;
  final confirmations = <String>[];
  final revocations = <String>[];
  bool failRevocation = false;

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
  Future<void> retryTailscale() async {
    retries++;
  }

  @override
  Future<void> confirmTailscaleDevice(String key) async {
    confirmations.add(key);
    final candidate = tailscaleCandidates.singleWhere(
      (item) => item.key == key,
    );
    tailscaleCandidates.remove(candidate);
    tailscaleAuthorizedDevices[candidate.deviceId] = candidate.name;
    notifyListeners();
  }

  @override
  Future<void> revokeTailscaleDevice(String deviceId) async {
    revocations.add(deviceId);
    if (failRevocation) {
      tailscaleError = 'Could not revoke sharing';
    } else {
      tailscaleError = null;
      tailscaleAuthorizedDevices.remove(deviceId);
    }
    notifyListeners();
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
  AppLanguage get language => AppLanguage.zh;
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
    'remote sharing actions are in Settings and absent from Devices',
    (tester) async {
      final model = _Model()
        ..tailscaleEnabled = true
        ..tailscaleState = TailscaleConnectionState.connected
        ..tailscaleCandidates = [_candidate]
        ..tailscaleAuthorizedDevices = {'laptop-id': 'Laptop'};
      final text = lookupAppLocalizations(model.locale);
      await tester.pumpWidget(TamayuraApp(model: model));
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      // The former sharing controls appeared below the remembered devices.
      final devices = find.byKey(const PageStorageKey('devices-scroll'));
      await tester.drag(devices, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(find.text('Tablet'), findsNothing);
      expect(find.text(text.tailscaleConfirm), findsNothing);
      expect(find.text(text.tailscaleRevoke), findsNothing);

      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final allow = find.byKey(const Key('tailscale-confirm-candidate'));
      await tester.scrollUntilVisible(
        allow,
        240,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('settings-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final card = find.byType(TailscaleSettings);
      Finder inCard(String value) =>
          find.descendant(of: card, matching: find.text(value));
      expect(inCard(text.tailscaleDescription), findsOneWidget);
      expect(inCard(text.tailscaleConnected), findsOneWidget);
      expect(inCard(model.deviceName), findsNothing);
      expect(inCard('发现远程共享设备'), findsOneWidget);
      expect(inCard('Tablet'), findsOneWidget);
      expect(inCard('允许远程共享'), findsOneWidget);
      expect(inCard('Laptop'), findsOneWidget);
      expect(inCard('撤销远程共享'), findsOneWidget);
      expect(find.textContaining('device-id'), findsNothing);
      expect(find.textContaining('node-id'), findsNothing);
      expect(find.textContaining('laptop-id'), findsNothing);
      expect(inCard('检查连接与设备'), findsOneWidget);
      final retry = find.byKey(const Key('tailscale-retry'));
      await Scrollable.ensureVisible(tester.element(retry), alignment: .5);
      await tester.pumpAndSettle();
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(model.retries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'allow requires confirmation and a failed revocation can be retried',
    (tester) async {
      final model = _Model()
        ..tailscaleEnabled = true
        ..tailscaleState = TailscaleConnectionState.connected
        ..tailscaleCandidates = [_candidate]
        ..tailscaleAuthorizedDevices = {'other-id': 'Other'};
      await tester.pumpWidget(
        _app(
          ListenableBuilder(
            listenable: model,
            builder: (context, _) => TailscaleSettings(model: model),
          ),
        ),
      );
      final allow = find.byKey(const Key('tailscale-confirm-candidate'));
      await tester.tap(allow);
      await tester.pumpAndSettle();
      expect(find.textContaining('shared folders'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(model.confirmations, isEmpty);
      await tester.tap(allow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(model.confirmations, ['candidate']);
      expect(allow, findsNothing);

      final revoke = find.byKey(const Key('tailscale-revoke-device-id'));
      model.failRevocation = true;
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      expect(find.text('Could not revoke sharing'), findsOneWidget);
      expect(revoke, findsOneWidget);
      model.failRevocation = false;
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      expect(model.revocations, ['device-id', 'device-id']);
      expect(revoke, findsNothing);
      expect(find.byKey(const Key('tailscale-error')), findsNothing);
      expect(
        find.byKey(const Key('tailscale-revoke-other-id')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['zh', 'ja', 'en']) {
    testWidgets(
      'remote diagnostics distinguish pending and zero in $language',
      (tester) async {
        final model = _Model();
        final text = lookupAppLocalizations(Locale(language));
        Future<void> show() => tester.pumpWidget(
          _app(TailscaleSettings(model: model), language: language),
        );
        await show();
        expect(find.text(text.tailscaleScanPending), findsNothing);
        model.tailscaleDiagnostics = (
          visibleNodes: null,
          respondingNodes: null,
          sharingReady: false,
        );
        await show();
        expect(find.text(text.tailscaleSharingNotReady), findsOneWidget);
        expect(find.text(text.tailscaleScanPending), findsOneWidget);
        expect(find.text(text.tailscaleVisibleNodes(0)), findsNothing);
        model.tailscaleDiagnostics = (
          visibleNodes: 1,
          respondingNodes: null,
          sharingReady: true,
        );
        await show();
        expect(find.text(text.tailscaleSharingReady), findsOneWidget);
        expect(find.text(text.tailscaleVisibleNodes(1)), findsOneWidget);
        expect(find.text(text.tailscaleProbePending), findsOneWidget);
        expect(find.text(text.tailscaleRespondingNodes(0)), findsNothing);
        model.tailscaleDiagnostics = (
          visibleNodes: 1,
          respondingNodes: 0,
          sharingReady: true,
        );
        await show();
        expect(find.text(text.tailscaleVisibleNodes(1)), findsOneWidget);
        expect(find.text(text.tailscaleRespondingNodes(0)), findsOneWidget);
        expect(find.text(text.tailscaleProbePending), findsNothing);
      },
    );

    testWidgets(
      'a successor node states that it revokes the previous one in $language',
      (tester) async {
        final model = _Model()
          ..tailscaleEnabled = true
          ..tailscaleState = TailscaleConnectionState.connected
          ..tailscaleAuthorizedDevices = {'device-id': 'Remote'}
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
          _app(TailscaleSettings(model: model), language: language),
        );
        final text = lookupAppLocalizations(Locale(language));
        expect(find.text('Remote'), findsOneWidget);
        expect(
          find.byKey(const Key('tailscale-revoke-device-id')),
          findsOneWidget,
        );
        expect(find.textContaining('new-node-id'), findsNothing);
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
