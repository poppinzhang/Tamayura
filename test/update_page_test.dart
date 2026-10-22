import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/app/app_info.dart';
import 'package:tamayura/l10n/app_locale.dart';
import 'package:tamayura/ui/update_page.dart';
import 'package:tamayura/update/update_platform.dart';
import 'package:tamayura/update/update_service.dart';

final _release = UpdateRelease(
  version: '0.8.0',
  buildNumber: 12,
  notes: '更新说明：新增功能与修复。',
  pageUrl: Uri.parse(
    'https://github.com/poppinzhang/Tamayura/releases/tag/v0.8.0',
  ),
  asset: UpdateAsset(
    filename: 'Tamayura-0.8.0-android.apk',
    url: Uri.parse(
      'https://github.com/poppinzhang/Tamayura/releases/download/v0.8.0/Tamayura-0.8.0-android.apk',
    ),
    sizeBytes: 1024,
    sha256: 'a' * 64,
  ),
);

class _Service extends UpdateService {
  UpdateRelease? release = _release;
  Object? checkError;
  Completer<UpdateRelease?>? checking;
  Completer<File>? downloading;
  UpdateCancellation? downloadCancellation;
  UpdateCancellation? checkCancellation;
  int checks = 0, downloads = 0;

  @override
  Future<UpdateRelease?> check(
    AppVersion current,
    UpdateTarget target, {
    UpdateCancellation? cancellation,
  }) async {
    checks++;
    checkCancellation = cancellation;
    if (checkError != null) throw checkError!;
    return checking == null ? release : checking!.future;
  }

  @override
  Future<File> download(
    UpdateRelease release,
    Directory directory, {
    void Function(int, int)? onProgress,
    UpdateCancellation? cancellation,
  }) async {
    downloads++;
    downloadCancellation = cancellation;
    onProgress?.call(512, 1024);
    return downloading == null
        ? File('updates/package.apk')
        : downloading!.future;
  }
}

class _Platform extends UpdatePlatform {
  _Platform(UpdateTarget target) : super(targetOverride: target);

  final events = <String>[];
  Object? installError;
  Object? openError;
  Object? exitError;
  bool refreshExpiredHelper = false;
  Map<String, dynamic> installStatus = {'state': 'started'};
  Uri? opened;

  @override
  Future<Directory> directory() async => Directory('updates');

  @override
  Future<String> install(File file, UpdateRelease release) async {
    events.add('install');
    if (installError != null) throw installError!;
    if (refreshExpiredHelper) exitError = null;
    return target == UpdateTarget.windows ? 'readyToExit' : 'started';
  }

  @override
  Future<void> openRelease(Uri url) async {
    if (openError != null) throw openError!;
    opened = url;
    events.add('open');
  }

  @override
  Future<void> exitForUpdate() async {
    events.add('exit');
    if (exitError != null) throw exitError!;
  }

  @override
  Future<Map<String, dynamic>> status() async => installStatus;
}

Future<void> _show(
  WidgetTester tester,
  _Service service,
  _Platform platform, {
  Future<void> Function()? shutdown,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocale.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: AppLocale.current,
      home: UpdatePage(
        service: service,
        platform: platform,
        loadVersion: () async => const AppVersion('0.7.0', '11'),
        shutdown: shutdown ?? () async => platform.events.add('shutdown'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('no release reports latest without prompting or downloading', (
    tester,
  ) async {
    final service = _Service()..release = null;
    final platform = _Platform(UpdateTarget.android);
    await _show(tester, service, platform);
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('当前版本 0.7.0+11'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.downloads, 0);
  });

  testWidgets('new release requires explicit confirmation', (tester) async {
    final service = _Service();
    final platform = _Platform(UpdateTarget.android);
    await _show(tester, service, platform);
    expect(find.text('更新至 0.8.0？'), findsOneWidget);
    expect(service.downloads, 0);
    await _tap(tester, 'update-decline');
    expect(service.downloads, 0);
    expect(platform.events, isEmpty);
    expect(find.text(_release.notes), findsOneWidget);
  });

  testWidgets(
    'Android downloads and starts installation only after confirming',
    (tester) async {
      final service = _Service();
      final platform = _Platform(UpdateTarget.android);
      await _show(tester, service, platform);
      await _tap(tester, 'update-confirm');
      expect(service.downloads, 1);
      expect(platform.events, ['install']);
      expect(find.text('已交给系统安装，请完成系统提示'), findsOneWidget);
      platform.installStatus = {'state': 'failed', 'message': '已取消安装，请重试'};
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('已取消安装，请重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('installation permission errors retry the verified package', (
    tester,
  ) async {
    final service = _Service();
    final platform = _Platform(UpdateTarget.android)
      ..installError = PlatformException(
        code: 'UPDATE_PERMISSION_REQUIRED',
        message: '请允许安装此来源的应用',
      );
    await _show(tester, service, platform);
    await _tap(tester, 'update-confirm');
    expect(find.text('请允许安装此来源的应用'), findsOneWidget);
    expect(find.text('重试安装'), findsOneWidget);
    platform.installError = null;
    await _tap(tester, 'update-action');
    await _tap(tester, 'update-confirm');
    expect(service.downloads, 1);
    expect(platform.events, ['install', 'install']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'macOS opens the selected release and never downloads or installs',
    (tester) async {
      final service = _Service();
      final platform = _Platform(UpdateTarget.macos);
      await _show(tester, service, platform);
      expect(platform.opened, isNull);
      await _tap(tester, 'update-confirm');
      expect(platform.opened, _release.pageUrl);
      expect(service.downloads, 0);
      expect(platform.events, ['open']);
      expect(find.text('已打开此版本的下载页面，请手动完成升级'), findsOneWidget);
    },
  );

  testWidgets(
    'Linux opens the selected release with archive instructions only',
    (tester) async {
      final service = _Service();
      final platform = _Platform(UpdateTarget.linux);
      await _show(tester, service, platform);
      expect(find.textContaining('对应架构的 Linux 压缩包'), findsOneWidget);
      expect(find.textContaining('macOS 安装包'), findsNothing);
      expect(find.text('打开下载页面'), findsWidgets);
      await _tap(tester, 'update-confirm');
      expect(platform.opened, _release.pageUrl);
      expect(service.downloads, 0);
      expect(platform.events, ['open']);
      expect(find.text('已打开此版本的下载页面，请手动完成升级'), findsOneWidget);
    },
  );

  testWidgets('macOS browser failures are visible and retryable', (
    tester,
  ) async {
    final platform = _Platform(UpdateTarget.macos)
      ..openError = PlatformException(
        code: 'OPEN_RELEASE_FAILED',
        message: '无法打开浏览器',
      );
    await _show(tester, _Service(), platform);
    await _tap(tester, 'update-confirm');
    expect(find.text('无法打开浏览器'), findsOneWidget);
    platform.openError = null;
    await _tap(tester, 'update-action');
    await _tap(tester, 'update-confirm');
    expect(platform.opened, _release.pageUrl);
  });

  testWidgets('Windows prepares first, then awaits shutdown before exiting', (
    tester,
  ) async {
    final platform = _Platform(UpdateTarget.windows);
    await _show(tester, _Service(), platform);
    await _tap(tester, 'update-confirm');
    expect(platform.events, ['install', 'shutdown', 'exit']);
    expect(find.text('正在结束传输，安装后将重新打开玉响…'), findsOneWidget);
  });

  testWidgets(
    'Windows preparation failure keeps the current application running',
    (tester) async {
      final platform = _Platform(UpdateTarget.windows)
        ..installError = PlatformException(
          code: 'UPDATE_PREPARE_FAILED',
          message: '安装目录不可写',
        );
      await _show(tester, _Service(), platform);
      await _tap(tester, 'update-confirm');
      expect(platform.events, ['install']);
      expect(find.text('安装目录不可写'), findsOneWidget);
    },
  );

  testWidgets('Windows exit failure can retry without preparing twice', (
    tester,
  ) async {
    final platform = _Platform(UpdateTarget.windows)
      ..exitError = PlatformException(code: 'EXIT_FAILED', message: '退出失败');
    await _show(tester, _Service(), platform);
    await _tap(tester, 'update-confirm');
    platform.exitError = null;
    await _tap(tester, 'update-retry-exit');
    expect(platform.events, ['install', 'shutdown', 'exit', 'exit']);
  });

  testWidgets('Windows waits for shutdown to finish before requesting exit', (
    tester,
  ) async {
    final platform = _Platform(UpdateTarget.windows);
    final stopped = Completer<void>();
    await _show(
      tester,
      _Service(),
      platform,
      shutdown: () async {
        platform.events.add('shutdown-start');
        await stopped.future;
        platform.events.add('shutdown-finished');
      },
    );
    await _tap(tester, 'update-confirm');
    expect(platform.events, ['install', 'shutdown-start']);
    stopped.complete();
    await tester.pump();
    expect(platform.events, [
      'install',
      'shutdown-start',
      'shutdown-finished',
      'exit',
    ]);
  });

  testWidgets(
    'Windows can prepare a replacement helper after its wait expires',
    (tester) async {
      final platform = _Platform(UpdateTarget.windows)
        ..exitError = PlatformException(
          code: 'UPDATE_NOT_READY',
          message: '安装进程已结束',
        );
      await _show(tester, _Service(), platform);
      await _tap(tester, 'update-confirm');
      platform.refreshExpiredHelper = true;
      await _tap(tester, 'update-retry-exit');
      expect(platform.events, [
        'install',
        'shutdown',
        'exit',
        'exit',
        'install',
        'exit',
      ]);
    },
  );

  testWidgets('failed checks are never presented as latest and can retry', (
    tester,
  ) async {
    final service = _Service()
      ..checkError = const UpdateException('GitHub 请求受限，请稍后重试');
    await _show(tester, service, _Platform(UpdateTarget.android));
    expect(find.text('已是最新版本'), findsNothing);
    expect(find.text('GitHub 请求受限，请稍后重试'), findsOneWidget);
    service.checkError = null;
    service.release = null;
    await _tap(tester, 'update-check-again');
    expect(find.text('已是最新版本'), findsOneWidget);
  });

  testWidgets('cancelled downloads never launch the installer', (tester) async {
    final service = _Service()..downloading = Completer<File>();
    final platform = _Platform(UpdateTarget.android);
    await _show(tester, service, platform);
    await _tap(tester, 'update-confirm');
    await _tap(tester, 'update-cancel-download');
    expect(service.downloadCancellation!.isCancelled, isTrue);
    service.downloading!.completeError(const UpdateCancelledException());
    await tester.pump();
    expect(find.text('已取消下载'), findsOneWidget);
    expect(platform.events, isEmpty);
  });

  testWidgets('leaving during a check cancels it and ignores late results', (
    tester,
  ) async {
    final service = _Service()..checking = Completer<UpdateRelease?>();
    final platform = _Platform(UpdateTarget.android);
    await _show(tester, service, platform);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(service.checkCancellation!.isCancelled, isTrue);
    service.checking!.complete(_release);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmation and notes fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _show(tester, _Service(), _Platform(UpdateTarget.android));
    expect(tester.takeException(), isNull);
    await _tap(tester, 'update-decline');
    expect(tester.takeException(), isNull);
  });
}
