import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app/app_info.dart';
import '../l10n/app_locale.dart';
import '../update/update_platform.dart';
import '../update/update_service.dart';
import 'app_icons.dart';

/// Progress shown on the page, rendered in the current interface language.
enum _UpdateStatus {
  checking,
  upToDate,
  available,
  openedDownloadPage,
  downloading,
  verifying,
  preparing,
  exiting,
  handedToSystem,
  downloadCancelled,
  installed,
  pendingUserAction,
}

class UpdatePage extends StatefulWidget {
  const UpdatePage({
    super.key,
    required this.shutdown,
    this.service,
    this.platform = const UpdatePlatform(),
    this.loadVersion = AppVersion.load,
  });

  final Future<void> Function() shutdown;
  final UpdateService? service;
  final UpdatePlatform platform;
  final Future<AppVersion> Function() loadVersion;

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> with WidgetsBindingObserver {
  late final UpdateService _service = widget.service ?? UpdateService();
  AppVersion? _current;
  UpdateRelease? _release;
  File? _downloaded;
  UpdateCancellation? _cancellation;
  UpdateCancellation? _checkCancellation;
  Timer? _statusTimer;
  bool _busy = false;
  bool _installing = false;
  bool _exiting = false;
  bool _confirming = false;
  bool _readingStatus = false;
  _UpdateStatus _status = _UpdateStatus.checking;
  String? _error;
  int _received = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _statusTimer != null) {
      unawaited(_readStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancellation?.cancel();
    _checkCancellation?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  String _describe(Object error) {
    if (error is UpdateException) return error.message;
    if (error is PlatformException) {
      return error.message ?? context.l10n.updateSystemFailed;
    }
    return context.l10n.updateFailed;
  }

  Future<void> _check() async {
    if (_busy || _confirming || _exiting) return;
    _statusTimer?.cancel();
    _statusTimer = null;
    setState(() {
      _busy = true;
      _error = null;
      _status = _UpdateStatus.checking;
      _release = null;
      _downloaded = null;
    });
    try {
      final current = await widget.loadVersion();
      if (!mounted) return;
      final cancellation = UpdateCancellation();
      _checkCancellation = cancellation;
      final release = await _service.check(
        current,
        widget.platform.target,
        cancellation: cancellation,
      );
      if (!mounted) return;
      setState(() {
        _current = current;
        _release = release;
        _status = release == null
            ? _UpdateStatus.upToDate
            : _UpdateStatus.available;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      _checkCancellation = null;
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _release != null) await _confirm();
  }

  Future<void> _confirm() async {
    final release = _release;
    if (release == null || _busy || _confirming || _exiting) return;
    _confirming = true;
    final manual = widget.platform.target == UpdateTarget.macos;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.updateConfirmTitle(release.version)),
        content: SingleChildScrollView(
          child: Text(
            manual
                ? context.l10n.updateConfirmMac
                : '${context.l10n.updateConfirmAutomatic}\n\n'
                      '${widget.platform.target == UpdateTarget.android ? context.l10n.updateConfirmAndroid : context.l10n.updateConfirmWindows}',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('update-decline'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.updateDecline),
          ),
          FilledButton(
            key: const Key('update-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              manual
                  ? context.l10n.updateOpenDownloadPage
                  : context.l10n.updateDownloadAndInstall,
            ),
          ),
        ],
      ),
    );
    _confirming = false;
    if (accepted == true && mounted) await _update(release);
  }

  Future<void> _update(UpdateRelease release) async {
    if (_busy || _exiting) return;
    setState(() {
      _busy = true;
      _error = null;
      _received = 0;
      _total = 0;
    });
    try {
      if (widget.platform.target == UpdateTarget.macos) {
        await widget.platform.openRelease(release.pageUrl);
        if (mounted) {
          setState(() => _status = _UpdateStatus.openedDownloadPage);
        }
        return;
      }
      if (_downloaded == null) {
        final cancellation = UpdateCancellation();
        _cancellation = cancellation;
        setState(() => _status = _UpdateStatus.downloading);
        final directory = await widget.platform.directory();
        if (!mounted) return;
        _downloaded = await _service.download(
          release,
          directory,
          cancellation: cancellation,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _received = received;
              _total = total;
              if (received == total) _status = _UpdateStatus.verifying;
            });
          },
        );
        _cancellation = null;
      }
      if (!mounted) return;
      setState(() {
        _installing = true;
        _status = _UpdateStatus.preparing;
      });
      final result = await widget.platform.install(_downloaded!, release);
      if (!mounted) return;
      if (result == 'readyToExit') {
        setState(() {
          _exiting = true;
          _status = _UpdateStatus.exiting;
        });
        await widget.shutdown();
        await widget.platform.exitForUpdate();
      } else {
        setState(() => _status = _UpdateStatus.handedToSystem);
        _statusTimer?.cancel();
        _statusTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_readStatus()),
        );
      }
    } on UpdateCancelledException {
      if (mounted) setState(() => _status = _UpdateStatus.downloadCancelled);
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      _cancellation = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _installing = false;
        });
      }
    }
  }

  Future<void> _readStatus() async {
    if (_readingStatus || _busy || !mounted) return;
    _readingStatus = true;
    try {
      final status = await widget.platform.status();
      if (!mounted) return;
      final state = status['state'];
      if (state == 'failed' || state == 'permissionRequired') {
        _statusTimer?.cancel();
        _statusTimer = null;
        setState(
          () => _error =
              status['message'] as String? ??
              context.l10n.updateInstallIncomplete,
        );
      } else if (state == 'succeeded') {
        _statusTimer?.cancel();
        _statusTimer = null;
        setState(() => _status = _UpdateStatus.installed);
      } else if (state == 'pendingUserAction') {
        setState(() => _status = _UpdateStatus.pendingUserAction);
      }
    } catch (error) {
      _statusTimer?.cancel();
      _statusTimer = null;
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      _readingStatus = false;
    }
  }

  Future<void> _retryExit() async {
    setState(() => _error = null);
    try {
      try {
        await widget.platform.exitForUpdate();
      } on PlatformException catch (error) {
        if (error.code != 'UPDATE_NOT_READY') rethrow;
        await widget.platform.install(_downloaded!, _release!);
        await widget.platform.exitForUpdate();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    }
  }

  String _statusText(AppLocalizations l10n) => switch (_status) {
    _UpdateStatus.checking => l10n.updateChecking,
    _UpdateStatus.upToDate => l10n.updateUpToDate,
    _UpdateStatus.available => l10n.updateAvailable(_release?.version ?? ''),
    _UpdateStatus.openedDownloadPage => l10n.updateOpenedDownloadPage,
    _UpdateStatus.downloading => l10n.updateDownloading,
    _UpdateStatus.verifying => l10n.updateVerifying,
    _UpdateStatus.preparing => l10n.updatePreparing,
    _UpdateStatus.exiting => l10n.updateExiting,
    _UpdateStatus.handedToSystem => l10n.updateHandedToSystem,
    _UpdateStatus.downloadCancelled => l10n.updateDownloadCancelled,
    _UpdateStatus.installed => l10n.updateInstalled,
    _UpdateStatus.pendingUserAction => l10n.updatePendingUserAction,
  };

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_installing && !_exiting,
    child: Scaffold(
      appBar: AppBar(title: Text(context.l10n.updateTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (_current != null)
                Text(
                  context.l10n.updateCurrentVersion(_current!.displayVersion),
                ),
              const SizedBox(height: 12),
              Text(
                _error == null
                    ? _statusText(context.l10n)
                    : context.l10n.updateIncomplete,
                key: const Key('update-status'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (_busy || _exiting) ...[
                LinearProgressIndicator(
                  value: _cancellation != null && _total > 0
                      ? _received / _total
                      : null,
                ),
                if (_total > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${(_received / 1048576).toStringAsFixed(1)} / '
                      '${(_total / 1048576).toStringAsFixed(1)} MiB',
                    ),
                  ),
                if (_cancellation != null)
                  TextButton(
                    key: const Key('update-cancel-download'),
                    onPressed: () => _cancellation?.cancel(),
                    child: Text(context.l10n.updateCancelDownload),
                  ),
              ],
              if (_error != null)
                Text(
                  _exiting
                      ? '$_error\n${context.l10n.updateExitFailedHint}'
                      : _error!,
                  key: const Key('update-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (_release != null)
                    FilledButton(
                      key: const Key('update-action'),
                      onPressed: _busy || _exiting || _statusTimer != null
                          ? null
                          : _confirm,
                      child: Text(
                        widget.platform.target == UpdateTarget.macos
                            ? context.l10n.updateOpenDownloadPage
                            : _downloaded != null
                            ? context.l10n.updateRetryInstall
                            : context.l10n.updateDownloadAndInstall,
                      ),
                    ),
                  OutlinedButton.icon(
                    key: const Key('update-check-again'),
                    onPressed: _busy || _exiting || _statusTimer != null
                        ? null
                        : _check,
                    icon: const Icon(AppIcons.refresh),
                    label: Text(context.l10n.updateCheckAgain),
                  ),
                  if (_exiting && _error != null)
                    FilledButton(
                      key: const Key('update-retry-exit'),
                      onPressed: _retryExit,
                      child: Text(context.l10n.updateFinishExit),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(context.l10n.updateSourceNote),
              if (_release != null) ...[
                const SizedBox(height: 24),
                Text(
                  context.l10n.updateReleaseNotes,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _release!.notes.isEmpty
                      ? context.l10n.updateNoReleaseNotes
                      : _release!.notes,
                  key: const Key('update-release-notes'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
