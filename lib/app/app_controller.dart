import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../data/repository.dart';
import '../data/transfer_store.dart';
import '../core/transfer_task.dart';
import 'errors.dart';
export 'errors.dart' show describeError;
import '../network/media_rpc.dart';
import '../platform/platform_bridge.dart';
import '../platform/default_bridge.dart';
import '../background/transfer_scheduler.dart';
import 'endpoint.dart';
import 'view_state.dart';

class AppController extends TamayuraModel {
  AppController({
    PlatformBridge? bridge,
    TransferScheduler? transferScheduler,
    Future<TamayuraRepository> Function()? openRepository,
    Future<TransferStore> Function()? openTransfers,
    MediaRpcClient Function(Peer)? clientFactory,
    int preferredPort = LanEndpoint.defaultPort,
    DateTime Function()? clock,
    Duration resumeRescanInterval = const Duration(seconds: 30),
  }) : _bridge = bridge ?? defaultPlatformBridge(),
       _transferScheduler = transferScheduler,
       _preferredPort = preferredPort,
       _openRepository = openRepository ?? TamayuraRepository.open,
       _openTransfers = openTransfers ?? TransferStore.open,
       _clientFactory = clientFactory ?? MediaRpcClient.new,
       _clock = clock ?? DateTime.now,
       _resumeRescanInterval = resumeRescanInterval;
  final PlatformBridge _bridge;
  TransferScheduler? _transferScheduler;
  final int _preferredPort;
  final MediaRpcClient Function(Peer) _clientFactory;
  final DateTime Function() _clock;
  final Duration _resumeRescanInterval;
  final Map<String, Peer> _activePeers = {}, _pendingPeers = {};
  final Future<TamayuraRepository> Function() _openRepository;
  final Future<TransferStore> Function() _openTransfers;
  TransferStore? _taskStore;
  Timer? _transferPoll;
  bool _foreground = true, _polling = false;
  bool _transferRefreshPending = false;
  SharingStatus _sharingStatus = const SharingStatus(
    enabled: false,
    running: false,
    batteryExempt: false,
  );
  bool _backgroundSharingSaving = false;
  int _sharingCommand = 0;
  int _sharingStatusRevision = 0;
  String? _failedSharingSession, _sharingFailure;
  StreamSubscription<SharingStatus>? _sharingSubscription;
  Future<void>? _initializing;
  bool _initialized = false;
  bool _initializationCancelled = false;
  _SharingStartup? _initializationStartup, _networkStartup;
  Future<TamayuraRepository>? _openingRepository;
  Future<TransferStore>? _openingTransfers;
  Future<void> _networkTail = Future.value();
  final Set<String> _scheduling = {};
  MediaCursor? _cursor;
  bool _hasMore = false, _loadingMore = false;
  int _pageGeneration = 0;
  Future<void> _reloadTail = Future.value();
  int _loadedMediaLimit = 60;
  final Map<String, SyncProgress> _syncProgress = {};
  final Map<String, Object> _syncProgressOwners = {};
  final Map<String, Peer> _syncCandidates = {};
  Timer? _syncRefreshTimer;
  bool _syncRefreshPending = false, _syncRefreshRunning = false;
  TamayuraRepository? _repository;
  MediaRpcServer? _server;
  _PlatformMediaSource? _source;
  StreamSubscription<Map<String, dynamic>>? _discovery;
  final Map<String, Peer> _peers = {};
  final Set<String> _online = {}, _connecting = {};
  final Map<String, Object> _presenceChecks = {};
  final Set<MediaRpcClient> _rpcClients = {};
  int _presenceGeneration = 0;
  final Map<String, MediaItem> _items = {};
  final Map<String, TransferView> _transfers = {};
  String _id = '', _deviceName = '我的设备';
  List<String> _addresses = [];
  List<SharedFolder> _sharedFolders = [];
  List<MediaCollection> _collections = [];
  String? _selectedCollectionKey;
  String? _downloadUri, _downloadFolder;
  String? _selectedDeviceId, _error;
  bool _loading = true, _busy = false, _disposed = false;
  ThemeMode _themeMode = ThemeMode.system;
  bool _themeModeSaving = false;
  int _localCount = 0, _totalMediaCount = 0;

  @override
  ThemeMode get themeMode => _themeMode;
  @override
  bool get backgroundSharingEnabled => _sharingStatus.enabled;
  @override
  bool get backgroundSharingRunning =>
      _sharingStatus.running && _sharingFailure == null;
  @override
  bool get backgroundSharingStarting =>
      _sharingStatus.starting && _sharingFailure == null;
  @override
  String? get backgroundSharingError => _sharingStatus.error ?? _sharingFailure;
  @override
  bool get backgroundSharingSaving => _backgroundSharingSaving;
  @override
  bool get batteryOptimizationExempt => _sharingStatus.batteryExempt;

  // A preference or a pending start is not permission to run headlessly. Only
  // an accepted native service session owns the foreground service/wake lock.
  bool get _hasSharingSession =>
      _sharingStatus.enabled &&
      _sharingStatus.sessionId != null &&
      _sharingStatus.sessionId != _failedSharingSession;
  bool get _shouldShare =>
      !_disposed &&
      (_foreground ||
          _hasSharingSession ||
          (_sharingStatus.running && _sharingFailure == null));
  @override
  bool get themeModeSaving => _themeModeSaving;
  @override
  bool get loading => _loading;
  @override
  bool get busy => _busy;
  @override
  String? get error => _error;
  @override
  String get deviceName => _deviceName;
  @override
  List<String> get addresses => List.unmodifiable(_addresses);
  @override
  int get port => _server?.port ?? 0;
  @override
  List<SharedFolder> get sharedFolders => List.unmodifiable(_sharedFolders);
  @override
  List<MediaCollection> get collections => List.unmodifiable(_collections);
  @override
  String? get selectedCollectionKey => _selectedCollectionKey;
  MediaCollection? get _selectedCollection => _collections
      .where((collection) => collection.key == _selectedCollectionKey)
      .firstOrNull;
  @override
  String? get downloadFolder => _downloadFolder;
  @override
  int get localMediaCount => _localCount;
  @override
  String? get selectedDeviceId => _selectedDeviceId;
  @override
  Map<String, TransferView> get transfers => Map.unmodifiable(_transfers);
  @override
  List<DeviceView> get devices =>
      _peers.values
          .map(
            (peer) => DeviceView(
              id: peer.id,
              name: peer.name,
              address: '${peer.host}:${peer.port}',
              online: _online.contains(peer.id),
              lastSync: peer.lastSync,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  @override
  List<MediaView> get media => _items.values.map(_view).toList();
  static MediaView _view(MediaItem item) => MediaView(
    id: item.id,
    deviceId: item.deviceId,
    name: item.name,
    sharedFolderId: item.sharedFolderId,
    sharedFolderName: item.sharedFolderName,
    relativePath: item.relativePath,
    mimeType: item.mimeType,
    size: item.size,
    modified: DateTime.fromMillisecondsSinceEpoch(item.modifiedMs),
    thumbnail: item.thumbnail,
  );
  @override
  bool get hasMoreMedia => _hasMore;
  @override
  int get totalMediaCount => _totalMediaCount;
  @override
  bool get loadingMoreMedia => _loadingMore;
  @override
  List<SyncProgress> get syncProgress =>
      List.unmodifiable(_syncProgress.values);

  Future<void> setForeground(bool foreground) async {
    if (_disposed) return;
    _foreground = foreground;
    _updateTransferPolling();
    if (_loading) return;
    if (!_initialized) {
      if (foreground) await initialize();
      return;
    }
    if (foreground) {
      try {
        await _readSharingStatus();
      } catch (e) {
        _error = describeError(e);
        _notify();
      }
    }
    await _reconcileSharing();
  }

  void _updateTransferPolling() {
    _transferPoll?.cancel();
    if (_foreground && _initialized && !_disposed) {
      unawaited(_refreshTransfers());
      _transferPoll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_refreshTransfers()),
      );
    }
  }

  Future<void> _readSharingStatus() async {
    final revision = _sharingStatusRevision;
    final status = await _bridge.sharingStatus();
    if (!_disposed && revision == _sharingStatusRevision) {
      _applySharingStatus(status);
    }
  }

  void _applySharingStatus(SharingStatus status) {
    if (_disposed) return;
    _sharingStatusRevision++;
    final previousError = backgroundSharingError;
    final wasStarting = _sharingStatus.starting;
    if (status.sessionId != _sharingStatus.sessionId || !status.enabled) {
      _sharingFailure = null;
    }
    _sharingStatus = status;
    for (final startup in [_initializationStartup, _networkStartup]) {
      if (startup == null || startup.cancelled) continue;
      startup.sessionId ??= status.sessionId;
      if ((startup.sessionId != null &&
              startup.sessionId != status.sessionId) ||
          (wasStarting &&
              status.error != null &&
              !status.starting &&
              !status.running)) {
        startup.cancel();
        ++_pageGeneration;
      }
    }
    if (_error == previousError) _error = null;
    if (status.error != null) _error = status.error;
    _notify();
    if (!_loading) {
      if (_initialized) {
        unawaited(_reconcileSharing());
      } else if (_hasSharingSession || (_foreground && !status.enabled)) {
        unawaited(initialize());
      }
    }
  }

  @override
  Future<void> setBackgroundSharing(bool enabled) async {
    final cancelStarting =
        !enabled && _sharingStatus.enabled && _sharingStatus.starting;
    if (_disposed ||
        ((_loading || _backgroundSharingSaving) && !cancelStarting)) {
      return;
    }
    final command = ++_sharingCommand;
    _backgroundSharingSaving = true;
    _error = null;
    _notify();
    try {
      final revision = _sharingStatusRevision;
      final status = await _bridge.setBackgroundSharing(enabled);
      if (_disposed || command != _sharingCommand) return;
      if (!_disposed && revision == _sharingStatusRevision) {
        _applySharingStatus(status);
      }
      await _readSharingStatus();
    } catch (e) {
      if (_disposed || command != _sharingCommand) return;
      // Native preserves the user's choice and its diagnostic for retry.
      try {
        await _readSharingStatus();
      } catch (_) {}
      if (_disposed || command != _sharingCommand) return;
      _error = describeError(e);
    } finally {
      if (command == _sharingCommand) {
        // A stop must stay responsive even if a scan is still completing.
        if (!cancelStarting && backgroundSharingError == null) {
          await _reconcileSharing();
        } else {
          unawaited(_reconcileSharing());
        }
        _backgroundSharingSaving = false;
        _notify();
      }
    }
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {
    try {
      await _bridge.openBatteryOptimizationSettings();
    } catch (e) {
      _error = describeError(e);
      _notify();
    }
  }

  // Serialize lifecycle changes, scans, and restarts: a late start must never
  // re-open a listener after the user has disabled background sharing.
  Future<void> _networkOperation(Future<void> Function() operation) {
    final next = _networkTail.then((_) => operation());
    _networkTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _reconcileSharing() async {
    if (_loading || !_initialized) return;
    await _networkOperation(() async {
      final startup = _SharingStartup(_sharingStatus.sessionId);
      final needsReady = _hasSharingSession && !_sharingStatus.running;
      _networkStartup = startup;
      try {
        if (_shouldShare) {
          if (needsReady &&
              (_server?.port ?? 0) != 0 &&
              _server!.scanError != null) {
            // A new service session may retry after a directory permission or
            // provider failure without recreating the application engine.
            await startup.wait(_server!.refresh);
            _localCount = _server!.localMedia.length;
          }
          if ((_server?.port ?? 0) == 0 || needsReady) {
            await _startNetwork(startup: startup);
          }
          await _confirmSharingReady(startup.sessionId, startup: startup);
        } else {
          await _stopNetwork();
        }
      } on _SharingStartupCancelled {
        // Stop invalidates an outstanding server start/refresh before releasing
        // the serialized queue, so its late completion cannot reopen a socket.
        await _stopNetwork();
      } catch (e) {
        await _failSharing(startup.sessionId, e);
        if (!_shouldShare) await _stopNetwork();
      } finally {
        if (identical(_networkStartup, startup)) _networkStartup = null;
      }
    }).catchError((Object e) {
      _error = describeError(e);
      _notify();
    });
  }

  bool _ownsSharingSession(String? sessionId) =>
      !_disposed &&
      sessionId != null &&
      sessionId == _sharingStatus.sessionId &&
      _hasSharingSession;

  Future<void> _confirmSharingReady(
    String? sessionId, {
    _SharingStartup? startup,
  }) async {
    if (!_ownsSharingSession(sessionId) || _sharingStatus.running) return;
    final server = _server;
    if (!_initialized || server == null || server.port == 0) return;
    if (server.scanError != null) throw server.scanError!;
    // Binding a socket alone does not prove Dart's service can handle RPCs.
    final probe = MediaRpcClient(
      Peer(id: _id, name: _deviceName, host: '127.0.0.1', port: server.port),
    );
    try {
      Future<Peer> identityRequest() =>
          probe.identity().timeout(const Duration(seconds: 5));
      final identity = await (startup == null
          ? identityRequest()
          : startup.wait(identityRequest));
      if (identity.id != _id) throw StateError('共享服务身份核验失败');
    } finally {
      await probe.close();
    }
    if (!_ownsSharingSession(sessionId)) return;
    Future<bool> report() => _bridge.reportSharingReady(sessionId!);
    final accepted = await (startup == null ? report() : startup.wait(report));
    if (!_ownsSharingSession(sessionId)) return;
    await _readSharingStatus();
    if (!accepted && _ownsSharingSession(sessionId)) {
      throw StateError('后台共享启动确认失败，请重试');
    }
  }

  Future<void> _failSharing(String? sessionId, Object error) async {
    // Never let a late failure from a stopped session cancel a newer start.
    if (sessionId != null && !_ownsSharingSession(sessionId)) return;
    final message = describeError(error);
    _error = message;
    if (sessionId != null) {
      _failedSharingSession = sessionId;
      _sharingFailure = message;
      _notify();
      try {
        await _bridge.reportSharingFailure(sessionId, message);
        await _readSharingStatus();
      } catch (_) {
        // Keep the failure visible even if the channel fails. The native ready
        // deadline also releases the service's resources in this case.
      }
    }
    _notify();
  }

  Future<void> _stopNetwork() async {
    _invalidatePresenceChecks();
    await _discovery?.cancel();
    _discovery = null;
    try {
      await _bridge.stopDiscovery();
    } finally {
      await _server?.stop();
      _online.clear();
      _notify();
    }
  }

  Future<void> _refreshTransfers() async {
    if (_taskStore == null || _disposed) return;
    if (_polling) {
      _transferRefreshPending = true;
      return;
    }
    _polling = true;
    try {
      final candidates = await _taskStore!.recent();
      if (_scheduling.isEmpty) {
        final scheduled = (await _transferScheduler!.scheduledTransferIds())
            .toSet();
        if (_scheduling.isEmpty) {
          await _taskStore!.reconcile(scheduled, candidates: candidates);
        }
      }
      final currentTasks = await _taskStore!.recent();
      final keys = currentTasks.map((task) => task.item.key).toSet();
      for (final removed in _transferTaskKeys.difference(keys)) {
        final previous = _transfers[removed];
        final item = previous?.item;
        final saved = item == null
            ? null
            : await _repository!.getDownload(item.deviceId, item.id);
        if (saved == null) {
          _transfers.remove(removed);
        } else {
          // A final native write may win a race with discard, or a completed
          // task may age out of recent history. The saved URI stays authoritative.
          _transfers[removed] = TransferView(
            progress: 1,
            savedUri: saved.uri,
            status: TransferStatus.completed,
            item: item,
            receivedBytes: item!.size,
            totalBytes: item.size,
          );
        }
      }
      _transferTaskKeys = keys;
      for (final task in currentTasks) {
        _transfers[task.item.key] = TransferView(
          progress: task.item.size == 0
              ? (task.state == DownloadState.completed ? 1 : 0)
              : (task.received / task.item.size).clamp(0, 1),
          savedUri: task.savedUri,
          error: task.error,
          item: _view(task.item),
          receivedBytes: task.received,
          totalBytes: task.item.size,
          attempt: task.attempt,
          status: TransferStatus.values.byName(task.state.name),
        );
      }
      _notify();
    } catch (e) {
      if (!_disposed) {
        _error = describeError(e);
        _notify();
      }
    } finally {
      _polling = false;
      // Desktop completion may arrive after the window's periodic polling has
      // stopped. Preserve that refresh even if a previous read is in flight.
      if (_transferRefreshPending && !_disposed) {
        _transferRefreshPending = false;
        unawaited(_refreshTransfers());
      }
    }
  }

  Set<String> _transferTaskKeys = {};

  Future<void> _cleanupTransferStaging() async {
    try {
      for (final task in await _taskStore!.recent()) {
        if (task.state == DownloadState.discarded) {
          await _transferScheduler!.cancelTransfer(task.id);
        }
      }
      final directory = Directory(await _bridge.transferDirectory());
      final active = (await _transferScheduler!.scheduledTransferIds()).toSet();
      await _taskStore!.cleanupStaging(directory, activeIds: active);
    } on MissingPluginException {
      // Platforms without native storage do not own a transfer directory.
    } catch (error) {
      _error = '部分下载暂存未能清理，可重试删除任务。${describeError(error)}';
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void clearError() {
    _error = null;
    _notify();
  }

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_disposed || _themeModeSaving || mode == _themeMode) return;
    final db = _repository;
    if (db == null || _loading) {
      _error = '应用尚未完成初始化，请重试后切换主题';
      _notify();
      return;
    }
    _themeModeSaving = true;
    _error = null;
    _notify();
    try {
      await db.setSetting('themeMode', mode.name);
      if (!_disposed) _themeMode = mode;
    } catch (_) {
      if (!_disposed) _error = '主题设置保存失败，请重试';
    } finally {
      _themeModeSaving = false;
      _notify();
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await action();
    } catch (e) {
      _error = describeError(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  Future<void> initialize() {
    if (_disposed || _initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
      // A new native start may arrive while an older initialization is still
      // unwinding. Retry that new session, never the failed session itself.
      if (!_initialized &&
          !_disposed &&
          (_hasSharingSession ||
              (_initializationCancelled &&
                  _foreground &&
                  !_sharingStatus.enabled))) {
        unawaited(initialize());
      }
    });
  }

  Future<void> _initialize() async {
    final startup = _SharingStartup(_sharingStatus.sessionId);
    _initializationStartup = startup;
    _initializationCancelled = false;
    _loading = true;
    _busy = true;
    _error = null;
    _notify();
    try {
      // Subscribe before identity/database work so even early cold-engine
      // failures can be reported to the native service waiting for readiness.
      _sharingSubscription ??= _bridge.sharingEvents.listen(
        _applySharingStatus,
        onError: (Object error) {
          _error = describeError(error);
          _notify();
        },
      );
      try {
        await startup.wait(_readSharingStatus);
      } on _SharingStartupCancelled {
        rethrow;
      } catch (e) {
        _error = describeError(e);
      }
      // Identity belongs to the platform installation/device, not the media cache.
      // Resolve it before opening stores so a failed read can be retried.
      _id = await startup.wait(_bridge.deviceId);
      await startup.wait(_ensureTransfers);
      await startup.wait(_ensureRepository);
      _transferScheduler ??= _bridge.usesInProcessTransfers
          ? InProcessTransferScheduler(
              store: _taskStore!,
              repository: _repository!,
              bridge: _bridge,
              clientFactory: _clientFactory,
              onChanged: _refreshTransfers,
            )
          : NativeTransferScheduler(_bridge);
      final db = _repository!;
      _themeMode = switch (await startup.wait(
        () => db.getSetting('themeMode'),
      )) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      final folders = await startup.wait(() => db.getSetting('sharedFolders'));
      _sharedFolders = folders == null
          ? []
          : (jsonDecode(folders) as List)
                .map(
                  (value) => SharedFolder.fromJson(
                    Map<String, dynamic>.from(value as Map),
                  ),
                )
                .toList();
      _downloadUri = await startup.wait(() => db.getSetting('downloadUri'));
      _downloadFolder = await startup.wait(
        () => db.getSetting('downloadFolder'),
      );
      _peers.clear();
      _syncProgress.clear();
      for (final peer in await startup.wait(db.listPeers)) {
        _peers[peer.id] = peer;
        final checkpoint = await startup.wait(() => db.findPeerSnapshot(peer));
        if (checkpoint != null) {
          _syncProgress[peer.id] = SyncProgress(
            peerId: peer.id,
            peerName: peer.name,
            phase: SyncPhase.failed,
            totalCount: checkpoint.totalCount,
            receivedCount: checkpoint.receivedCount,
            readyCount: checkpoint.readyCount,
          );
        }
      }
      final scheduled = await startup.wait(
        _transferScheduler!.scheduledTransferIds,
      );
      await startup.wait(() => _taskStore!.reconcile(scheduled.toSet()));
      await startup.wait(_cleanupTransferStaging);
      await startup.wait(_refreshTransfers);
      // Initialization may retry after a stalled read. Page generations discard
      // late results, without making the new attempt wait behind the old read.
      await startup.wait(() => _readCachedMedia(preserveWindow: false));
      _source = _PlatformMediaSource(_bridge, _id, () => sharedFolders, _clock);
      _initialized = true;
      _loading = false;
      _updateTransferPolling();
      _notify();
      await _reconcileSharing();
    } on _SharingStartupCancelled {
      // Native already published the stop/timeout. Preserve that diagnostic.
      _initializationCancelled = true;
    } catch (e) {
      await _failSharing(startup.sessionId, e);
    } finally {
      if (identical(_initializationStartup, startup)) {
        _initializationStartup = null;
      }
      _loading = false;
      _busy = false;
      _notify();
    }
    // The UI can browse its cache and choose folders during network requests.
    if (_initialized && _foreground && !_disposed) {
      await _syncRemembered();
    }
  }

  Future<void> _ensureRepository() async {
    if (_repository != null) return;
    await (_openingRepository ??= _openRepository()
        .then((repository) async {
          if (_disposed) {
            await repository.close();
          } else {
            _repository = repository;
          }
          return repository;
        })
        .whenComplete(() => _openingRepository = null));
  }

  Future<void> _ensureTransfers() async {
    if (_taskStore != null) return;
    await (_openingTransfers ??= _openTransfers()
        .then((transfers) async {
          if (_disposed) {
            await transfers.close();
          } else {
            _taskStore = transfers;
          }
          return transfers;
        })
        .whenComplete(() => _openingTransfers = null));
  }

  Future<void> _startNetwork({_SharingStartup? startup}) async {
    if (!_shouldShare) return;
    Future<T> wait<T>(Future<T> Function() action) =>
        startup == null ? action() : startup.wait(action);
    _source ??= _PlatformMediaSource(_bridge, _id, () => sharedFolders, _clock);
    final info = await wait(_bridge.localInfo);
    _deviceName = info['name'] as String? ?? _bridge.platformName;
    _addresses = (info['addresses'] as List? ?? []).cast<String>();
    _server ??= MediaRpcServer(
      identity: Peer(id: _id, name: _deviceName, host: '', port: 0),
      source: _source!,
    );
    _server!.updateDeviceName(_deviceName);
    if (_server!.port == 0) {
      try {
        await wait(() => _server!.start(port: _preferredPort));
      } on SocketException {
        await wait(() => _server!.start());
      }
    }
    _localCount = _server!.localMedia.length;
    if (_server!.scanError != null) _error = describeError(_server!.scanError!);
    if (!_shouldShare) {
      await _stopNetwork();
      return;
    }
    _discovery ??= _bridge.discoveryEvents.listen(
      _onDiscovery,
      onError: (Object e) {
        _error = '设备发现暂不可用，可手动输入 IP 连接。${describeError(e)}';
        _notify();
      },
    );
    await wait(
      () => _bridge.startDiscovery(id: _id, name: _deviceName, port: port),
    );
    if (!_shouldShare) await _stopNetwork();
    _notify();
  }

  void _onDiscovery(Map<String, dynamic> event) {
    if (_disposed || !_shouldShare) return;
    final id = event['id'] as String?;
    switch (event['type']) {
      case 'found':
        if (id == _id) return;
        final host = event['host'] as String?;
        final remotePort = event['port'] as int?;
        if (host == null || remotePort == null) return;
        try {
          LanEndpoint.parse('$host:$remotePort');
          _presenceChecks.remove(id);
          unawaited(
            _syncPeer(
              Peer(
                id: id ?? '',
                name: event['name'] as String? ?? '局域网设备',
                host: host,
                port: remotePort,
              ),
            ),
          );
        } on FormatException {
          /* Ignore non-LAN/unsupported addresses. */
        }
      case 'lost':
        if (id != null) unawaited(_checkPeerPresence(id));
      case 'error':
        _error = '自动发现暂不可用，可在「设备」中手动连接。';
        _notify();
    }
  }

  void _invalidatePresenceChecks() {
    ++_presenceGeneration;
    _presenceChecks.clear();
    _connecting.clear();
    _activePeers.clear();
    _pendingPeers.clear();
    _syncProgress.clear();
    _syncProgressOwners.clear();
    _syncCandidates.clear();
    _syncRefreshTimer?.cancel();
    _syncRefreshTimer = null;
    _syncRefreshPending = false;
    // Stop traffic as well as discarding its results. Otherwise a catalog and
    // its thumbnails could continue transferring after sharing was suspended.
    for (final client in _rpcClients.toList()) {
      unawaited(_closeRpcClient(client));
    }
  }

  Future<void> _closeRpcClient(MediaRpcClient client) async {
    if (!_rpcClients.remove(client)) return;
    try {
      await client.close();
    } catch (_) {}
  }

  Future<void> _checkPeerPresence(String id) async {
    final peer = _peers[id];
    if (_disposed ||
        !_shouldShare ||
        peer == null ||
        _presenceChecks.containsKey(id)) {
      return;
    }
    final generation = _presenceGeneration;
    final check = Object();
    _presenceChecks[id] = check;
    bool isCurrent() =>
        !_disposed &&
        _shouldShare &&
        generation == _presenceGeneration &&
        identical(_presenceChecks[id], check);
    MediaRpcClient? client;
    try {
      client = _clientFactory(peer);
      _rpcClients.add(client);
      final identity = await client.identity().timeout(
        const Duration(seconds: 8),
      );
      if (!isCurrent()) return;
      // mDNS disappearance is only a hint. The remembered endpoint must still
      // answer as this device; another phone may now own its previous address.
      if (identity.id == id) {
        _online.add(id);
      } else {
        _online.remove(id);
      }
      _notify();
    } catch (_) {
      if (isCurrent()) {
        _online.remove(id);
        _notify();
      }
    } finally {
      if (identical(_presenceChecks[id], check)) _presenceChecks.remove(id);
      if (client != null) await _closeRpcClient(client);
    }
  }

  // Coalesce thumbnail arrivals so a large catalog does not queue one database
  // read and a widget rebuild for every photo. A slow read never piles up work.
  void _scheduleSyncRefresh() {
    _syncRefreshPending = true;
    if (_syncRefreshTimer != null ||
        _syncRefreshRunning ||
        _loadingMore ||
        _disposed) {
      return;
    }
    _syncRefreshTimer = Timer(const Duration(milliseconds: 250), () async {
      _syncRefreshTimer = null;
      if (_disposed || !_syncRefreshPending) return;
      _syncRefreshPending = false;
      _syncRefreshRunning = true;
      _notify();
      try {
        await _loadCachedMedia(preserveWindow: true);
      } catch (error) {
        if (!_disposed) _error = describeError(error);
      } finally {
        _syncRefreshRunning = false;
        if (!_disposed) {
          _notify();
          if (_syncRefreshPending) _scheduleSyncRefresh();
        }
      }
    });
  }

  Future<void> _loadCachedMedia({bool preserveWindow = false}) {
    final next = _reloadTail.then(
      (_) => _readCachedMedia(preserveWindow: preserveWindow),
    );
    _reloadTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _readCachedMedia({required bool preserveWindow}) async {
    if (_disposed) return;
    // A progress refresh must not invalidate a page the user is still loading.
    // Defer it until that page finishes; explicit filter changes still proceed
    // immediately and invalidate the old page via _pageGeneration.
    if (preserveWindow && _loadingMore) {
      _syncRefreshPending = true;
      return;
    }
    final generation = ++_pageGeneration;
    _hasMore = false;
    final collections = await _repository!.mediaCollections(
      deviceId: _selectedDeviceId,
    );
    if (generation != _pageGeneration || _disposed) return;
    _collections = collections;
    if (_selectedCollection == null && _selectedCollectionKey != null) {
      _selectedCollectionKey = null;
      _loadedMediaLimit = 60;
    }
    final collection = _selectedCollection;
    final limit = preserveWindow ? _loadedMediaLimit : 60;
    final items = <MediaItem>[];
    MediaCursor? cursor;
    late MediaPage page;
    do {
      page = await _repository!.listMediaPage(
        deviceId: collection?.deviceId ?? _selectedDeviceId,
        sharedFolderId: collection?.sharedFolderId,
        after: cursor,
        limit: (limit - items.length).clamp(1, 200),
      );
      if (generation != _pageGeneration || _disposed) return;
      items.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null && items.length < limit);
    await _appendMedia(
      items,
      generation,
      reset: true,
      reuseDownloads: preserveWindow,
    );
    if (generation != _pageGeneration || _disposed) return;
    _cursor = page.nextCursor;
    _hasMore = _cursor != null;
    _totalMediaCount = page.totalCount;
    _notify();
  }

  Future<void> _appendMedia(
    List<MediaItem> items,
    int generation, {
    bool reset = false,
    bool reuseDownloads = false,
  }) async {
    final savedViews = <String, TransferView>{};
    for (final item in items) {
      if (!_transfers.containsKey(item.key) &&
          !(reuseDownloads && _items.containsKey(item.key))) {
        final saved = await _repository!.getDownload(item.deviceId, item.id);
        if (saved != null) {
          savedViews[item.key] = TransferView(
            progress: 1,
            savedUri: saved.uri,
            status: TransferStatus.completed,
            item: _view(item),
            receivedBytes: item.size,
            totalBytes: item.size,
          );
        }
      }
    }
    if (generation != _pageGeneration || _disposed) return;
    if (reset) _items.clear();
    for (final item in items) {
      _items[item.key] = item;
    }
    for (final entry in savedViews.entries) {
      _transfers.putIfAbsent(entry.key, () => entry.value);
    }
    _notify();
  }

  @override
  Future<void> loadMoreMedia() async {
    if (!_hasMore || _loadingMore || _repository == null) return;
    final generation = _pageGeneration;
    _loadingMore = true;
    _notify();
    try {
      final page = await _repository!.listMediaPage(
        deviceId: _selectedCollection?.deviceId ?? _selectedDeviceId,
        sharedFolderId: _selectedCollection?.sharedFolderId,
        after: _cursor,
      );
      if (generation != _pageGeneration || _disposed) return;
      _cursor = page.nextCursor;
      _hasMore = _cursor != null;
      await _appendMedia(page.items, generation);
      if (generation == _pageGeneration && !_disposed) {
        _loadedMediaLimit = _items.length < 60 ? 60 : _items.length;
      }
    } catch (e) {
      _error = describeError(e);
    } finally {
      _loadingMore = false;
      _notify();
      if (_syncRefreshPending) _scheduleSyncRefresh();
    }
  }

  Future<void> _syncPeer(Peer candidate, {bool reportError = false}) async {
    if (_disposed || !_shouldShare) return;
    var key = candidate.id.isEmpty
        ? '${candidate.host}:${candidate.port}'
        : candidate.id;
    if (!_connecting.add(key)) {
      final active = _activePeers[key];
      if (active?.host != candidate.host || active?.port != candidate.port) {
        _pendingPeers[key] = candidate;
      }
      return;
    }
    _activePeers[key] = candidate;
    final generation = _presenceGeneration;
    final progressOwner = Object();
    var progressKey = key;
    _syncProgressOwners[progressKey] = progressOwner;
    _syncCandidates[progressKey] = candidate;
    bool ownsProgress() =>
        !_disposed &&
        _shouldShare &&
        generation == _presenceGeneration &&
        identical(_syncProgressOwners[progressKey], progressOwner);
    void progressChanged(SyncProgress progress) {
      if (!ownsProgress()) return;
      final previous = _syncProgress[progressKey];
      // Reconnecting must not erase the durable counts before the remote
      // revision has been checked. Receiving reports the validated checkpoint.
      if (progress.phase == SyncPhase.connecting && previous != null) {
        progress = SyncProgress(
          peerId: progress.peerId,
          peerName: progress.peerName,
          phase: progress.phase,
          totalCount: previous.totalCount,
          receivedCount: previous.receivedCount,
          readyCount: previous.readyCount,
          attempt: progress.attempt,
        );
      }
      _syncProgress[progressKey] = progress;
      if (previous?.phase != progress.phase ||
          previous?.attempt != progress.attempt) {
        _notify();
      }
      _scheduleSyncRefresh();
    }

    progressChanged(
      SyncProgress(
        peerId: progressKey,
        peerName: candidate.name.isEmpty ? candidate.host : candidate.name,
        phase: SyncPhase.connecting,
      ),
    );
    final remembered = _peers[candidate.id];
    var resolvedId = candidate.id;
    var identified = false;
    MediaRpcClient? client;
    try {
      client = _clientFactory(candidate);
      _rpcClients.add(client);
      var peer = await client.identity();
      if (_disposed || !_shouldShare || generation != _presenceGeneration) {
        return;
      }
      if (candidate.id.isNotEmpty && peer.id != candidate.id) {
        throw const FormatException('此 IP 地址已由另一台设备使用，请重新发现设备');
      }
      if (peer.id == _id) {
        if (ownsProgress()) {
          _syncProgress.remove(progressKey);
          _syncProgressOwners.remove(progressKey);
          _syncCandidates.remove(progressKey);
        }
        if (reportError) _error = '这是本机地址，请输入另一台设备的地址';
        return;
      }
      // Manual addresses and mDNS announcements may resolve to the same peer.
      // Only one of them may write that peer's persistent sync checkpoint.
      if (key != peer.id) {
        if (!_connecting.add(peer.id)) {
          final active = _activePeers[peer.id];
          if (active?.host != peer.host || active?.port != peer.port) {
            _pendingPeers[peer.id] = peer;
          }
          if (ownsProgress()) {
            _syncProgress.remove(progressKey);
            _syncProgressOwners.remove(progressKey);
            _syncCandidates.remove(progressKey);
          }
          return;
        }
        _connecting.remove(key);
        _activePeers.remove(key);
        _pendingPeers.remove(key);
        key = peer.id;
        _activePeers[key] = candidate;
      }
      if (progressKey != peer.id) {
        if (ownsProgress()) {
          _syncProgress.remove(progressKey);
          _syncProgressOwners.remove(progressKey);
          _syncCandidates.remove(progressKey);
        }
        progressKey = peer.id;
        _syncProgressOwners[progressKey] = progressOwner;
      }
      _syncCandidates[progressKey] = peer;
      progressChanged(
        SyncProgress(
          peerId: peer.id,
          peerName: peer.name,
          phase: SyncPhase.connecting,
        ),
      );
      resolvedId = peer.id;
      identified = true;
      _presenceChecks.remove(peer.id);
      final previous = _peers[peer.id];
      peer = peer.copyWith(
        lastSeen: DateTime.now(),
        lastSync: previous?.lastSync,
      );
      await _repository!.upsertPeer(peer);
      if (_disposed || !_shouldShare || generation != _presenceGeneration) {
        return;
      }
      _peers[peer.id] = peer;
      _presenceChecks.remove(peer.id);
      _online.add(peer.id);
      _notify();
      final result = await client.synchronize(
        _repository!,
        onProgress: progressChanged,
      );
      if (_disposed || !_shouldShare || generation != _presenceGeneration) {
        return;
      }
      if (identical(_peers[peer.id], peer)) {
        _peers[peer.id] = result.peer;
        _presenceChecks.remove(peer.id);
        _online.add(peer.id);
      }
      progressChanged(
        SyncProgress(
          peerId: result.peer.id,
          peerName: result.peer.name,
          phase: SyncPhase.completed,
          totalCount: result.totalCount,
          receivedCount: result.totalCount,
          readyCount: result.totalCount,
          attempt: _syncProgress[progressKey]?.attempt ?? 0,
        ),
      );
      await _loadCachedMedia(preserveWindow: true);
    } catch (e) {
      if (!_disposed && _shouldShare && generation == _presenceGeneration) {
        final previous = _syncProgress[progressKey];
        progressChanged(
          SyncProgress(
            peerId: progressKey,
            peerName: previous?.peerName ?? candidate.name,
            phase: SyncPhase.failed,
            totalCount: previous?.totalCount,
            receivedCount: previous?.receivedCount ?? 0,
            readyCount: previous?.readyCount ?? 0,
            attempt: previous?.attempt ?? 0,
            error: describeError(e),
          ),
        );
        // Include every thumbnail committed before interruption, even if the
        // throttled preview refresh has not run yet.
        try {
          await _loadCachedMedia(preserveWindow: true);
        } catch (reloadError) {
          if (!_disposed) _error = describeError(reloadError);
        }
        if (identified) {
          // A catalog/permission error is not evidence that the phone went
          // offline. Recheck reachability independently of media synchronization.
          // Reachability is independent of retrying the catalog. A slow probe
          // must not leave the visible retry button blocked by this attempt.
          unawaited(_checkPeerPresence(resolvedId));
        } else if (identical(_peers[resolvedId], remembered)) {
          _online.remove(resolvedId);
        }
        if (reportError &&
            !_disposed &&
            _shouldShare &&
            generation == _presenceGeneration) {
          _error = describeError(e);
        }
      }
    } finally {
      if (client != null) await _closeRpcClient(client);
      if (!_disposed && generation != _presenceGeneration) {
        // A stopped sync may finish saving after a new foreground operation
        // has begun. Read the current view without reviving old progress.
        try {
          await _loadCachedMedia(preserveWindow: true);
        } catch (_) {}
      }
      if (identical(_syncProgressOwners[progressKey], progressOwner)) {
        _syncProgressOwners.remove(progressKey);
      }
      if (generation == _presenceGeneration &&
          identical(_activePeers[key], candidate)) {
        _connecting.remove(key);
        _activePeers.remove(key);
        _notify();
        final next = _pendingPeers.remove(key);
        if (next != null && !_disposed && _shouldShare) {
          await _syncPeer(next, reportError: reportError);
        }
      }
    }
  }

  Future<void> _syncRemembered() async {
    final peers = _peers.values.toList();
    // Bound concurrent peers; each catalog uses metadata pages and incremental thumbnails.
    for (var offset = 0; offset < peers.length; offset += 3) {
      await Future.wait(
        peers.skip(offset).take(3).map((peer) => _syncPeer(peer)),
      );
    }
  }

  @override
  Future<void> retrySync(String peerId) async {
    final peer = _syncCandidates[peerId] ?? _peers[peerId];
    if (peer == null) return;
    _error = null;
    await _syncPeer(peer, reportError: true);
  }

  @override
  Future<void> refresh() => _refresh(rescan: true);

  /// Activation (unlocking, returning from a share sheet, focusing a desktop
  /// window) refreshes peers but rescans local folders at most once per
  /// interval while sharing is healthy. Failed scans retry on activation;
  /// manual refresh and folder changes always rescan.
  Future<void> refreshAfterResume() async {
    if (_loading || _busy || _disposed) return;
    final scanned = _source?.scannedAt;
    await _refresh(
      rescan:
          _server?.scanError != null ||
          scanned == null ||
          _clock().difference(scanned) >= _resumeRescanInterval,
    );
  }

  Future<void> _refresh({required bool rescan}) async {
    if (!_initialized) {
      await initialize();
      return;
    }
    await _guard(() async {
      await _readSharingStatus();
      await _networkOperation(() async {
        if (!_shouldShare) {
          await _stopNetwork();
          return;
        }
        Object? scanError;
        try {
          if (rescan && (_server?.port ?? 0) != 0) await _server!.refresh();
          await _startNetwork();
        } catch (e) {
          scanError = e;
        }
        _localCount = _server?.localMedia.length ?? 0;
        if (scanError != null) throw scanError;
      });
    });
    if (_foreground && !_disposed) await _syncRemembered();
  }

  @override
  Future<void> chooseSharedFolder() => _guard(() async {
    final directory = await _bridge.pickDirectory();
    if (directory == null) return;
    final uri = directory['uri'] as String;
    if (_sharedFolders.any((folder) => folder.uri == uri)) {
      throw const FormatException('这个目录已在共享列表中，无需重复添加');
    }
    await _bridge.validateSharedDirectory(
      uri,
      _sharedFolders.map((folder) => folder.uri).toList(),
    );
    await _saveSharedFolders([
      ..._sharedFolders,
      SharedFolder(
        id: const Uuid().v4(),
        uri: uri,
        name: directory['name'] as String,
      ),
    ]);
  });

  @override
  Future<void> removeSharedFolder(String id) => _guard(() async {
    if (!_sharedFolders.any((folder) => folder.id == id)) return;
    await _saveSharedFolders(
      _sharedFolders.where((folder) => folder.id != id).toList(),
    );
  });

  Future<void> _saveSharedFolders(List<SharedFolder> folders) async {
    await _repository!.setSetting(
      'sharedFolders',
      jsonEncode(folders.map((folder) => folder.toJson()).toList()),
    );
    _sharedFolders = folders;
    try {
      await _networkOperation(() async {
        if (!_shouldShare) return;
        if ((_server?.port ?? 0) == 0) {
          await _startNetwork();
        } else {
          await _server!.refresh();
        }
      });
    } finally {
      _localCount = _server?.localMedia.length ?? 0;
    }
  }

  @override
  Future<void> chooseDownloadFolder() => _guard(() async {
    final directory = await _bridge.pickDirectory();
    if (directory == null) return;
    _downloadUri = directory['uri'] as String;
    _downloadFolder = directory['name'] as String;
    await _repository!.setSetting('downloadUri', _downloadUri!);
    await _repository!.setSetting('downloadFolder', _downloadFolder!);
  });

  @override
  Future<void> connect(String address) async {
    LanEndpoint? endpoint;
    await _guard(() async {
      endpoint = LanEndpoint.parse(address);
    });
    final target = endpoint;
    if (target == null) return;
    // Network synchronization has its own per-device state. Keep local actions
    // such as choosing a download folder available while previews arrive.
    await _syncPeer(
      Peer(id: '', name: '局域网设备', host: target.host, port: target.port),
      reportError: true,
    );
  }

  @override
  Future<void> selectDevice(String? id) async {
    _selectedDeviceId = id;
    _selectedCollectionKey = null;
    _loadedMediaLimit = 60;
    ++_pageGeneration;
    await _loadCachedMedia();
  }

  @override
  Future<void> selectCollection(String? key) async {
    if (key != null &&
        !_collections.any((collection) => collection.key == key)) {
      return;
    }
    _selectedCollectionKey = key;
    _loadedMediaLimit = 60;
    ++_pageGeneration;
    await _loadCachedMedia();
  }

  @override
  Future<void> download(MediaView view) async {
    if (_disposed ||
        _taskStore == null ||
        _transfers[view.key]?.running == true ||
        !_scheduling.add(view.key)) {
      return;
    }
    try {
      if (_downloadUri == null) {
        await chooseDownloadFolder();
        if (_downloadUri == null) return;
      }
      final item =
          _items[view.key] ??
          await _repository!.getMedia(view.deviceId, view.id) ??
          (await _taskStore!.forMedia(view.deviceId, view.id))?.item;
      final peer = _peers[view.deviceId];
      if (item == null ||
          peer == null ||
          _transfers[view.key]?.complete == true) {
        return;
      }
      final task = await _taskStore!.enqueue(peer, item, _downloadUri!);
      await _refreshTransfers();
      try {
        await _transferScheduler!.scheduleTransfer(task.id);
      } catch (e) {
        await _taskStore!.update(task.id, {
          'state': 'failed',
          'run_token': null,
          'error': describeError(e),
        });
        rethrow;
      }
    } catch (e) {
      _error = describeError(e);
    } finally {
      _scheduling.remove(view.key);
      await _refreshTransfers();
      _notify();
    }
  }

  @override
  Future<void> cancelDownload(String key) async {
    if (!_scheduling.add(key)) return;
    try {
      final task = (await _taskStore?.recent())
          ?.where((task) => task.item.key == key)
          .firstOrNull;
      if (task == null || !task.active) return;
      try {
        await _taskStore!.cancel(task.id);
        await _transferScheduler!.cancelTransfer(task.id);
      } catch (e) {
        _error = describeError(e);
      }
      await _refreshTransfers();
    } finally {
      _scheduling.remove(key);
    }
  }

  @override
  Future<void> discardDownload(String key) async {
    if (_disposed || _taskStore == null || !_scheduling.add(key)) return;
    try {
      final task = (await _taskStore!.recent())
          .where((task) => task.item.key == key)
          .firstOrNull;
      if (task == null || !await _taskStore!.requestDiscard(task.id)) return;
      await _refreshTransfers();
      await _transferScheduler!.cancelTransfer(task.id);
      final directory = Directory(await _bridge.transferDirectory());
      await _taskStore!.finishDiscard(task.id, directory);
      // Refresh removes the task and restores any save committed just before stop.
    } catch (error) {
      _error = describeError(error);
    } finally {
      _scheduling.remove(key);
      await _refreshTransfers();
      _notify();
    }
  }

  @override
  Future<Uint8List?> loadPreview(MediaView item) async {
    final uri = _transfers[item.key]?.savedUri;
    if (uri == null || item.isVideo) return null;
    try {
      return await _bridge.readPreview(uri, maxDimension: 2560);
    } catch (e) {
      _error = describeError(e);
      _notify();
      return null;
    }
  }

  @override
  Future<void> share(MediaView item) => _openSaved(item, share: true);
  @override
  Future<void> open(MediaView item) => _openSaved(item, share: false);
  Future<void> _openSaved(MediaView item, {required bool share}) async {
    final uri = _transfers[item.key]?.savedUri;
    if (uri == null) return;
    try {
      if (share) {
        await _bridge.share(uri, item.mimeType);
      } else {
        await _bridge.open(uri, item.mimeType);
      }
    } catch (e) {
      // Only missing/revoked documents invalidate history; no viewer installed
      // does not mean the downloaded file has disappeared.
      if (e is PlatformException &&
          [
            'MISSING',
            'FILE_NOT_FOUND',
            'PERMISSION',
            'PERMISSION_LOST',
            'SECURITY',
          ].contains(e.code)) {
        await _repository?.removeDownload(item.deviceId, item.id);
        await _taskStore?.invalidate(item.deviceId, item.id);
        _transfers.remove(item.key);
        await _refreshTransfers();
      }
      _error = describeError(e);
      _notify();
    }
  }

  Future<void> shutdown() async {
    _disposed = true;
    _initializationStartup?.cancel();
    _networkStartup?.cancel();
    _invalidatePresenceChecks();
    _transferPoll?.cancel();
    await _sharingSubscription?.cancel();
    try {
      await _networkOperation(_stopNetwork);
    } catch (_) {}
    try {
      await _transferScheduler?.shutdown();
      await _reloadTail;
      await _repository?.close();
      await _taskStore?.close();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}

class _SharingStartupCancelled implements Exception {}

/// Stop awaiting a failed native session while leaving shared resources owned
/// by the controller. Each caller commits state only after this wait succeeds.
class _SharingStartup {
  _SharingStartup(this.sessionId);
  String? sessionId;
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  Future<T> wait<T>(Future<T> Function() action) async {
    if (cancelled) throw _SharingStartupCancelled();
    final value = await Future.any([
      action(),
      _cancelled.future.then<T>((_) => throw _SharingStartupCancelled()),
    ]);
    if (cancelled) throw _SharingStartupCancelled();
    return value;
  }
}

class _PlatformMediaSource implements LocalMediaSource {
  _PlatformMediaSource(
    this.bridge,
    this.deviceId,
    this.sharedFolders,
    this.clock,
  );
  final PlatformBridge bridge;
  final String deviceId;
  final List<SharedFolder> Function() sharedFolders;
  final DateTime Function() clock;

  /// When the last successful scan started; failed scans retry on activation.
  DateTime? scannedAt;

  @override
  Future<List<MediaMetadata>> scan() async {
    final started = clock();
    final folders = sharedFolders();
    if (folders.isEmpty) {
      await bridge.clearSharedDirectory();
      scannedAt = started;
      return [];
    }
    final entries = await bridge.scanDirectoriesMetadata(folders);
    scannedAt = started;
    return entries
        .map(
          (entry) => MediaMetadata(
            id: entry['id'] as String,
            deviceId: deviceId,
            name: entry['name'] as String,
            sharedFolderId: entry['sharedFolderId'] as String,
            sharedFolderName: entry['sharedFolderName'] as String,
            relativePath: entry['relativePath'] as String,
            mimeType: entry['mimeType'] as String,
            size: entry['size'] as int,
            modifiedMs: entry['modifiedMs'] as int,
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> readThumbnail(String id) => bridge.thumbnail(id);

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    try {
      return await bridge.readRange(id, offset, length);
    } on PlatformException catch (error) {
      // Native catalogs report a replaced or revoked snapshot this way.
      if (error.code == 'SCAN_CANCELLED') throw const MediaSourceInterrupted();
      rethrow;
    }
  }
}
