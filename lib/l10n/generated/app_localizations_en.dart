// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Tamayura';

  @override
  String get appLocalName => '';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonSaving => 'Saving…';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonDone => 'Done';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonConnect => 'Connect';

  @override
  String get commonShare => 'Share';

  @override
  String get commonOnline => 'Online';

  @override
  String get commonOffline => 'Offline';

  @override
  String get commonVideo => 'Video';

  @override
  String get commonImage => 'Image';

  @override
  String get navAlbum => 'Album';

  @override
  String get navDevices => 'Devices';

  @override
  String get navSettings => 'Settings';

  @override
  String get homeDownloadsTooltip => 'Downloads';

  @override
  String get homeRefreshTooltip => 'Refresh devices and albums';

  @override
  String get homeOpening => 'Opening your pocket album…';

  @override
  String get homeActionFailed =>
      'Couldn\'t finish. Check the network and folder permissions, then try again.';

  @override
  String get homeErrorRetry => 'Reconnect and refresh';

  @override
  String get homeErrorDismiss => 'Dismiss';

  @override
  String get albumHeadline => 'Every moment, close at hand.';

  @override
  String get albumSubtitle =>
      'Browse collections by shared folder. Tap a photo to save it here.';

  @override
  String get albumAllDevices => 'All devices';

  @override
  String get albumAllCollections => 'All collections';

  @override
  String get albumSharedCollectionFallback => 'Shared collection';

  @override
  String get albumDeleteLocalFiles => 'Delete local files';

  @override
  String albumCollectionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count collections',
      one: '1 collection',
    );
    return '$_temp0';
  }

  @override
  String albumMomentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count moments',
      one: '1 moment',
    );
    return '$_temp0';
  }

  @override
  String get albumSelectSavedHint => 'Select saved photos or videos';

  @override
  String get albumTapToDownloadHint => 'Tap to download the original';

  @override
  String get albumReceivingTitle => 'Receiving the album';

  @override
  String get albumReceivingDescription =>
      'Thumbnails appear as they arrive. You can browse while syncing.';

  @override
  String get albumSyncIncompleteTitle => 'Sync not finished';

  @override
  String get albumSyncIncompleteDescription =>
      'Check the connection between both devices, then sync again.';

  @override
  String get albumNoDevicesTitle => 'Let your photos meet';

  @override
  String get albumNoDevicesDescription =>
      'Open Tamayura on another device on the same local network.\nOnce it\'s found, its shared folders appear here as collections.';

  @override
  String get albumEmptyCollectionTitle => 'No photos in this collection yet';

  @override
  String get albumNoCollectionsTitle => 'No collections yet';

  @override
  String get albumNoMediaDesktopDescription =>
      'The other device needs to choose a shared folder and keep Tamayura running.\nClick refresh at the top right to update connected devices\' albums.';

  @override
  String get albumNoMediaMobileDescription =>
      'The other device needs to choose a shared folder; with background sharing on, it works even when locked.\nTap refresh at the top right to update connected devices\' albums.';

  @override
  String get albumConnectDevice => 'Connect a device';

  @override
  String get albumLoadMoreFailed =>
      'Couldn\'t load more photos. Please try again.';

  @override
  String get albumLoadingMore => 'Loading more photos…';

  @override
  String get albumLoadMore => 'Load more photos';

  @override
  String get albumRetryLoad => 'Try again';

  @override
  String get albumLoadingThumbnail => 'Loading thumbnail';

  @override
  String get albumRetryThumbnail => 'Reload thumbnail';

  @override
  String get albumSortTooltip => 'Sort by name or modified date';

  @override
  String get albumSorting => 'Sorting…';

  @override
  String albumSortLabel(String order) {
    return 'Sort: $order';
  }

  @override
  String get albumSortNameAscending => 'Name (A–Z)';

  @override
  String get albumSortNameDescending => 'Name (Z–A)';

  @override
  String get albumSortDateAscending => 'Oldest first';

  @override
  String get albumSortDateDescending => 'Newest first';

  @override
  String albumSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get albumDeleting => 'Deleting…';

  @override
  String albumLocalDeleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Deleted $count local files.',
      one: 'Deleted 1 local file.',
    );
    return '$_temp0 Tap a thumbnail to download again.';
  }

  @override
  String albumLocalDeletePartial(int deleted, int failed) {
    return 'Local files deleted: $deleted. Not deleted: $failed. Check folder permissions and try again.';
  }

  @override
  String albumMonthLabel(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMM(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String albumDateLabel(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMMEd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String albumFastScrollLabel(String label) {
    return 'Fast scroll album, $label';
  }

  @override
  String get rememberedDeviceFallback => 'Remembered device';

  @override
  String get setupTitle => 'Set up your album first';

  @override
  String get setupDescription =>
      'Add folders to share, and choose where received photos are saved.';

  @override
  String get setupShareFolder => 'Share a folder';

  @override
  String get setupDownloadFolder => 'Download folder';

  @override
  String collectionSemantics(String folder, String device, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count moments',
      one: '1 moment',
    );
    return '$folder, from $device, $_temp0';
  }

  @override
  String mediaSemantics(String name, String device, String state) {
    return '$name, from $device, $state';
  }

  @override
  String get mediaStateSaved => 'Saved';

  @override
  String get mediaStateDownloading => 'Downloading';

  @override
  String get mediaStateFailed => 'Download failed, tap to retry';

  @override
  String get mediaStateTapToDownload => 'Tap to download the original';

  @override
  String get mediaStateOffline => 'Device offline, tap for details';

  @override
  String get mediaDeviceOffline => 'Device offline';

  @override
  String mediaDownloadingName(String name) {
    return 'Downloading $name';
  }

  @override
  String mediaSelectName(String name) {
    return 'Select $name';
  }

  @override
  String mediaNotSavedName(String name) {
    return '$name is not saved yet';
  }

  @override
  String get mediaDeleteLocalOnly => 'Deletes the local copy only';

  @override
  String get mediaNotSaved => 'Not saved yet';

  @override
  String get mediaDownloadFailedRetry => 'Failed · Retry';

  @override
  String get mediaReceivingOriginal => 'Receiving original…';

  @override
  String mediaCardDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.MMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get devicesTitle => 'Nearby companions';

  @override
  String get devicesSubtitle =>
      'One local network, every device\'s album connected.';

  @override
  String get devicesThisDevice => 'This device';

  @override
  String get devicesNoAddress =>
      'No local network address. Connect to a network, then refresh.';

  @override
  String get devicesShowQr => 'Show connection QR code';

  @override
  String get devicesConnectByIp => 'Connect by IP';

  @override
  String get devicesScan => 'Scan QR code';

  @override
  String get devicesConnecting => 'Connecting to device…';

  @override
  String get devicesRemembered => 'Remembered devices';

  @override
  String devicesOnlineCount(int count) {
    return '$count online';
  }

  @override
  String get devicesReorder => 'Reorder';

  @override
  String get devicesEmptyTitle => 'Waiting for another Tamayura';

  @override
  String get devicesEmptyDescription =>
      'Devices are discovered automatically on the local network.\nIf none shows up, connect by IP or scan a QR code.';

  @override
  String get devicesFooterWindows =>
      'Album thumbnails stay available when a device is offline. Sharing and receiving need Tamayura running, the PC awake, and the source device on the same local network.';

  @override
  String get devicesFooterMac =>
      'Album thumbnails stay available when a device is offline. Sharing and receiving need Tamayura running, the Mac awake, and the source device on the same local network.';

  @override
  String get devicesFooterMobile =>
      'Album thumbnails stay available when a device is offline. With background sharing on, the source device can provide originals while locked; this device keeps receiving if you switch apps.';

  @override
  String deviceLastSuccessfulSync(String time) {
    return 'Last successful sync: $time';
  }

  @override
  String get deviceNeverSynced => 'never';

  @override
  String get devicePendingApproval => 'Newly found · Album sync not turned on';

  @override
  String get deviceSyncDeclined => 'Album sync off';

  @override
  String get deviceOfflineCached => 'Offline · Cached album available';

  @override
  String get deviceActions => 'Device actions';

  @override
  String get deviceEnableAlbumSync => 'Turn on album sync';

  @override
  String get deviceForget => 'Forget device';

  @override
  String get deviceStartSync => 'Turn on sync';

  @override
  String deviceForgotten(String name) {
    return 'Forgot “$name”. If it\'s found again, you\'ll be asked whether to sync it.';
  }

  @override
  String get deviceForgetFailed =>
      'Couldn\'t forget this device. Please try again later.';

  @override
  String deviceForgetTitle(String name) {
    return 'Forget “$name”?';
  }

  @override
  String get deviceForgetMessage =>
      'This removes the device from the list and deletes its offline album data, thumbnails and unfinished sync progress.\n\nFiles already downloaded to this device and download tasks are kept, and nothing is deleted on the other device. If it\'s found on the network again, you\'ll be asked whether to sync it.';

  @override
  String get syncApprovalTitle => 'New device found';

  @override
  String syncApprovalMessage(String name, String address) {
    return '“$name” ($address) is on your local network. Sync the albums it shares?\n\nSyncing only fetches file details and thumbnails; originals download when you open them. If you choose “Not now”, you can turn it on anytime on the Devices page.';
  }

  @override
  String get syncApprovalDecline => 'Not now';

  @override
  String get syncApprovalAccept => 'Start syncing';

  @override
  String get connectDialogTitle => 'Connect another device';

  @override
  String get connectDialogHint =>
      'Find the IP address on the other device\'s Devices page.';

  @override
  String get connectDialogLabel => 'IP address and port';

  @override
  String get connectDialogEmpty => 'Enter the other device\'s IP address';

  @override
  String get qrDialogHint => 'Scan with Tamayura on another device';

  @override
  String qrSemantics(String address, int port) {
    return 'Connection QR code for this device, address $address, port $port';
  }

  @override
  String get scannerTitle => 'Scan device QR code';

  @override
  String get scannerInvalidCode =>
      'This isn\'t a Tamayura device QR code. Scan the code on the other device\'s Devices page.';

  @override
  String get scannerCameraUnavailable =>
      'Can\'t open the camera. Allow camera access in system settings, or go back and connect by IP.';

  @override
  String get scannerBack => 'Back to Devices';

  @override
  String get scannerHint =>
      'Point the camera at the other device\'s QR code\nBoth devices must be on the same local network';

  @override
  String get syncPhaseConnecting => 'Connecting';

  @override
  String get syncPhaseReceiving => 'Syncing album';

  @override
  String get syncPhaseCommitting => 'Finishing sync';

  @override
  String get syncPhaseCompleted => 'Album synced';

  @override
  String get syncPhaseFailed => 'Sync not finished';

  @override
  String syncConnectingResume(int count) {
    return '$count items kept. Connecting to continue syncing.';
  }

  @override
  String get syncConnectingFresh =>
      'Getting album details. Keep the devices connected.';

  @override
  String syncReceivingOpen(int count) {
    return '$count items ready. Getting more photos.';
  }

  @override
  String syncReceivingProgress(int ready, int total) {
    return '$ready of $total items ready. You can browse while syncing.';
  }

  @override
  String get syncCommittingDetail => 'Thumbnails ready. Organizing the album.';

  @override
  String syncCompletedDetail(int count) {
    return '$count items ready.';
  }

  @override
  String syncFailedResume(int count) {
    return '$count items kept. Sync continues once the connection is back.';
  }

  @override
  String get syncFailedFresh =>
      'Album and sync progress are kept. Check the connection and try again.';

  @override
  String get syncDismiss => 'Dismiss sync notice';

  @override
  String syncProgressSemantics(String device, String status, String detail) {
    return '$device, $status, $detail';
  }

  @override
  String get syncContinue => 'Continue sync';

  @override
  String get settingsTitle => 'Your album, your way';

  @override
  String get settingsSubtitle =>
      'Share only the folders you choose. Originals are fetched on demand.';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsThemeMode => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSaving => 'Saving theme…';

  @override
  String get settingsThemeSystemDescription =>
      'Switches between light and dark with your system.';

  @override
  String get settingsThemeLightDescription =>
      'Always uses the light appearance.';

  @override
  String get settingsThemeDarkDescription => 'Always uses the dark appearance.';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'System default';

  @override
  String get settingsLanguageSaving => 'Saving language…';

  @override
  String settingsLanguageSystemDescription(String language) {
    return 'Follows your system language, currently $language. System languages other than Chinese or Japanese use English.';
  }

  @override
  String settingsLanguageFixedDescription(String language) {
    return 'Always uses $language, regardless of the system language.';
  }

  @override
  String get settingsAlbum => 'Album';

  @override
  String get settingsDetailedMode => 'Detailed mode';

  @override
  String get settingsDetailedModeSaving => 'Saving display mode…';

  @override
  String get settingsDetailedModeDescription =>
      'The default mode uses a compact square grid; tap a photo for details.\nDetailed mode shows each photo\'s file name, source device, date and download status.';

  @override
  String get settingsSync => 'Sync';

  @override
  String get settingsAutoSyncInterval => 'Auto sync interval';

  @override
  String get settingsAutoSyncSaving => 'Saving sync interval…';

  @override
  String settingsAutoSyncDescription(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other:
          'Syncs automatically $minutes minutes after the last sync attempt.',
      one: 'Syncs automatically 1 minute after the last sync attempt.',
    );
    return '$_temp0\nManual and failed syncs restart the timer. Refresh at the top right to sync now.';
  }

  @override
  String get settingsFilesStorage => 'Files & storage';

  @override
  String get settingsSharedFolders => 'Shared folders';

  @override
  String get settingsSharedFoldersDescription =>
      'Add as many folders as you like; all subfolders are included. A folder already added, or its parent or subfolder, can\'t be added again.';

  @override
  String get settingsSharedFoldersEmpty =>
      'None yet · Let other devices see photos here';

  @override
  String settingsRemoveSharedFolder(String name) {
    return 'Remove $name';
  }

  @override
  String get settingsAddSharedFolder => 'Add shared folder';

  @override
  String get settingsBackgroundSharing => 'Background sharing';

  @override
  String get settingsBackgroundSharingWindows =>
      'Closing the window keeps Tamayura in the system tray. When on, sharing continues while the window is closed or minimized; when off, sharing stops while the window is hidden. The PC must stay awake.';

  @override
  String get settingsBackgroundSharingMac =>
      'Closing the window keeps Tamayura in the menu bar. When on, sharing continues while the window is closed, hidden or minimized; when off, sharing stops while the window is hidden. The Mac must stay awake.';

  @override
  String get settingsBackgroundSharingMobile =>
      'When on, media stays shared while the screen is locked. When off, sharing only happens while you use the app, which saves battery.';

  @override
  String get backgroundSharingStarting => 'Starting background sharing…';

  @override
  String get backgroundSharingUpdating => 'Updating background sharing…';

  @override
  String get backgroundSharingStartFailed =>
      'Background sharing couldn\'t start. Please try again.';

  @override
  String get backgroundSharingOff => 'Background sharing is off.';

  @override
  String get backgroundSharingRunningWindows =>
      'Background sharing is running. It stops if the PC sleeps or Tamayura exits.';

  @override
  String get backgroundSharingRunningMac =>
      'Background sharing is running. It stops if the Mac sleeps or Tamayura quits.';

  @override
  String get backgroundSharingRunningMobile =>
      'Background sharing is running. Your chosen folders stay available while locked.';

  @override
  String get backgroundSharingNotRunning =>
      'Background sharing isn\'t running yet.';

  @override
  String get backgroundSharingRetry => 'Retry background sharing';

  @override
  String get backgroundSharingBatteryHint =>
      'System battery restrictions may interrupt sharing while the device sleeps. In battery settings, allow Tamayura to run without restrictions.';

  @override
  String get backgroundSharingBatterySettings => 'Battery settings';

  @override
  String get settingsDownloadFolder => 'Download folder';

  @override
  String get settingsDownloadFolderEmpty =>
      'Not chosen · Downloaded originals are saved here';

  @override
  String settingsSharingSummary(int folders, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count media files',
      one: '1 media file',
    );
    String _temp1 = intl.Intl.pluralLogic(
      folders,
      locale: localeName,
      other: '$folders folders',
      one: '1 folder',
    );
    return 'Sharing $_temp0 from $_temp1';
  }

  @override
  String get settingsDownloadLayout =>
      'Originals are saved as “source device / shared folder / original subfolders”, keeping the folder structure.';

  @override
  String get settingsDeviceInfo => 'This device';

  @override
  String get settingsNoLan => 'Not connected to a local network';

  @override
  String get settingsTips => 'Tips';

  @override
  String get tipNetworkTitle => 'Join the same network';

  @override
  String get tipNetworkDescription =>
      'Only local networks are supported, and no account is needed. Share folders only on networks you trust.';

  @override
  String get tipWindowsTitle => 'Ready for Windows';

  @override
  String get tipWindowsDescription =>
      'Supports Windows 10 1809 or later and Windows 11 (x64). Allow Tamayura through the firewall for private networks, or connect by IP manually.';

  @override
  String get tipBackgroundReceiveTitle => 'Close the window, keep receiving';

  @override
  String get tipBackgroundReceiveWindows =>
      'Downloads already started continue after you close the window. Click the Tamayura icon in the system tray to reopen it, or right-click it and choose “Exit Tamayura”. If the PC sleeps or goes offline, retry in Downloads.';

  @override
  String get tipBackgroundReceiveMac =>
      'Downloads already started continue after you close the window. Reopen it from the menu bar or the Dock; it only quits when you choose “Quit Tamayura” or press ⌘Q. If the Mac sleeps or goes offline, retry in Downloads.';

  @override
  String get tipKeyboardTitle => 'Switch with the keyboard';

  @override
  String get tipKeyboardWindows =>
      'Ctrl+1 Album · Ctrl+2 Devices · Ctrl+3 or Ctrl+, Settings · Ctrl+R Refresh.';

  @override
  String get tipKeyboardMac =>
      '⌘1 Album · ⌘2 Devices · ⌘3 or ⌘, Settings · ⌘R Refresh.';

  @override
  String get tipMacTitle => 'Ready for Mac';

  @override
  String get tipMacDescription =>
      'Supports macOS Sequoia 15, Tahoe 26 and later. Folder access and camera permission are managed by the system and can be changed in System Settings.';

  @override
  String get tipAndroidTitle => 'Receiving continues in the background';

  @override
  String get tipAndroidDescription =>
      'Supports Android 16 or later. Notification permission is optional: with notifications off, downloads still run and progress shows in Downloads. With background sharing on, the source device can be locked; both devices must be on the same local network.';

  @override
  String get tipOpenTitle => 'Tap to fetch, open when downloaded';

  @override
  String get tipOpenDescription =>
      'Each shared folder appears as its own collection. Click to download the original, then open it with a system app or locate it in File Explorer.';

  @override
  String get tipShareTitle => 'Tap to fetch, share when downloaded';

  @override
  String get tipShareDescription =>
      'Each shared folder appears as its own collection, including photos and videos from all its subfolders. Tap to download the original, then use Share to send it to another app.';

  @override
  String get settingsAboutProject => 'About the project';

  @override
  String get settingsCheckUpdates => 'Check for updates';

  @override
  String get settingsCheckUpdatesSubtitle =>
      'Check GitHub for new versions; you confirm before updating';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsAboutSubtitle =>
      'Version, open-source licenses and a few musings';

  @override
  String get autoSyncDialogDescription =>
      'Timed from the latest sync attempt; an automatic sync is tried once the set number of minutes has passed. Manual and failed syncs restart the timer.';

  @override
  String get autoSyncDialogLabel => 'Interval in minutes';

  @override
  String get autoSyncDialogHelper => '1–525600 minutes, default 10';

  @override
  String get autoSyncDialogInvalid =>
      'Enter a whole number of minutes from 1 to 525600';

  @override
  String get autoSyncDialogSaveFailed =>
      'Couldn\'t save the sync interval. Please try again.';

  @override
  String get deviceOrderTitle => 'Reorder devices';

  @override
  String get deviceOrderDescription =>
      'Drag the handles or use the arrows. Devices in the album follow the same order.';

  @override
  String deviceOrderDrag(String name) {
    return 'Drag $name';
  }

  @override
  String deviceOrderMoveUp(String name) {
    return 'Move $name up';
  }

  @override
  String deviceOrderMoveDown(String name) {
    return 'Move $name down';
  }

  @override
  String get deviceOrderSaveFailed =>
      'Couldn\'t save the device order. Please try again.';

  @override
  String get previewUnavailable =>
      'The original is saved but can\'t be previewed in the app. Open it with another app.';

  @override
  String get previewReadFailed =>
      'Couldn\'t read the original for preview. Try again or open it with another app.';

  @override
  String get previewActionFailed =>
      'Couldn\'t finish. Check the network or file permissions, then try again.';

  @override
  String get previewLocalDeleted =>
      'Local file deleted. You can download it again.';

  @override
  String get previewLocalDeleteFailed =>
      'Couldn\'t delete the local file. Check folder permissions and try again.';

  @override
  String get previewDetails => 'Details';

  @override
  String get previewCloseDetails => 'Close details';

  @override
  String get detailFileName => 'File name';

  @override
  String get detailSourceDevice => 'Source device';

  @override
  String get detailDeviceStatus => 'Device status';

  @override
  String get detailDeviceUnknown => 'Device record unavailable';

  @override
  String get detailModified => 'Modified (local time)';

  @override
  String get detailType => 'Type';

  @override
  String get detailSize => 'Size';

  @override
  String detailSizeValue(String size, int bytes) {
    return '$size ($bytes bytes)';
  }

  @override
  String get detailCollection => 'Collection';

  @override
  String get detailRelativePath => 'Relative path';

  @override
  String get previewImageError =>
      'Can\'t show this preview. Download it and open it with another app.';

  @override
  String get previewBack => 'Back to album';

  @override
  String get previewDeleteLocal => 'Delete local file';

  @override
  String get previewZoomReset => 'Reset zoom';

  @override
  String get previewZoomIn => 'Zoom in';

  @override
  String get previewVideoHint =>
      'Video thumbnail · Open with the system player after downloading';

  @override
  String get previewReadingOriginal => 'Reading the local original…';

  @override
  String get previewOriginalDesktop =>
      'Local original · Double-click or scroll to zoom';

  @override
  String get previewOriginalMobile => 'Local original · Pinch to zoom';

  @override
  String get previewCachedThumbnail =>
      'Cached thumbnail · Original shows after downloading';

  @override
  String get previewResetDesktop => 'Double-click to reset';

  @override
  String get previewResetMobile => 'Double-tap to reset';

  @override
  String get previewZoomDesktop => 'Double-click to zoom';

  @override
  String get previewSwipeDown => 'Swipe down to go back';

  @override
  String previewSource(String device) {
    return 'From $device';
  }

  @override
  String get previewRetry => 'Reload preview';

  @override
  String get downloadsTitle => 'Downloads';

  @override
  String get downloadsEmptyTitle => 'Your next favorite photo is on its way';

  @override
  String get downloadsEmptyDescription =>
      'Tap a photo or video in the album to see its download progress here.';

  @override
  String get downloadsBackToAlbum => 'Back to album';

  @override
  String get downloadsAllDone => 'Everything has found its place.';

  @override
  String downloadsActive(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tasks in progress',
      one: '1 task in progress',
    );
    return '$_temp0';
  }

  @override
  String get downloadsHintWindows =>
      'Receiving continues after you close the window; reopen it from the system tray. Keep the PC awake and on the same local network as the source device. Retry if exiting or sleep interrupts a download.';

  @override
  String get downloadsHintMac =>
      'Receiving continues after you close the window; reopen it from the menu bar or the Dock. Keep the Mac awake and on the same local network as the source device. Retry if quitting or sleep interrupts a download.';

  @override
  String get downloadsHintMobile =>
      'Receiving continues in the background. The source device must keep Tamayura running and be on the same local network as this device.';

  @override
  String get downloadsActionFailed =>
      'Couldn\'t update the task. Please try again.';

  @override
  String get downloadsMediaFallback => 'Media file';

  @override
  String get transferQueued => 'Waiting to download';

  @override
  String get transferDownloading => 'Downloading';

  @override
  String get transferSaving => 'Saving to download folder';

  @override
  String get transferCompleted => 'Saved to this device';

  @override
  String get transferFailed => 'Download failed';

  @override
  String get transferPaused => 'Paused';

  @override
  String get transferDiscarded => 'Waiting to clean up staged data';

  @override
  String get transferNotDownloaded => 'Original not downloaded';

  @override
  String get transferContinues =>
      'You can go back to the album or switch apps; receiving continues.';

  @override
  String transferStaged(String size) {
    return 'About $size staged. Pausing keeps it; deleting the task frees the space.';
  }

  @override
  String transferAttempt(int attempt) {
    return 'Attempt $attempt';
  }

  @override
  String get transferShowInFolder => 'Show in folder';

  @override
  String get transferPlayVideo => 'Play video';

  @override
  String get transferOpenWith => 'Open with another app';

  @override
  String get transferPause => 'Pause download';

  @override
  String get transferRetry => 'Retry download';

  @override
  String get transferResume => 'Resume download';

  @override
  String get transferDownloadOriginal => 'Download original';

  @override
  String get transferCancelAndDelete => 'Cancel and delete';

  @override
  String get transferDeleteTask => 'Delete task and free space';

  @override
  String transferRetryLater(String error) {
    return '$error; will retry automatically';
  }

  @override
  String get updateTitle => 'Check for updates';

  @override
  String get updateChecking => 'Checking for updates…';

  @override
  String get updateUpToDate => 'You\'re up to date';

  @override
  String updateAvailable(String version) {
    return 'New version $version available';
  }

  @override
  String get updateSystemFailed =>
      'The system couldn\'t complete the update. Please try again.';

  @override
  String get updateFailed =>
      'Update failed. Check the network, disk space and install permission, then try again.';

  @override
  String updateConfirmTitle(String version) {
    return 'Update to $version?';
  }

  @override
  String get updateConfirmMac =>
      'This opens the GitHub Release page for this version. Download the macOS package and upgrade manually.';

  @override
  String get updateConfirmAutomatic =>
      'The package will be downloaded and verified, then installation starts automatically. Updating interrupts sharing and transfers; unfinished downloads can be retried after reopening.\n\nBefore v1.0.0, old data and connections between different versions aren\'t guaranteed to work. Read the release notes; you may need to choose folders and connect devices again.';

  @override
  String get updateConfirmAndroid =>
      'Android may ask you to allow installs from this source and to confirm in a system screen.';

  @override
  String get updateConfirmWindows => 'Windows will exit and restart Tamayura.';

  @override
  String get updateDecline => 'Not now';

  @override
  String get updateOpenDownloadPage => 'Open download page';

  @override
  String get updateDownloadAndInstall => 'Download and install';

  @override
  String get updateOpenedDownloadPage =>
      'Opened the download page for this version. Please upgrade manually.';

  @override
  String get updateDownloading => 'Downloading package…';

  @override
  String get updateVerifying => 'Verifying package…';

  @override
  String get updatePreparing => 'Preparing to install…';

  @override
  String get updateExiting =>
      'Finishing transfers; Tamayura will reopen after installing…';

  @override
  String get updateHandedToSystem =>
      'Handed over to the system installer. Follow the system prompts.';

  @override
  String get updateDownloadCancelled => 'Download cancelled';

  @override
  String get updateInstallIncomplete =>
      'Installation didn\'t finish. Please try again.';

  @override
  String get updateInstalled => 'Installed. Please reopen Tamayura.';

  @override
  String get updatePendingUserAction =>
      'Confirm the update in the system installer';

  @override
  String updateCurrentVersion(String version) {
    return 'Current version $version';
  }

  @override
  String get updateIncomplete => 'Update not finished';

  @override
  String get updateCancelDownload => 'Cancel download';

  @override
  String get updateExitFailedHint =>
      'Sharing and transfers have stopped; you can retry finishing the installation. If it still fails, choose “Exit Tamayura” from the system tray and reopen it.';

  @override
  String get updateRetryInstall => 'Retry install';

  @override
  String get updateCheckAgain => 'Check again';

  @override
  String get updateFinishExit => 'Exit and install';

  @override
  String get updateSourceNote =>
      'Published versions (including pre-releases) come from GitHub and need an internet connection.';

  @override
  String get updateReleaseNotes => 'Release notes';

  @override
  String get updateNoReleaseNotes => 'This version has no release notes.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutSummary =>
      'Browse and fetch photos and videos across devices on your local network, keeping beautiful moments within reach.';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutReadingVersion => 'Reading version…';

  @override
  String get aboutVersionUnavailable => 'Can\'t read the version right now';

  @override
  String get aboutProjectLicense => 'Project license';

  @override
  String get aboutThirdPartyLicenses => 'Open-source licenses';

  @override
  String get aboutThirdPartyLicensesSubtitle =>
      'Thanks to Flutter and the open-source community';

  @override
  String get aboutMusings => 'Musings';

  @override
  String get aboutMusingsSubtitle =>
      'On the name, photography, and a special port';

  @override
  String get licenseIntro =>
      'Tamayura is licensed under the Apache License 2.0. The full license text follows.';

  @override
  String get licenseReading => 'Reading license…';

  @override
  String get licenseUnavailable => 'Can\'t read the license text right now';

  @override
  String get musingNameTitle => 'Named after Tamayura';

  @override
  String get musingNameText =>
      'The project is named after the anime Tamayura (たまゆら). It follows everyday life and growing up through photography: Fu Sawatari, who loves taking pictures, comes to her father\'s hometown of Takehara in Hiroshima Prefecture, captures the scenery around her with her camera, and searches for life\'s small joys with her friends.';

  @override
  String get musingMomentsTitle => 'Keep beautiful moments close';

  @override
  String get musingMomentsText =>
      'Photography gives fleeting light, scenery and smiles a place where we can meet them again. Tamayura exists for the same reason: to let what you capture flow easily between your own devices. Whichever device a photo lives on, I hope you can always find it, bring it back, and share it with the people you care about.';

  @override
  String get musingPortTitle => '50728, a small tribute';

  @override
  String musingPortText(int port) {
    return 'Fu Sawatari\'s birthday is July 28, 1995. Taking the last digit of the year, “5”, and the month and day, “0728”, gives Tamayura\'s default port, $port. Every connection carries a little fondness for the anime.';
  }

  @override
  String get defaultDeviceName => 'My device';

  @override
  String get lanDeviceFallback => 'Local network device';

  @override
  String get fallbackFolderName => 'Folder';

  @override
  String get spaceLocationDownloadDisk => 'download disk';

  @override
  String get spaceLocationStaging => 'download staging folder';

  @override
  String get spaceLocationDestination => 'download folder';

  @override
  String get errorAppNotReady =>
      'The app hasn\'t finished starting. Please try again shortly.';

  @override
  String get errorAppNotReadyTheme =>
      'The app hasn\'t finished starting. Try changing the theme again.';

  @override
  String get errorDeviceOrderSave =>
      'Couldn\'t save the device order. Please try again.';

  @override
  String get errorThemeSave => 'Couldn\'t save the theme. Please try again.';

  @override
  String get errorLanguageSave =>
      'Couldn\'t save the language. Please try again.';

  @override
  String get errorDetailedModeSave =>
      'Couldn\'t save the album display mode. Please try again.';

  @override
  String get errorAutoSyncRange =>
      'Enter a whole number of minutes from 1 to 525600 for the auto sync interval.';

  @override
  String get errorAutoSyncSave =>
      'Couldn\'t save the auto sync interval. Please try again.';

  @override
  String errorStagingCleanup(String error) {
    return 'Some staged download data couldn\'t be cleaned up; you can retry deleting the task. $error';
  }

  @override
  String errorDiscoveryUnavailable(String error) {
    return 'Device discovery is unavailable; you can connect by IP instead. $error';
  }

  @override
  String get errorAutoDiscoveryUnavailable =>
      'Automatic discovery is unavailable. Connect manually on the Devices page.';

  @override
  String get errorAddressInUse =>
      'This IP address is used by another device. Discover devices again.';

  @override
  String get errorOwnAddress =>
      'That\'s this device\'s address. Enter the other device\'s address.';

  @override
  String get errorFolderAlreadyShared => 'This folder is already shared.';

  @override
  String get errorSharingIdentity =>
      'Couldn\'t verify the sharing service identity';

  @override
  String get errorSharingConfirm =>
      'Couldn\'t confirm that background sharing started. Please try again.';

  @override
  String get errorPeerStalled =>
      'The other device hasn\'t responded for a while. It may be asleep or off the local network.';

  @override
  String get errorSystemOperation =>
      'The system operation failed. Please try again.';

  @override
  String get errorPeerFileMissing =>
      'The file was deleted or can\'t be accessed on the other device. Refresh the album.';

  @override
  String get errorPeerFolderUnavailable =>
      'The other device\'s shared folder is unavailable. Choose the folder again on that device and refresh.';

  @override
  String get errorTransferIncomplete =>
      'The file didn\'t transfer completely. Please try again.';

  @override
  String get errorPeerUnreachable =>
      'Can\'t reach this device right now. Make sure both devices are on the same local network and the app is open on the other device.';

  @override
  String get errorNetworkUnavailable =>
      'Can\'t connect to the local network. Check Wi-Fi and try again.';

  @override
  String get errorFileSave =>
      'Couldn\'t save the file. Check free space and folder permissions.';

  @override
  String errorUnknown(String error) {
    return 'Couldn\'t finish. Please try again. $error';
  }

  @override
  String get errorFolderOverlap =>
      'This folder is already shared, or it contains or is inside a shared folder.';

  @override
  String get errorFileChanged => 'The file size changed. Refresh the album.';

  @override
  String get errorScanCancelled => 'Shared folders changed. Scan again.';

  @override
  String get errorAddressRequired =>
      'Enter a local IPv4 address, or scan a Tamayura QR code.';

  @override
  String errorAddressInvalid(int port) {
    return 'Enter a valid local IPv4 address, such as 192.168.1.8:$port.';
  }

  @override
  String get errorAddressNotPrivate =>
      'Only private local IPv4 addresses are supported for now.';

  @override
  String get errorPortRange => 'The port must be from 1 to 65535.';

  @override
  String get errorVersionUnreadable =>
      'Couldn\'t read the app version. Please try again.';

  @override
  String get errorAppExiting =>
      'The app is exiting. Reopen it and retry the download.';

  @override
  String get errorSharedFolderConfig =>
      'The shared folder settings are invalid. Choose the folder again.';

  @override
  String get errorMediaPath => 'The media file\'s relative path is invalid.';

  @override
  String get errorMediaFolderPath =>
      'The media file\'s shared folder or relative path is invalid.';

  @override
  String get errorCatalogChanged =>
      'The media catalog was updated. Sync again.';

  @override
  String get errorSharedFoldersChanged =>
      'Shared folders were updated. Please try again shortly.';

  @override
  String get errorTaskIdMissing => 'The download task has no ID.';

  @override
  String get errorAddressOwnedByOther =>
      'This address belongs to another device. Discover devices again and retry.';

  @override
  String errorSpaceInsufficient(String location) {
    return 'Not enough space in the $location. Free up space and try again.';
  }

  @override
  String get errorChunkSize =>
      'A received file chunk has the wrong size. Refresh and try again.';

  @override
  String get errorChunkIncomplete =>
      'A file chunk didn\'t transfer completely. Retry to continue the download.';

  @override
  String get errorDownloadSizeMismatch =>
      'The downloaded file size doesn\'t match the catalog. Refresh and try again.';

  @override
  String get errorDatabaseDirectory =>
      'The local database folder is unavailable. Check your user folder permissions and try again.';

  @override
  String get errorTransferTarget =>
      'The media\'s device or shared folder is invalid. Refresh the album.';

  @override
  String get errorStagingNotCleaned =>
      'Staged files haven\'t been cleaned up. Retry deleting the task first.';

  @override
  String get errorStagingCleanupFailed =>
      'Couldn\'t clean up staged data. Retry deleting the task.';

  @override
  String get errorFileDeletedRedownload =>
      'The file was deleted. Download it again.';

  @override
  String get errorTaskInterrupted =>
      'The task was interrupted. Tap retry to continue downloading.';

  @override
  String get errorCatalogVersion => 'Invalid media catalog version.';

  @override
  String get errorCatalogCursor => 'Invalid media catalog page position.';

  @override
  String get errorCatalogInvalidEntries =>
      'The other device\'s media catalog contains invalid or duplicate files.';

  @override
  String get errorCatalogInvalidEntriesRefresh =>
      'The other device\'s media catalog contains invalid or duplicate files. Refresh and try again.';

  @override
  String get errorCatalogDuplicate =>
      'The other device\'s media catalog contains duplicate files. Please try again.';

  @override
  String get errorCatalogCount =>
      'The other device\'s media catalog count doesn\'t match. Please try again.';

  @override
  String get errorCatalogIncomplete =>
      'The media catalog wasn\'t fully received; the existing offline album is unchanged.';

  @override
  String get errorThumbnailTooLarge =>
      'The thumbnail exceeds the allowed size.';

  @override
  String get errorIncompatiblePeer =>
      'The other device isn\'t a compatible Tamayura device. Make sure both run the same app version.';

  @override
  String get errorPeerPaging =>
      'The other device sent invalid catalog paging. Refresh and try again.';

  @override
  String get errorPeerCatalogInvalid =>
      'The other device returned an invalid media catalog. Refresh and try again.';

  @override
  String get errorPeerThumbnail =>
      'The other device sent an invalid thumbnail. Refresh and try again.';

  @override
  String get errorPeerCatalogCount =>
      'The other device\'s catalog count doesn\'t match. Please try again.';

  @override
  String get errorPeerCatalogVersion =>
      'The other device\'s catalog changed. Please try again.';

  @override
  String get errorPeerCatalogPageRepeated =>
      'The other device repeated a catalog page. Please try again.';

  @override
  String get errorChunkInvalid =>
      'A received file chunk is invalid. Download again.';

  @override
  String get errorTransferEnded =>
      'The file transfer ended early. Download again.';

  @override
  String get errorSharingStatus =>
      'Couldn\'t read the background sharing status. Please try again.';

  @override
  String get errorStagingUnavailable =>
      'The download staging folder is unavailable.';

  @override
  String get errorSaveFailed => 'Couldn\'t save the file.';

  @override
  String get errorCacheUnavailable => 'The temporary folder is unavailable.';

  @override
  String errorDeviceId(String platform) {
    return 'Couldn\'t read the $platform device identifier. Restart the app and try again.';
  }

  @override
  String errorPlatformUnsupported(String platform) {
    return '$platform isn\'t supported yet.';
  }

  @override
  String get updateErrorCancelled => 'Update download cancelled';

  @override
  String get updateErrorCurrentVersion =>
      'Can\'t identify the current app version. Reinstall an official release package.';

  @override
  String get updateErrorReleaseList =>
      'GitHub\'s release list has an unexpected format. Please try again later.';

  @override
  String get updateErrorPageUrl =>
      'The update page address is invalid. Please try again later.';

  @override
  String get updateErrorNotes =>
      'The release notes have an unexpected format. Please try again later.';

  @override
  String get updateErrorListTooLong =>
      'The release list is too long to determine the latest version. Please check GitHub.';

  @override
  String get updateErrorManifest =>
      'The new version\'s update manifest is invalid; automatic update isn\'t available.';

  @override
  String get updateErrorManifestMismatch =>
      'The new version\'s update manifest doesn\'t match the release.';

  @override
  String get updateErrorAndroidBuild =>
      'The new version\'s Android build number is invalid; it can\'t be installed over this one.';

  @override
  String get updateErrorPackageInfo =>
      'The new version has no valid package for this platform.';

  @override
  String get updateErrorArchitecture =>
      'The new version\'s package architecture isn\'t supported.';

  @override
  String get updateErrorPackageSize =>
      'The new version\'s package size doesn\'t match its update manifest.';

  @override
  String get updateErrorInvalidPackage =>
      'The package information is invalid. Check for updates again.';

  @override
  String get updateErrorDownloadSize =>
      'The downloaded package size doesn\'t match the update manifest. Please try again.';

  @override
  String get updateErrorDownloadTooLarge =>
      'The downloaded package is larger than the update manifest allows. Please try again.';

  @override
  String get updateErrorChecksum =>
      'The package failed its integrity check. Download it again.';

  @override
  String get updateErrorBusy =>
      'Another update operation is in progress. Please wait.';

  @override
  String get updateErrorTimeout =>
      'Connecting to GitHub or downloading the package timed out. Check the network and try again.';

  @override
  String get updateErrorConnect =>
      'Can\'t connect to GitHub. Check the network and try again.';

  @override
  String get updateErrorConnectionLost =>
      'The connection to GitHub was interrupted. Please try again later.';

  @override
  String get updateErrorStorage =>
      'Couldn\'t save the update package. Check free space and folder permissions, then try again.';

  @override
  String get updateErrorFormat =>
      'The update information has an unexpected format. Please try again later.';

  @override
  String get updateErrorResponseTooLarge =>
      'The update information exceeds the allowed size. Please try again later.';

  @override
  String get updateErrorRedirect =>
      'GitHub\'s download redirect looks wrong. Please try again later.';

  @override
  String get updateErrorForbidden =>
      'GitHub denied access or rate-limited the request. Please try again later.';

  @override
  String get updateErrorUnavailable =>
      'GitHub\'s update information or package is temporarily unavailable. Please try again later.';

  @override
  String get updateErrorEncoding =>
      'GitHub returned an unsupported download encoding. Please try again later.';

  @override
  String get updateErrorUntrustedUrl =>
      'The update download address isn\'t trusted. The update was stopped.';

  @override
  String get updateErrorNoAssets =>
      'The new version has no release assets; automatic update isn\'t available.';

  @override
  String get updateErrorAmbiguousAssets =>
      'The new version lacks a single complete release asset; automatic update isn\'t available.';

  @override
  String get updateErrorAssetsPending =>
      'The new version\'s release assets haven\'t finished uploading. Please try again later.';

  @override
  String get updateErrorAssetUrl =>
      'The update asset address doesn\'t match the release.';

  @override
  String get updateErrorPlatform =>
      'App updates aren\'t supported on this platform yet.';

  @override
  String get updateErrorStagingDirectory =>
      'Couldn\'t create the update staging folder. Check disk space and try again.';

  @override
  String get updateErrorInstallInfo =>
      'This version has no valid installation information.';

  @override
  String get updateErrorInstallStart =>
      'Couldn\'t confirm that installation started. Please try again.';

  @override
  String get updateErrorReleaseUrl => 'The update page address is invalid.';
}
