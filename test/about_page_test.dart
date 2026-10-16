import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/app_info.dart';
import 'package:tamayura/ui/about_page.dart';

Future<AppVersion> _version() async => const AppVersion('2.3.4', '56');

Future<void> _show(WidgetTester tester, {Widget? child}) async {
  await tester.pumpWidget(
    MaterialApp(home: child ?? const AboutPage(loadVersion: _version)),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

class _RetryLicenseBundle extends CachingAssetBundle {
  int calls = 0;

  @override
  Future<ByteData> load(String key) async {
    expect(key, 'LICENSE');
    if (++calls == 1) throw StateError('unavailable');
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode('Apache License\nVersion 2.0, January 2004'),
      ),
    );
  }
}

void main() {
  testWidgets('about shows the installed version, summary and license', (
    tester,
  ) async {
    await _show(tester);
    expect(find.text('Tamayura · 玉响'), findsOneWidget);
    expect(find.text('2.3.4+56'), findsOneWidget);
    expect(find.textContaining('局域网设备之间'), findsOneWidget);
    expect(find.text('Apache-2.0'), findsOneWidget);
    expect(find.byKey(const Key('musings-entry')), findsOneWidget);
  });

  testWidgets('version read failures can retry without hiding project info', (
    tester,
  ) async {
    var attempts = 0;
    await _show(
      tester,
      child: AboutPage(
        loadVersion: () async {
          if (++attempts == 1) throw PlatformException(code: 'unavailable');
          return const AppVersion('3.0.0', '90');
        },
      ),
    );
    expect(find.text('暂时无法读取版本信息'), findsOneWidget);
    expect(find.text('Apache-2.0'), findsOneWidget);
    await _tap(tester, 'retry-app-version');
    expect(find.text('3.0.0+90'), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during a version lookup is safe', (tester) async {
    final pending = Completer<AppVersion>();
    await _show(tester, child: AboutPage(loadVersion: () => pending.future));
    expect(find.text('正在读取版本…'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.completeError(StateError('late platform failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('musings explain the anime, photography and birthday port', (
    tester,
  ) async {
    await _show(tester);
    await _tap(tester, 'musings-entry');
    expect(find.byKey(const Key('musings-page')), findsOneWidget);
    expect(find.textContaining('项目取名自动画《玉响》'), findsOneWidget);
    expect(find.textContaining('摄影让转瞬即逝'), findsOneWidget);
    final birthday = find.textContaining('1995 年 7 月 28 日');
    await tester.ensureVisible(birthday);
    expect(birthday, findsOneWidget);
    expect(find.textContaining('默认端口 50728'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project license opens the full bundled Apache text offline', (
    tester,
  ) async {
    await _show(tester);
    await _tap(tester, 'project-license-entry');
    await tester.runAsync(() => rootBundle.loadString('LICENSE'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-license-page')), findsOneWidget);
    final text = tester
        .widget<SelectableText>(find.byKey(const Key('project-license-text')))
        .data!;
    expect(text, contains('Version 2.0, January 2004'));
    expect(text, contains('Grant of Patent License'));
    expect(text, contains('END OF TERMS AND CONDITIONS'));
    expect(text.length, greaterThan(10000));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-page')), findsOneWidget);
  });

  testWidgets('license asset failures offer a working retry', (tester) async {
    final bundle = _RetryLicenseBundle();
    await _show(
      tester,
      child: DefaultAssetBundle(
        bundle: bundle,
        child: const ProjectLicensePage(),
      ),
    );
    expect(find.text('暂时无法读取许可正文'), findsOneWidget);
    await _tap(tester, 'retry-project-license');
    expect(find.textContaining('Version 2.0, January 2004'), findsOneWidget);
    expect(bundle.calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('third party licenses open and allow returning to about', (
    tester,
  ) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks([
        'sample_dependency',
      ], 'Example license');
    });
    await _show(tester);
    await _tap(tester, 'dependency-licenses-entry');
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('sample_dependency'), findsOneWidget);
    await tester.tap(find.text('sample_dependency'));
    await tester.pumpAndSettle();
    expect(find.text('Example license'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-page')), findsOneWidget);
  });

  testWidgets('about and musings scroll on a small phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _show(tester);
    expect(tester.takeException(), isNull);
    await _tap(tester, 'musings-entry');
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.textContaining('1995 年 7 月 28 日'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _tap(tester, 'project-license-entry');
    await tester.runAsync(() => rootBundle.loadString('LICENSE'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
