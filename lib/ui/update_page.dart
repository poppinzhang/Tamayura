import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_info.dart';
import '../update/update_platform.dart';
import '../update/update_service.dart';

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
  String _message = '正在检查更新…';
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
      return error.message ?? '系统无法完成更新，请重试';
    }
    return '更新操作失败，请检查网络、磁盘空间及安装权限后重试';
  }

  Future<void> _check() async {
    if (_busy || _confirming || _exiting) return;
    _statusTimer?.cancel();
    _statusTimer = null;
    setState(() {
      _busy = true;
      _error = null;
      _message = '正在检查更新…';
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
        _message = release == null ? '已是最新版本' : '发现新版本 ${release.version}';
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
        title: Text('更新至 ${release.version}？'),
        content: SingleChildScrollView(
          child: Text(
            manual
                ? '将打开此版本的 GitHub Release 页面，请下载 macOS 安装包并手动完成升级。'
                : '确认后下载并校验安装包，完成后自动发起安装。更新会中断共享和传输，未完成的下载可在重新打开后重试。'
                      '\n\nv1.0.0 前不保证旧数据或跨版本互联兼容，请阅读更新说明；必要时需重新选择目录并连接设备。'
                      '${widget.platform.target == UpdateTarget.android ? '\n\nAndroid 可能要求允许安装此来源的应用，并在系统界面确认。' : '\n\nWindows 将退出并重新启动玉响。'}',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('update-decline'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不更新'),
          ),
          FilledButton(
            key: const Key('update-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(manual ? '打开下载页面' : '下载并安装'),
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
        if (mounted) setState(() => _message = '已打开此版本的下载页面，请手动完成升级');
        return;
      }
      if (_downloaded == null) {
        final cancellation = UpdateCancellation();
        _cancellation = cancellation;
        setState(() => _message = '正在下载安装包…');
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
              if (received == total) _message = '正在校验安装包…';
            });
          },
        );
        _cancellation = null;
      }
      if (!mounted) return;
      setState(() {
        _installing = true;
        _message = '正在准备安装…';
      });
      final result = await widget.platform.install(_downloaded!, release);
      if (!mounted) return;
      if (result == 'readyToExit') {
        setState(() {
          _exiting = true;
          _message = '正在结束传输，安装后将重新打开玉响…';
        });
        await widget.shutdown();
        await widget.platform.exitForUpdate();
      } else {
        setState(() => _message = '已交给系统安装，请完成系统提示');
        _statusTimer?.cancel();
        _statusTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_readStatus()),
        );
      }
    } on UpdateCancelledException {
      if (mounted) setState(() => _message = '已取消下载');
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
        setState(() => _error = status['message'] as String? ?? '安装未完成，请重试');
      } else if (state == 'succeeded') {
        _statusTimer?.cancel();
        _statusTimer = null;
        setState(() => _message = '安装完成，请重新打开玉响');
      } else if (state == 'pendingUserAction') {
        setState(() => _message = '请在系统安装界面确认更新');
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_installing && !_exiting,
    child: Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (_current != null) Text('当前版本 ${_current!.displayVersion}'),
              const SizedBox(height: 12),
              Text(
                _error == null ? _message : '更新未完成',
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
                    child: const Text('取消下载'),
                  ),
              ],
              if (_error != null)
                Text(
                  _exiting
                      ? '$_error\n应用已停止共享和传输，可重试完成安装；如仍失败，请从系统托盘选择「退出玉响」后重新打开。'
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
                            ? '打开下载页面'
                            : _downloaded != null
                            ? '重试安装'
                            : '下载并安装',
                      ),
                    ),
                  OutlinedButton.icon(
                    key: const Key('update-check-again'),
                    onPressed: _busy || _exiting || _statusTimer != null
                        ? null
                        : _check,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新检查'),
                  ),
                  if (_exiting && _error != null)
                    FilledButton(
                      key: const Key('update-retry-exit'),
                      onPressed: _retryExit,
                      child: const Text('完成退出并安装'),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('从 GitHub 获取已公开版本（包括预发布），需要互联网连接。'),
              if (_release != null) ...[
                const SizedBox(height: 24),
                Text('更新说明', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                SelectableText(
                  _release!.notes.isEmpty ? '此版本未提供更新说明。' : _release!.notes,
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
