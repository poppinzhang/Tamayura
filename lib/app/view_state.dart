import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../core/models.dart';
export '../core/models.dart'
    show SharedFolder, MediaCollection, SyncPhase, SyncProgress;

class DeviceView {
  const DeviceView({
    required this.id,
    required this.name,
    required this.address,
    required this.online,
    this.lastSync,
  });
  final String id, name, address;
  final bool online;
  final DateTime? lastSync;
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
  bool get backgroundSharingEnabled => false;
  bool get backgroundSharingRunning => false;
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
  List<SyncProgress> get syncProgress => const [];
  String? get selectedDeviceId;
  List<MediaCollection> get collections;
  String? get selectedCollectionKey;
  List<MediaView> get media;
  int get totalMediaCount => media.length;
  Map<String, TransferView> get transfers;
  bool get hasMoreMedia => false;
  bool get loadingMoreMedia => false;
  Future<void> initialize();
  Future<void> setThemeMode(ThemeMode mode);
  Future<void> setBackgroundSharing(bool enabled) async {}
  Future<void> openBatteryOptimizationSettings() async {}
  Future<void> refresh();
  Future<void> retrySync(String peerId) => refresh();
  Future<void> chooseSharedFolder();
  Future<void> removeSharedFolder(String id);
  Future<void> chooseDownloadFolder();
  Future<void> connect(String address);
  Future<void> selectDevice(String? id);
  Future<void> selectCollection(String? key);
  Future<void> download(MediaView item);
  Future<void> share(MediaView item);
  Future<void> loadMoreMedia() async {}

  /// Return bounded image bytes from the saved local file, or null when it
  /// cannot safely be previewed in the app (for example a very large image).
  Future<Uint8List?> loadPreview(MediaView item) async => null;
  Future<void> open(MediaView item) => share(item);
  Future<void> cancelDownload(String key) async {}
  void clearError();
}
