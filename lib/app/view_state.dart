import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../core/models.dart';
export '../core/models.dart'
    show
        SharedFolder,
        MediaCollection,
        MediaSortOrder,
        MediaScrollEntry,
        PeerSyncApproval,
        SyncPhase,
        SyncProgress;

class DeviceView {
  const DeviceView({
    required this.id,
    required this.name,
    required this.address,
    required this.online,
    this.lastSync,
    this.lastSuccessfulSync,
    this.syncApproval = PeerSyncApproval.approved,
  });
  final String id, name, address;
  final bool online;
  final DateTime? lastSync;
  final DateTime? lastSuccessfulSync;

  /// Discovered devices synchronize only after the user approves them.
  final PeerSyncApproval syncApproval;
  bool get syncEnabled => syncApproval == PeerSyncApproval.approved;
}

class MediaView {
  const MediaView({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.modified,
    required this.thumbnail,
    this.sharedFolderId = '',
    this.sharedFolderName = '',
    this.relativePath = '',
  });
  final String id, deviceId, name, mimeType;
  final String sharedFolderId, sharedFolderName, relativePath;
  final int size;
  final DateTime modified;
  final Uint8List thumbnail;
  String get key => '$deviceId/$id';
  bool get isVideo => mimeType.startsWith('video/');
}

enum TransferStatus {
  queued,
  downloading,
  saving,
  completed,
  failed,
  cancelled,
  discarded,
}

class TransferView {
  const TransferView({
    required this.progress,
    this.savedUri,
    this.error,
    this.item,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.attempt = 1,
    TransferStatus? status,
  }) : _status = status;
  final double progress;
  final String? savedUri, error;
  final MediaView? item;
  final int receivedBytes, totalBytes, attempt;
  final TransferStatus? _status;
  TransferStatus get status =>
      _status ??
      (complete
          ? TransferStatus.completed
          : error != null
          ? TransferStatus.failed
          : TransferStatus.downloading);
  bool get complete => savedUri != null;
  bool get running =>
      status == TransferStatus.queued ||
      status == TransferStatus.downloading ||
      status == TransferStatus.saving;
}

abstract class TamayuraModel extends ChangeNotifier {
  ThemeMode get themeMode => ThemeMode.system;
  bool get themeModeSaving => false;
  bool get albumDetailedMode => false;
  bool get albumDetailedModeSaving => false;
  int get autoSyncIntervalHours => 12;
  bool get autoSyncIntervalSaving => false;
  bool get backgroundSharingEnabled => false;
  bool get backgroundSharingRunning => false;
  bool get backgroundSharingStarting => false;
  String? get backgroundSharingError => null;
  bool get backgroundSharingSaving => false;
  bool get batteryOptimizationExempt => true;
  bool get loading;
  bool get busy;
  String? get error;
  String get deviceName;
  List<String> get addresses;
  int get port;
  List<SharedFolder> get sharedFolders;
  String? get downloadFolder;
  int get localMediaCount;
  List<DeviceView> get devices;
  bool get deviceOrderSaving => false;
  List<SyncProgress> get syncProgress => const [];
  String? get selectedDeviceId;
  List<MediaCollection> get collections;
  String? get selectedCollectionKey;
  List<MediaView> get media;
  List<MediaScrollEntry> get mediaScrollEntries => const [];
  MediaView? mediaAtScrollIndex(int index) => null;

  /// Load an inclusive visible range in the album index, without loading the
  /// intervening pages. A newer range supersedes pending obsolete ranges.
  Future<void> ensureMediaScrollRange(int first, int last) async {}
  MediaSortOrder get mediaSortOrder => MediaSortOrder.dateDescending;
  bool get mediaSortOrderChanging => false;
  int get totalMediaCount => media.length;
  Map<String, TransferView> get transfers;
  bool get hasMoreMedia => false;
  bool get loadingMoreMedia => false;
  Future<void> initialize();
  Future<void> setThemeMode(ThemeMode mode);
  Future<void> setAlbumDetailedMode(bool enabled) async {}
  Future<void> setAutoSyncIntervalHours(int hours) async {}
  Future<void> setBackgroundSharing(bool enabled) async {}
  Future<void> openBatteryOptimizationSettings() async {}
  Future<void> refresh();
  Future<void> retrySync(String peerId) => refresh();
  Future<void> chooseSharedFolder();
  Future<void> removeSharedFolder(String id);
  Future<void> chooseDownloadFolder();
  Future<void> connect(String address);
  Future<void> selectDevice(String? id);

  /// Save the order shared by the device list and album device filters.
  Future<bool> reorderDevices(List<String> deviceIds) async => false;

  /// Newly discovered devices awaiting the one-time "start syncing?" prompt,
  /// oldest first. Each device is offered at most once per application run.
  List<DeviceView> get syncApprovalRequests => const [];

  /// Approve (and start) or decline album synchronization for a device. A
  /// declined device stays remembered and can be enabled later.
  Future<void> setDeviceSyncEnabled(String id, bool enabled) async {}

  /// Close the prompt without deciding; the device remains pending.
  void dismissSyncApproval(String id) {}

  /// Devices whose forget operation is still running.
  Set<String> get forgettingDeviceIds => const {};

  /// Remove a remembered device with its offline album, unfinished sync
  /// stages and unused thumbnails. Saved local files and downloads remain.
  Future<bool> forgetDevice(String id) async => false;
  Future<void> selectCollection(String? key);
  Future<void> setMediaSortOrder(MediaSortOrder order) async {}
  Future<void> download(MediaView item);

  /// Delete only the saved local copy, retaining its offline media metadata.
  Future<bool> deleteLocalFile(MediaView item) async => false;
  Future<void> share(MediaView item);
  Future<void> loadMoreMedia() async {}

  /// Return bounded image bytes from the saved local file, or null when it
  /// cannot be read or safely previewed. Gallery cards request a smaller bound
  /// than the full-screen preview to limit native decoding and channel memory.
  /// [isCurrent] lets disposed or superseded consumers skip queued decoding.
  Future<Uint8List?> loadPreview(
    MediaView item, {
    int maxDimension = 2560,
    bool Function()? isCurrent,
  }) async => null;
  Future<void> open(MediaView item) => share(item);
  Future<void> cancelDownload(String key) async {}
  Future<void> discardDownload(String key) async {}
  void clearError();
}
