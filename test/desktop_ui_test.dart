import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/app.dart';

class _DesktopModel extends TamayuraModel {
  @override
  bool get loading => false;
  @override
  bool busy = false;
  @override
  String? error;
  @override
  String get deviceName => '我的 Mac';
  @override
  List<String> get addresses => ['192.168.1.10'];
  @override
  int get port => 50728;
  @override
  List<SharedFolder> sharedFolders = [
    const SharedFolder(id: 'pictures', uri: '/Pictures', name: '照片'),
  ];
  @override
  String? downloadFolder = '/Pictures/Tamayura';
  @override
  int get localMediaCount => 24;
  @override
  List<DeviceView> get devices => const [
    DeviceView(
      id: 'phone',
      name: 'Android 相册',
      address: '192.168.1.11:50728',
      online: true,
    ),
    DeviceView(
      id: 'other-mac',
      name: '另一台 Mac',
      address: '192.168.1.12:50728',
      online: false,
    ),
  ];
  @override
  List<MediaCollection> get collections => [
    MediaCollection(
      deviceId: 'phone',
      sharedFolderId: 'camera',
      sharedFolderName: '日常 · 相机胶卷',
      itemCount: 128,
      thumbnail: Uint8List(0),
    ),
    MediaCollection(
      deviceId: 'phone',
      sharedFolderId: 'travel',
      sharedFolderName: '旅行 · 山与海',
      itemCount: 46,
      thumbnail: Uint8List(0),
    ),
    MediaCollection(
      deviceId: 'other-mac',
      sharedFolderId: 'weekend',
      sharedFolderName: '周末 · 散步随拍',
      itemCount: 32,
      thumbnail: Uint8List(0),
    ),
  ];
  @override
  String? selectedCollectionKey;
  @override
  String? selectedDeviceId;
  @override
  List<MediaView> get media => [photo];
  final photo = MediaView(
    id: 'photo',
    deviceId: 'phone',
    name: 'IMG_001.jpg',
    sharedFolderId: 'camera',
    sharedFolderName: '日常 · 相机胶卷',
    mimeType: 'image/jpeg',
    size: 3200000,
    modified: DateTime(2026, 10, 10),
    thumbnail: Uint8List(0),
  );
  @override
  Map<String, TransferView> transfers = {};
  @override
  bool backgroundSharingEnabled = false;
  @override
  bool get backgroundSharingRunning => backgroundSharingEnabled;
  @override
  bool get batteryOptimizationExempt => false;
  int refreshCalls = 0;
  int chooseSharedCalls = 0;
  int downloadCalls = 0;
  String? connectedAddress;
  bool failConnect = false;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> setThemeMode(ThemeMode mode) async {}
  @override
  Future<void> refresh() async => refreshCalls++;
  @override
  Future<void> chooseSharedFolder() async => chooseSharedCalls++;
  @override
  Future<void> chooseDownloadFolder() async {}
  @override
  Future<void> removeSharedFolder(String id) async {}
  @override
  Future<void> connect(String address) async {
    if (failConnect) throw StateError('offline');
    connectedAddress = address;
  }

  @override
  Future<void> selectDevice(String? id) async {
    selectedDeviceId = id;
    selectedCollectionKey = null;
    notifyListeners();
  }

  @override
  Future<void> selectCollection(String? key) async {
    selectedCollectionKey = key;
    notifyListeners();
  }

  @override
  Future<void> download(MediaView item) async {
    downloadCalls++;
    transfers[item.key] = TransferView(
      progress: .25,
      item: item,
      receivedBytes: 800000,
      totalBytes: item.size,
    );
    notifyListeners();
  }

  @override
  Future<void> share(MediaView item) async {}
  @override
  Future<void> setBackgroundSharing(bool enabled) async {
    backgroundSharingEnabled = enabled;
    notifyListeners();
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

const _captureKey = Key('macos-prototype-capture');

Future<void> _show(WidgetTester tester, _DesktopModel model) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: TamayuraApp(model: model),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _settingsItem(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('settings-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void _desktopTest(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

void main() {
  testWidgets(
    'desktop settings explain close-to-tray, sharing and explicit quit',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final sharing = find.byKey(const Key('background-sharing-switch'));
      await _settingsItem(tester, sharing);
      expect(find.textContaining('关闭此项后在窗口隐藏时停止共享'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(sharing).value, isFalse);
      await tester.tap(sharing);
      await tester.pumpAndSettle();
      expect(model.backgroundSharingEnabled, isTrue);

      final closeTip = find.text('关闭窗口，接收继续');
      await _settingsItem(tester, closeTip);
      expect(find.textContaining('退出玉响'), findsOneWidget);
      expect(find.textContaining('关闭窗口会退出应用'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'Windows uses Ctrl shortcuts, desktop layout, QR display and no camera scanner',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      expect(find.byType(NavigationRail), findsOneWidget);
      Future<void> control(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await control(LogicalKeyboardKey.digit2);
      expect(find.text('附近的伙伴'), findsOneWidget);
      expect(find.text('扫一扫'), findsNothing);
      expect(find.text('输入 IP 连接'), findsOneWidget);
      await tester.tap(find.text('展示连接二维码'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await control(LogicalKeyboardKey.keyR);
      expect(model.refreshCalls, 1);
      await control(LogicalKeyboardKey.digit3);
      final tip = find.textContaining('支持 Windows 10 1809');
      await _settingsItem(tester, tip);
      expect(tip, findsOneWidget);
      expect(find.textContaining('支持 Android 16'), findsNothing);
      expect(find.textContaining('支持 macOS Sequoia'), findsNothing);
      expect(
        find.byKey(const Key('background-sharing-battery-settings')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows completed downloads offer Explorer reveal and narrow layouts',
    (tester) async {
      final model = _DesktopModel();
      model.transfers[model.photo.key] = TransferView(
        progress: 1,
        status: TransferStatus.completed,
        item: model.photo,
        savedUri: r'C:\Photos\IMG_001.jpg',
      );
      await _show(tester, model);
      await tester.tap(find.text('日常 · 相机胶卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('media-${model.photo.key}')));
      await tester.pumpAndSettle();
      expect(find.text('在文件夹中显示'), findsOneWidget);
      expect(find.text('分享'), findsNothing);
      tester.view.physicalSize = const Size(620, 860);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Linux uses Ctrl shortcuts, desktop layout, QR display and no camera scanner',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      Future<void> control(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await control(LogicalKeyboardKey.digit2);
      expect(find.text('附近的伙伴'), findsOneWidget);
      expect(find.text('扫一扫'), findsNothing);
      expect(find.text('输入 IP 连接'), findsOneWidget);
      expect(find.textContaining('电脑保持唤醒'), findsOneWidget);
      await tester.tap(find.text('展示连接二维码'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await control(LogicalKeyboardKey.keyR);
      expect(model.refreshCalls, 1);
      // ⌘ shortcuts belong to macOS only.
      await _command(tester, LogicalKeyboardKey.digit1);
      expect(find.text('附近的伙伴'), findsOneWidget);
      await control(LogicalKeyboardKey.comma);
      final tip = find.textContaining('支持 Ubuntu 24.04 LTS');
      await _settingsItem(tester, tip);
      expect(tip, findsOneWidget);
      expect(find.textContaining('Avahi'), findsOneWidget);
      expect(find.textContaining('支持 Windows 10'), findsNothing);
      expect(find.textContaining('支持 macOS Sequoia'), findsNothing);
      expect(find.textContaining('支持 Android 16'), findsNothing);
      final keyboard = find.textContaining('Ctrl+R 刷新 · Ctrl+Q 退出');
      await _settingsItem(tester, keyboard);
      expect(keyboard, findsOneWidget);
      final open = find.textContaining('在文件管理器中定位文件');
      await _settingsItem(tester, open);
      expect(open, findsOneWidget);
      expect(find.textContaining('资源管理器'), findsNothing);
      final footer = find.text('TAMAYURA  /  Linux');
      await _settingsItem(tester, footer);
      expect(footer, findsOneWidget);
      expect(
        find.byKey(const Key('background-sharing-battery-settings')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('Linux explains tray-dependent closing and background sharing', (
    tester,
  ) async {
    final model = _DesktopModel();
    model.transfers[model.photo.key] = TransferView(
      progress: .25,
      item: model.photo,
      receivedBytes: 800000,
      totalBytes: model.photo.size,
    );
    await _show(tester, model);
    await tester.tap(find.byKey(const Key('settings-tab')));
    await tester.pumpAndSettle();
    final sharing = find.byKey(const Key('background-sharing-switch'));
    await _settingsItem(tester, sharing);
    expect(find.textContaining('没有托盘时关闭窗口会退出玉响'), findsOneWidget);
    await tester.tap(sharing);
    await tester.pumpAndSettle();
    expect(model.backgroundSharingEnabled, isTrue);
    expect(find.textContaining('电脑睡眠或退出玉响后'), findsOneWidget);
    final tray = find.textContaining('Ubuntu 默认桌面');
    await _settingsItem(tester, tray);
    expect(find.textContaining('「退出玉响」'), findsOneWidget);
    expect(find.textContaining('右键菜单'), findsNothing);
    await tester.tap(find.byKey(const Key('downloads-entry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有托盘时关闭窗口会退出并中断接收'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux completed downloads offer a file manager reveal', (
    tester,
  ) async {
    final model = _DesktopModel();
    model.transfers[model.photo.key] = TransferView(
      progress: 1,
      status: TransferStatus.completed,
      item: model.photo,
      savedUri: '/home/用户/图片/Phone/IMG_001.jpg',
    );
    await _show(tester, model);
    await tester.tap(find.text('日常 · 相机胶卷'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('media-${model.photo.key}')));
    await tester.pumpAndSettle();
    expect(find.text('在文件夹中显示'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    tester.view.physicalSize = const Size(620, 860);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  _desktopTest(
    'Mac uses sidebar and constrained surfaces with keyboard shortcuts',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue,
      );
      await _command(tester, LogicalKeyboardKey.digit2);
      expect(find.text('附近的伙伴'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const PageStorageKey('devices-scroll')))
            .width,
        lessThanOrEqualTo(840),
      );
      await _command(tester, LogicalKeyboardKey.keyR);
      expect(model.refreshCalls, 1);
      model.busy = true;
      await _command(tester, LogicalKeyboardKey.keyR);
      expect(model.refreshCalls, 1);
      model.busy = false;
      await _command(tester, LogicalKeyboardKey.comma);
      expect(find.text('你的相册，你来安排'), findsOneWidget);
      await _command(tester, LogicalKeyboardKey.digit1);
      expect(find.text('每一刻，都在手边。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _desktopTest(
    'resizing preserves selected tab and supports a narrow Mac window',
    (tester) async {
      await _show(tester, _DesktopModel());
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(920, 600);
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
      expect(find.text('附近的伙伴'), findsOneWidget);
      tester.view.physicalSize = const Size(600, 500);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      expect(find.text('你的相册，你来安排'), findsOneWidget);
      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _desktopTest(
    'Mac settings explain sleep and supported releases without Android battery actions',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final addFolder = find.byKey(const Key('add-shared-folder'));
      await _settingsItem(tester, addFolder);
      await tester.tap(addFolder);
      expect(model.chooseSharedCalls, 1);
      final sharing = find.byKey(const Key('background-sharing-switch'));
      await _settingsItem(tester, sharing);
      await tester.tap(sharing);
      await tester.pumpAndSettle();
      expect(model.backgroundSharingEnabled, isTrue);
      expect(find.textContaining('关闭此项后在窗口隐藏时停止共享'), findsOneWidget);
      expect(find.textContaining('Mac 睡眠或退出玉响'), findsOneWidget);
      expect(
        find.byKey(const Key('background-sharing-battery-settings')),
        findsNothing,
      );
      final supported = find.textContaining('支持 macOS Sequoia 15、Tahoe 26');
      await _settingsItem(tester, supported);
      expect(supported, findsOneWidget);
      expect(find.textContaining('支持 Android 16'), findsNothing);
      final sleep = find.textContaining('Mac 睡眠或断网后');
      await _settingsItem(tester, sleep);
      expect(sleep, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _desktopTest(
    'Mac manual connection supports keyboard submission, QR display and failures',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      await tester.tap(find.byKey(const Key('devices-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('展示连接二维码'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-manual')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ip-input')),
        '192.168.1.20:50728',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(model.connectedAddress, '192.168.1.20:50728');
      model.failConnect = true;
      await tester.tap(find.byKey(const Key('connect-manual')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ip-input')), '192.168.1.21');
      await tester.tap(find.byKey(const Key('confirm-connect')));
      await tester.pumpAndSettle();
      expect(find.text('操作未能完成，请检查网络与目录权限后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _desktopTest(
    'Mac collection click downloads once and retains task after closing preview',
    (tester) async {
      final model = _DesktopModel();
      await _show(tester, model);
      await tester.tap(find.byKey(const Key('collection-phone/camera')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('media-${model.photo.key}')));
      await tester.pumpAndSettle();
      expect(model.downloadCalls, 1);
      expect(find.text('双击放大'), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-preview')));
      await tester.pumpAndSettle();
      expect(model.transfers[model.photo.key]!.running, isTrue);
      await tester.tap(find.byKey(const Key('downloads-entry')));
      await tester.pumpAndSettle();
      expect(find.textContaining('退出或睡眠中断后可重试'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const PageStorageKey('downloads-list')))
            .width,
        lessThanOrEqualTo(840),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide Android windows retain bottom navigation and Android guidance',
    (tester) async {
      await _show(tester, _DesktopModel());
      await tester.pumpWidget(TamayuraApp(model: _DesktopModel()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-tab')));
      await tester.pumpAndSettle();
      final supported = find.textContaining('支持 Android 16');
      await _settingsItem(tester, supported);
      expect(supported, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // Opt-in visual capture uses local fonts; routine tests stay portable.
  const screenshot = String.fromEnvironment('TAMAYURA_SCREENSHOT_PATH');
  if (screenshot.isNotEmpty) {
    _desktopTest('render Mac prototype with fictional albums', (tester) async {
      await tester.runAsync(() async {
        await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
              rootBundle.load(
                'packages/lucide_icons_flutter/assets/lucide.ttf',
              ),
            ))
            .load();
        const fontPath = String.fromEnvironment('TAMAYURA_SCREENSHOT_FONT');
        final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
        for (final family in [
          'Roboto',
          '.SF UI Text',
          '.SF UI Display',
          '.AppleSystemUIFont',
          'CupertinoSystemText',
          'CupertinoSystemDisplay',
        ]) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
        const iconPath = String.fromEnvironment('TAMAYURA_SCREENSHOT_ICONS');
        if (iconPath.isNotEmpty) {
          await (FontLoader('MaterialIcons')..addFont(
                Future.value(
                  ByteData.sublistView(await File(iconPath).readAsBytes()),
                ),
              ))
              .load();
        }
      });
      await _show(tester, _DesktopModel());
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(screenshot);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    });
  }
}
