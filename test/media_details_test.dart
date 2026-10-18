import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/media_preview.dart';

class _Model extends TamayuraModel {
  @override
  final List<DeviceView> devices = [
    const DeviceView(id: 'peer', name: '来源设备', address: '', online: false),
  ];

  @override
  final Map<String, TransferView> transfers = {};

  final unexpectedCalls = <Symbol>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw StateError('Unexpected model access: ${invocation.memberName}');
  }
}

MediaView _photo({
  String name = 'IMG_001.jpg',
  String folder = '相机',
  String path = '2026/旅行/IMG_001.jpg',
  bool video = false,
}) => MediaView(
  id: 'photo',
  deviceId: 'peer',
  name: name,
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  size: 2 * 1024 * 1024,
  modified: DateTime.utc(2026, 10, 17, 14, 35, 20),
  thumbnail: Uint8List(0),
  sharedFolderName: folder,
  relativePath: path,
);

Future<void> _show(
  WidgetTester tester,
  _Model model,
  MediaView item, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: AppLocale.current,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => MediaPreviewPage(model: model, item: item),
              ),
            ),
            child: const Text('打开图片'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开图片'));
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('preview-details')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'preview shows cached source, date, size and full offline details',
    (tester) async {
      final model = _Model();
      final item = _photo();
      final local = item.modified.toLocal();
      String pad(int value) => value.toString().padLeft(2, '0');
      final date = '${local.year}-${pad(local.month)}-${pad(local.day)}';
      final time =
          '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
      await _show(tester, model, item);

      expect(find.text(item.name), findsOneWidget);
      expect(find.text('来自 来源设备'), findsOneWidget);
      expect(find.text('$date · 2.0 MB · 图片'), findsOneWidget);
      await _openDetails(tester);
      expect(find.byKey(const Key('media-details-sheet')), findsOneWidget);
      expect(find.text('文件名'), findsOneWidget);
      expect(find.text('来源设备'), findsNWidgets(2));
      expect(find.text('离线'), findsOneWidget);
      expect(find.text('修改时间（本地）'), findsOneWidget);
      expect(find.text('$date $time'), findsOneWidget);
      expect(find.text('图片 · image/jpeg'), findsOneWidget);
      expect(find.text('2.0 MB（2097152 字节）'), findsOneWidget);
      await tester.ensureVisible(find.text(item.relativePath));
      expect(find.text('合集'), findsOneWidget);
      expect(find.text(item.sharedFolderName), findsOneWidget);
      expect(find.text('相对路径'), findsOneWidget);
      expect(find.text(item.relativePath), findsOneWidget);
      expect(model.unexpectedCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing and backing out of details preserve the preview route', (
    tester,
  ) async {
    final model = _Model();
    await _show(tester, model, _photo());
    await _openDetails(tester);
    await tester.tap(find.byKey(const Key('close-media-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-details-sheet')), findsNothing);
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    await _openDetails(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-details-sheet')), findsNothing);
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('preview-gesture-area')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsNothing);
    expect(find.text('打开图片'), findsOneWidget);
    expect(model.unexpectedCalls, isEmpty);
  });

  testWidgets('missing source records and empty optional metadata are safe', (
    tester,
  ) async {
    final model = _Model()..devices.clear();
    await _show(tester, model, _photo(folder: '', path: '', video: true));
    expect(find.text('来自 已记住的设备'), findsOneWidget);
    await _openDetails(tester);
    expect(find.text('已记住的设备'), findsOneWidget);
    expect(find.text('设备记录不可用'), findsOneWidget);
    expect(find.text('视频 · video/mp4'), findsOneWidget);
    expect(find.text('合集'), findsNothing);
    expect(find.text('相对路径'), findsNothing);
    expect(model.unexpectedCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long metadata scrolls on a narrow screen with large text', (
    tester,
  ) async {
    final model = _Model();
    model.devices[0] = DeviceView(
      id: 'peer',
      name: List.filled(20, '共享媒体设备').join(),
      address: '',
      online: true,
    );
    final item = _photo(
      name: '${List.filled(30, 'long-photo-name').join()}.jpg',
      folder: List.filled(20, '相机合集').join(),
      path: '${List.filled(30, '旅行照片/').join()}IMG_001.jpg',
    );
    await _show(tester, model, item, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('preview-gesture-area'))).height,
      greaterThan(100),
    );
    await _openDetails(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('media-details-sheet')),
        matching: find.text(item.name),
      ),
      findsOneWidget,
    );
    expect(find.text('在线'), findsOneWidget);
    await tester.ensureVisible(find.text(item.relativePath));
    await tester.pumpAndSettle();
    expect(find.text(item.relativePath), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('close-media-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-preview-page')), findsOneWidget);
    expect(model.unexpectedCalls, isEmpty);
  });
}
