// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Tamayura · 玉响';

  @override
  String get appLocalName => '玉响';

  @override
  String get commonCancel => '取消';

  @override
  String get commonSave => '保存';

  @override
  String get commonSaving => '正在保存…';

  @override
  String get commonRetry => '重试';

  @override
  String get commonDone => '完成';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonConnect => '连接';

  @override
  String get commonShare => '分享';

  @override
  String get commonOnline => '在线';

  @override
  String get commonOffline => '离线';

  @override
  String get commonVideo => '视频';

  @override
  String get commonImage => '图片';

  @override
  String get navAlbum => '相册';

  @override
  String get navDevices => '设备';

  @override
  String get navSettings => '设置';

  @override
  String get homeDownloadsTooltip => '下载任务';

  @override
  String get homeRefreshTooltip => '刷新设备和相册';

  @override
  String get homeOpening => '正在打开你的随身相册…';

  @override
  String get homeActionFailed => '操作未能完成，请检查网络与目录权限后重试。';

  @override
  String get homeErrorRetry => '重试连接与刷新';

  @override
  String get homeErrorDismiss => '关闭提示';

  @override
  String get albumHeadline => '每一刻，都在手边。';

  @override
  String get albumSubtitle => '按共享文件夹浏览合集，轻点照片就存到这里。';

  @override
  String get albumAllDevices => '全部设备';

  @override
  String get albumAllCollections => '全部合集';

  @override
  String get albumSharedCollectionFallback => '共享合集';

  @override
  String get albumDeleteLocalFiles => '删除本地文件';

  @override
  String albumCollectionCount(int count) {
    return '$count 个合集';
  }

  @override
  String albumMomentCount(int count) {
    return '$count 个瞬间';
  }

  @override
  String get albumSelectSavedHint => '选择已保存的图片或视频';

  @override
  String get albumTapToDownloadHint => '轻点下载原文件';

  @override
  String get albumReceivingTitle => '正在接收相册';

  @override
  String get albumReceivingDescription => '缩略图会陆续显示，你可以边同步边浏览。';

  @override
  String get albumSyncIncompleteTitle => '同步尚未完成';

  @override
  String get albumSyncIncompleteDescription => '请检查两台设备的连接，然后重试同步。';

  @override
  String get albumNoDevicesTitle => '让照片相遇';

  @override
  String get albumNoDevicesDescription =>
      '在另一台设备上打开玉响，连接同一个局域网。\n发现设备后，共享文件夹会以合集出现在这里。';

  @override
  String get albumEmptyCollectionTitle => '这个合集还没有照片';

  @override
  String get albumNoCollectionsTitle => '这里还没有合集';

  @override
  String get albumNoMediaDesktopDescription =>
      '对方需要选择共享目录，并保持玉响运行。\n点击右上角刷新，更新已连接设备的相册。';

  @override
  String get albumNoMediaMobileDescription =>
      '对方需要选择共享目录，开启后台共享后锁屏也能访问。\n点击右上角刷新，更新已连接设备的相册。';

  @override
  String get albumConnectDevice => '连接一台设备';

  @override
  String get albumLoadMoreFailed => '更多照片暂时未能加载，请重试。';

  @override
  String get albumLoadingMore => '正在加载更多照片…';

  @override
  String get albumLoadMore => '加载更多照片';

  @override
  String get albumRetryLoad => '重试加载';

  @override
  String get albumLoadingThumbnail => '正在加载缩略图';

  @override
  String get albumRetryThumbnail => '重试加载缩略图';

  @override
  String get albumSortTooltip => '按名称或文件修改日期排序';

  @override
  String get albumSorting => '正在排序…';

  @override
  String albumSortLabel(String order) {
    return '排序：$order';
  }

  @override
  String get albumSortNameAscending => '名称升序';

  @override
  String get albumSortNameDescending => '名称降序';

  @override
  String get albumSortDateAscending => '日期升序';

  @override
  String get albumSortDateDescending => '日期降序';

  @override
  String albumSelectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get albumDeleting => '正在删除…';

  @override
  String albumLocalDeleted(int count) {
    return '已删除 $count 个本地文件，可轻点缩略图重新下载。';
  }

  @override
  String albumLocalDeletePartial(int deleted, int failed) {
    return '已删除 $deleted 个本地文件，$failed 个未能删除，请检查目录权限后重试。';
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
    return '快速滚动相册，$label';
  }

  @override
  String get rememberedDeviceFallback => '已记住的设备';

  @override
  String get setupTitle => '先安顿好你的相册';

  @override
  String get setupDescription => '添加要分享的文件夹，以及收到照片后存放的位置。';

  @override
  String get setupShareFolder => '共享文件夹';

  @override
  String get setupDownloadFolder => '接收目录';

  @override
  String collectionSemantics(String folder, String device, int count) {
    return '$folder，来自$device，$count 个瞬间';
  }

  @override
  String mediaSemantics(String name, String device, String state) {
    return '$name，来自$device，$state';
  }

  @override
  String get mediaStateSaved => '已保存';

  @override
  String get mediaStateDownloading => '正在下载';

  @override
  String get mediaStateFailed => '下载失败，点击重试';

  @override
  String get mediaStateTapToDownload => '点击下载原文件';

  @override
  String get mediaStateOffline => '设备离线，点击查看详情';

  @override
  String get mediaDeviceOffline => '设备离线';

  @override
  String mediaDownloadingName(String name) {
    return '正在下载 $name';
  }

  @override
  String mediaSelectName(String name) {
    return '选择 $name';
  }

  @override
  String mediaNotSavedName(String name) {
    return '$name 尚未保存';
  }

  @override
  String get mediaDeleteLocalOnly => '仅删除本地文件';

  @override
  String get mediaNotSaved => '尚未保存';

  @override
  String get mediaDownloadFailedRetry => '下载失败 · 重试';

  @override
  String get mediaReceivingOriginal => '正在接收原文件…';

  @override
  String mediaCardDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.MMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get devicesTitle => '附近的伙伴';

  @override
  String get devicesSubtitle => '同一个局域网，让每台设备的相册连在一起。';

  @override
  String get devicesThisDevice => '这台设备';

  @override
  String get devicesNoAddress => '暂无局域网地址，请连接网络后刷新';

  @override
  String get devicesShowQr => '展示连接二维码';

  @override
  String get devicesConnectByIp => '输入 IP 连接';

  @override
  String get devicesScan => '扫一扫';

  @override
  String get devicesConnecting => '正在连接设备…';

  @override
  String get devicesRemembered => '已记住的设备';

  @override
  String devicesOnlineCount(int count) {
    return '$count 台在线';
  }

  @override
  String get devicesReorder => '调整顺序';

  @override
  String get devicesEmptyTitle => '等待另一台玉响';

  @override
  String get devicesEmptyDescription =>
      '设备会通过局域网自动发现。\n如果暂时没找到，可以输入 IP 或扫描二维码连接。';

  @override
  String get devicesFooterWindows =>
      '设备离线后仍会保留相册缩略图。共享与接收需要玉响运行、电脑保持唤醒，并与来源设备处于同一局域网。';

  @override
  String get devicesFooterMac =>
      '设备离线后仍会保留相册缩略图。共享与接收需要玉响保持运行、Mac 保持唤醒，并与来源设备处于同一局域网。';

  @override
  String get devicesFooterMobile =>
      '设备离线后仍会保留相册缩略图。来源设备开启后台共享后，锁屏也能提供原文件；这台设备可以切换到其他应用继续接收。';

  @override
  String deviceLastSuccessfulSync(String time) {
    return '最后成功同步：$time';
  }

  @override
  String get deviceNeverSynced => '尚未成功同步';

  @override
  String get devicePendingApproval => '新发现的设备 · 尚未开启相册同步';

  @override
  String get deviceSyncDeclined => '未开启相册同步';

  @override
  String get deviceOfflineCached => '离线 · 可浏览缓存';

  @override
  String get deviceActions => '设备操作';

  @override
  String get deviceEnableAlbumSync => '开启相册同步';

  @override
  String get deviceForget => '忘记设备';

  @override
  String get deviceStartSync => '开启同步';

  @override
  String deviceForgotten(String name) {
    return '已忘记「$name」，再次发现时会作为新设备询问是否同步。';
  }

  @override
  String get deviceForgetFailed => '未能忘记这台设备，请稍后重试。';

  @override
  String deviceForgetTitle(String name) {
    return '忘记「$name」？';
  }

  @override
  String get deviceForgetMessage =>
      '将从设备列表移除这台设备，并删除它的离线相册信息、缩略图和未完成的同步进度。\n\n已下载到本机的文件和下载任务不受影响，对端的原文件也不会被删除。再次在局域网中发现它时，会作为新设备询问是否同步。';

  @override
  String get syncApprovalTitle => '发现新设备';

  @override
  String syncApprovalMessage(String name, String address) {
    return '「$name」（$address）出现在局域网中。是否同步它共享的相册？\n\n同步只获取文件信息和缩略图，原文件仍在点开时下载。选择「暂不同步」后，可以随时在「设备」页面开启。';
  }

  @override
  String get syncApprovalDecline => '暂不同步';

  @override
  String get syncApprovalAccept => '开始同步';

  @override
  String get connectDialogTitle => '连接另一台设备';

  @override
  String get connectDialogHint => '在对方的「设备」页面找到 IP 地址。';

  @override
  String get connectDialogLabel => 'IP 地址与端口';

  @override
  String get connectDialogEmpty => '请输入对方的 IP 地址';

  @override
  String get qrDialogHint => '另一台设备打开玉响扫一扫';

  @override
  String qrSemantics(String address, int port) {
    return '本机连接二维码，地址 $address，端口 $port';
  }

  @override
  String get scannerTitle => '扫描设备二维码';

  @override
  String get scannerInvalidCode => '这不是玉响的设备二维码，请扫描对方「设备」页面的二维码。';

  @override
  String get scannerCameraUnavailable => '无法打开相机。请在系统设置中允许相机权限，或返回后输入 IP 连接。';

  @override
  String get scannerBack => '返回设备页面';

  @override
  String get scannerHint => '将对方的设备二维码放入镜头中\n双方需要连接同一个局域网';

  @override
  String get syncPhaseConnecting => '正在连接';

  @override
  String get syncPhaseReceiving => '正在同步相册';

  @override
  String get syncPhaseCommitting => '正在完成同步';

  @override
  String get syncPhaseCompleted => '相册同步完成';

  @override
  String get syncPhaseFailed => '本次同步未完成';

  @override
  String syncConnectingResume(int count) {
    return '已保留 $count 项，正在连接设备继续同步。';
  }

  @override
  String get syncConnectingFresh => '正在获取相册信息，请保持设备连接。';

  @override
  String syncReceivingOpen(int count) {
    return '已就绪 $count 项，正在获取更多照片。';
  }

  @override
  String syncReceivingProgress(int ready, int total) {
    return '已就绪 $ready / $total 项，可边同步边浏览。';
  }

  @override
  String get syncCommittingDetail => '缩略图已就绪，正在整理相册。';

  @override
  String syncCompletedDetail(int count) {
    return '已就绪 $count 项。';
  }

  @override
  String syncFailedResume(int count) {
    return '已保留 $count 项，恢复连接后可继续同步。';
  }

  @override
  String get syncFailedFresh => '相册和同步进度已保留，请检查连接后重试。';

  @override
  String get syncDismiss => '关闭同步提示';

  @override
  String syncProgressSemantics(String device, String status, String detail) {
    return '$device，$status，$detail';
  }

  @override
  String get syncContinue => '继续同步';

  @override
  String get settingsTitle => '你的相册，你来安排';

  @override
  String get settingsSubtitle => '只分享选定的目录，原文件按需获取。';

  @override
  String get settingsAppearance => '外观';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSaving => '正在保存主题…';

  @override
  String get settingsThemeSystemDescription => '随系统自动切换浅色和深色外观。';

  @override
  String get settingsThemeLightDescription => '已固定为浅色外观。';

  @override
  String get settingsThemeDarkDescription => '已固定为深色外观。';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageSystem => '跟随系统';

  @override
  String get settingsLanguageSaving => '正在保存语言…';

  @override
  String settingsLanguageSystemDescription(String language) {
    return '跟随系统语言，当前显示$language。系统语言不是中文或日文时显示英文。';
  }

  @override
  String settingsLanguageFixedDescription(String language) {
    return '已固定为$language，不随系统语言切换。';
  }

  @override
  String get settingsAlbum => '相册';

  @override
  String get settingsDetailedMode => '详细模式';

  @override
  String get settingsDetailedModeSaving => '正在保存显示模式…';

  @override
  String get settingsDetailedModeDescription =>
      '默认模式使用紧凑的正方形网格，点击照片查看详细信息。\n开启详细模式后，照片卡片会显示文件名、来源设备、日期和下载状态。';

  @override
  String get settingsSync => '同步';

  @override
  String get settingsAutoSyncInterval => '自动同步间隔';

  @override
  String get settingsAutoSyncSaving => '正在保存同步间隔…';

  @override
  String settingsAutoSyncDescription(int minutes) {
    return '上次同步尝试超过 $minutes 分钟后自动同步。\n手动同步和同步失败都会重新计时。点击右上角刷新可立即同步。';
  }

  @override
  String get settingsFilesStorage => '文件与存储';

  @override
  String get settingsSharedFolders => '共享文件夹';

  @override
  String get settingsSharedFoldersDescription =>
      '可添加多个文件夹，自动包含所有子目录。已添加的目录及其父目录、子目录不能重复添加。';

  @override
  String get settingsSharedFoldersEmpty => '尚未选择 · 让其他设备看到这里的照片';

  @override
  String settingsRemoveSharedFolder(String name) {
    return '移除 $name';
  }

  @override
  String get settingsAddSharedFolder => '添加共享文件夹';

  @override
  String get settingsBackgroundSharing => '后台共享';

  @override
  String get settingsBackgroundSharingWindows =>
      '关闭窗口后玉响会留在系统托盘。开启此项后，关闭或最小化窗口仍可共享；关闭此项后在窗口隐藏时停止共享。电脑需要保持唤醒。';

  @override
  String get settingsBackgroundSharingMac =>
      '关闭窗口后玉响会留在菜单栏。开启此项后，关闭、隐藏或最小化窗口仍可共享；关闭此项后在窗口隐藏时停止共享。Mac 需要保持唤醒。';

  @override
  String get settingsBackgroundSharingLinux =>
      '桌面提供状态托盘时，关闭窗口后玉响会留在托盘中；没有托盘时关闭窗口会退出玉响。开启此项后，窗口隐藏或最小化时仍可共享；关闭此项后在窗口隐藏时停止共享。电脑需要保持唤醒。';

  @override
  String get settingsBackgroundSharingMobile => '开启后锁屏仍可共享媒体；关闭后仅在使用应用时共享，更省电。';

  @override
  String get backgroundSharingStarting => '正在启动后台共享…';

  @override
  String get backgroundSharingUpdating => '正在更新后台共享…';

  @override
  String get backgroundSharingStartFailed => '后台共享启动失败，请重试。';

  @override
  String get backgroundSharingOff => '后台共享已关闭。';

  @override
  String get backgroundSharingRunningWindows => '后台共享正在运行。电脑睡眠或退出玉响后，共享会停止。';

  @override
  String get backgroundSharingRunningMac => '后台共享正在运行。Mac 睡眠或退出玉响后，共享会停止。';

  @override
  String get backgroundSharingRunningMobile => '后台共享正在运行，锁屏后仍可访问已选目录。';

  @override
  String get backgroundSharingNotRunning => '后台共享尚未运行。';

  @override
  String get backgroundSharingRetry => '重试后台共享';

  @override
  String get backgroundSharingBatteryHint =>
      '系统省电限制可能在休眠时中断共享。可在电池设置中允许玉响不受限制地运行。';

  @override
  String get backgroundSharingBatterySettings => '电池设置';

  @override
  String get settingsDownloadFolder => '接收目录';

  @override
  String get settingsDownloadFolderEmpty => '尚未选择 · 下载的原文件会保存在这里';

  @override
  String settingsSharingSummary(int folders, int count) {
    return '当前从 $folders 个目录共享 $count 个媒体文件';
  }

  @override
  String get settingsDownloadLayout => '原文件按「对端设备 / 共享文件夹 / 原有子目录」保存，保留目录层级。';

  @override
  String get settingsDeviceInfo => '本机信息';

  @override
  String get settingsNoLan => '尚未连接局域网';

  @override
  String get settingsTips => '使用小提示';

  @override
  String get tipNetworkTitle => '连接同一个网络';

  @override
  String get tipNetworkDescription => '目前仅支持局域网，设备无需登录账号。请只在可信的网络中共享目录。';

  @override
  String get tipWindowsTitle => '为 Windows 准备';

  @override
  String get tipWindowsDescription =>
      '支持 Windows 10 1809 及更新版本、Windows 11（x64）。请允许玉响通过专用网络防火墙；也可使用手动 IP 连接。';

  @override
  String get tipLinuxTitle => '为 Linux 准备';

  @override
  String get tipLinuxDescription =>
      '支持 Ubuntu 24.04 LTS 及同代或更新的发行版（x64、arm64）。自动发现需要 Avahi（avahi-daemon）；请在防火墙中允许 mDNS（UDP 5353）和玉响的服务端口，也可使用手动 IP 连接。';

  @override
  String get tipBackgroundReceiveTitle => '关闭窗口，接收继续';

  @override
  String get tipBackgroundReceiveWindows =>
      '关闭窗口后，已开始的下载继续。点击系统托盘中的玉响图标可重新打开，右键菜单可选择「退出玉响」。电脑睡眠或断网后可在下载任务中重试。';

  @override
  String get tipBackgroundReceiveMac =>
      '关闭窗口后，已开始的下载继续。从右上角菜单栏或 Dock 可重新打开；选择「退出玉响」或按 ⌘Q 才会退出。Mac 睡眠或断网后可在下载任务中重试。';

  @override
  String get tipBackgroundReceiveLinux =>
      '桌面提供状态托盘（如 KDE Plasma、Ubuntu 默认桌面、Xfce）时，关闭窗口后已开始的下载继续，点击托盘中的玉响图标可重新打开，菜单中可选择「退出玉响」；没有托盘时关闭窗口即退出。任何时候都可按 Ctrl+Q 退出。电脑睡眠或断网后可在下载任务中重试。';

  @override
  String get tipKeyboardTitle => '用键盘快速切换';

  @override
  String get tipKeyboardWindows =>
      'Ctrl+1 相册 · Ctrl+2 设备 · Ctrl+3 或 Ctrl+, 设置 · Ctrl+R 刷新。';

  @override
  String get tipKeyboardMac => '⌘1 相册 · ⌘2 设备 · ⌘3 或 ⌘, 设置 · ⌘R 刷新。';

  @override
  String get tipKeyboardLinux =>
      'Ctrl+1 相册 · Ctrl+2 设备 · Ctrl+3 或 Ctrl+, 设置 · Ctrl+R 刷新 · Ctrl+Q 退出。';

  @override
  String get tipMacTitle => '为 Mac 准备';

  @override
  String get tipMacDescription =>
      '支持 macOS Sequoia 15、Tahoe 26 及后续版本。目录访问和相机权限由系统管理，可在系统设置中调整。';

  @override
  String get tipAndroidTitle => '接收可在后台继续';

  @override
  String get tipAndroidDescription =>
      '支持 Android 16 及更新版本。通知权限为可选项，关闭通知仍可下载并在下载中心查看进度；来源设备开启后台共享后可以锁屏，双方需要处于同一局域网。';

  @override
  String get tipOpenTitle => '轻点获取，下载后打开';

  @override
  String get tipOpenDescription =>
      '每个共享文件夹显示为独立合集；点击下载原文件，可用系统应用打开，或在资源管理器中定位文件。';

  @override
  String get tipOpenDescriptionLinux =>
      '每个共享文件夹显示为独立合集；点击下载原文件，可用系统应用打开，或在文件管理器中定位文件。';

  @override
  String get tipShareTitle => '轻点获取，下载后分享';

  @override
  String get tipShareDescription =>
      '每个共享文件夹显示为独立合集，包含其所有子目录的照片与视频；点击下载原文件，再使用分享按钮发送到其他应用。';

  @override
  String get settingsAboutProject => '关于项目';

  @override
  String get settingsCheckUpdates => '检查更新';

  @override
  String get settingsCheckUpdatesSubtitle => '从 GitHub 检查新版本，由你确认后更新';

  @override
  String get settingsAbout => '关于';

  @override
  String get settingsAboutSubtitle => '版本、开源许可与一点碎碎念';

  @override
  String get autoSyncDialogDescription =>
      '从最近一次同步尝试开始计时，超过设定分钟数后尝试自动同步。手动同步和同步失败都会重新计时。';

  @override
  String get autoSyncDialogLabel => '间隔分钟数';

  @override
  String get autoSyncDialogHelper => '1–525600 分钟，默认 10 分钟';

  @override
  String get autoSyncDialogInvalid => '请输入 1–525600 之间的整数分钟';

  @override
  String get autoSyncDialogSaveFailed => '同步间隔未能保存，请重试。';

  @override
  String get deviceOrderTitle => '调整设备顺序';

  @override
  String get deviceOrderDescription => '拖动手柄或使用箭头调整，相册中的设备也会按此顺序展示。';

  @override
  String deviceOrderDrag(String name) {
    return '拖动 $name';
  }

  @override
  String deviceOrderMoveUp(String name) {
    return '上移 $name';
  }

  @override
  String deviceOrderMoveDown(String name) {
    return '下移 $name';
  }

  @override
  String get deviceOrderSaveFailed => '设备顺序保存失败，请重试。';

  @override
  String get previewUnavailable => '原文件已保存，暂无法在应用内预览。可用其他应用打开。';

  @override
  String get previewReadFailed => '原文件预览读取失败，可重试或用其他应用打开。';

  @override
  String get previewActionFailed => '操作未完成，请检查网络或文件权限后重试。';

  @override
  String get previewLocalDeleted => '已删除本地文件，可重新下载。';

  @override
  String get previewLocalDeleteFailed => '本地文件未能删除，请检查目录权限后重试。';

  @override
  String get previewDetails => '详细信息';

  @override
  String get previewCloseDetails => '关闭详细信息';

  @override
  String get detailFileName => '文件名';

  @override
  String get detailSourceDevice => '来源设备';

  @override
  String get detailDeviceStatus => '设备状态';

  @override
  String get detailDeviceUnknown => '设备记录不可用';

  @override
  String get detailModified => '修改时间（本地）';

  @override
  String get detailType => '类型';

  @override
  String get detailSize => '大小';

  @override
  String detailSizeValue(String size, int bytes) {
    return '$size（$bytes 字节）';
  }

  @override
  String get detailCollection => '合集';

  @override
  String get detailRelativePath => '相对路径';

  @override
  String get previewImageError => '无法显示这张预览图，可下载后用其他应用打开。';

  @override
  String get previewBack => '返回相册';

  @override
  String get previewDeleteLocal => '删除本地文件';

  @override
  String get previewZoomReset => '还原缩放';

  @override
  String get previewZoomIn => '放大预览';

  @override
  String get previewRotateClockwise => '顺时针旋转';

  @override
  String get previewRotateCounterclockwise => '逆时针旋转';

  @override
  String get previewPrevious => '上一个媒体文件';

  @override
  String get previewNext => '下一个媒体文件';

  @override
  String previewPosition(int current, int total) {
    return '第 $current / $total 项';
  }

  @override
  String get previewSwipeHorizontal => '左右滑动查看前后媒体';

  @override
  String get previewVideoHint => '视频缩略图 · 下载后可用系统播放器打开';

  @override
  String get previewReadingOriginal => '正在读取本机原图…';

  @override
  String get previewOriginalDesktop => '本机原图 · 双击或滚轮缩放';

  @override
  String get previewOriginalMobile => '本机原图 · 双指缩放';

  @override
  String get previewCachedThumbnail => '缓存缩略图 · 下载完成后显示原图';

  @override
  String get previewResetDesktop => '双击还原';

  @override
  String get previewResetMobile => '双击还原';

  @override
  String get previewZoomDesktop => '双击放大';

  @override
  String get previewSwipeDown => '下滑返回';

  @override
  String previewSource(String device) {
    return '来自 $device';
  }

  @override
  String get previewRetry => '重新读取预览';

  @override
  String get downloadsTitle => '下载任务';

  @override
  String get downloadsEmptyTitle => '下一张心动的照片，在路上';

  @override
  String get downloadsEmptyDescription => '轻点相册中的照片或视频，即可在这里查看下载进度。';

  @override
  String get downloadsBackToAlbum => '返回相册';

  @override
  String get downloadsAllDone => '每一份，都有着落。';

  @override
  String downloadsActive(int count) {
    return '$count 个任务正在进行';
  }

  @override
  String get downloadsHintWindows =>
      '关闭窗口后仍可继续接收，从系统托盘可重新打开。请保持电脑唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。';

  @override
  String get downloadsHintMac =>
      '关闭窗口后仍可继续接收，从菜单栏或 Dock 可重新打开。请保持 Mac 唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。';

  @override
  String get downloadsHintLinux =>
      '有状态托盘时，关闭窗口后仍可继续接收，从托盘可重新打开；没有托盘时关闭窗口会退出并中断接收。请保持电脑唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。';

  @override
  String get downloadsHintMobile => '接收可在后台继续。来源设备需要保持玉响运行，并与这台设备处于同一局域网。';

  @override
  String get downloadsActionFailed => '任务操作未完成，请重试。';

  @override
  String get downloadsMediaFallback => '媒体文件';

  @override
  String get transferQueued => '等待下载';

  @override
  String get transferDownloading => '正在下载';

  @override
  String get transferSaving => '正在保存到接收目录';

  @override
  String get transferCompleted => '已保存到本机';

  @override
  String get transferFailed => '下载失败';

  @override
  String get transferPaused => '已暂停';

  @override
  String get transferDiscarded => '等待清理暂存';

  @override
  String get transferNotDownloaded => '原文件尚未下载';

  @override
  String get transferContinues => '可返回相册或切换应用，接收任务会继续进行。';

  @override
  String transferStaged(String size) {
    return '已暂存约 $size，暂停会保留，删除任务可释放空间。';
  }

  @override
  String transferAttempt(int attempt) {
    return '第 $attempt 次尝试';
  }

  @override
  String get transferShowInFolder => '在文件夹中显示';

  @override
  String get transferPlayVideo => '播放视频';

  @override
  String get transferOpenWith => '用其他应用打开';

  @override
  String get transferPause => '暂停下载';

  @override
  String get transferRetry => '重试下载';

  @override
  String get transferResume => '继续下载';

  @override
  String get transferDownloadOriginal => '下载原文件';

  @override
  String get transferCancelAndDelete => '取消并删除';

  @override
  String get transferDeleteTask => '删除任务并释放空间';

  @override
  String transferRetryLater(String error) {
    return '$error；稍后会自动重试';
  }

  @override
  String get updateTitle => '检查更新';

  @override
  String get updateChecking => '正在检查更新…';

  @override
  String get updateUpToDate => '已是最新版本';

  @override
  String updateAvailable(String version) {
    return '发现新版本 $version';
  }

  @override
  String get updateSystemFailed => '系统无法完成更新，请重试';

  @override
  String get updateFailed => '更新操作失败，请检查网络、磁盘空间及安装权限后重试';

  @override
  String updateConfirmTitle(String version) {
    return '更新至 $version？';
  }

  @override
  String get updateConfirmMac =>
      '将打开此版本的 GitHub Release 页面，请下载 macOS 安装包并手动完成升级。';

  @override
  String get updateConfirmLinux =>
      '将打开此版本的 GitHub Release 页面，请下载对应架构的 Linux 压缩包，退出玉响后解压到新文件夹，并在其中重新运行 install-desktop-entry.sh；确认新版本正常后可删除旧文件夹。';

  @override
  String get updateConfirmAutomatic =>
      '确认后下载并校验安装包，完成后自动发起安装。更新会中断共享和传输，未完成的下载可在重新打开后重试。\n\nv1.0.0 前不保证旧数据或跨版本互联兼容，请阅读更新说明；必要时需重新选择目录并连接设备。';

  @override
  String get updateConfirmAndroid => 'Android 可能要求允许安装此来源的应用，并在系统界面确认。';

  @override
  String get updateConfirmWindows => 'Windows 将退出并重新启动玉响。';

  @override
  String get updateDecline => '暂不更新';

  @override
  String get updateOpenDownloadPage => '打开下载页面';

  @override
  String get updateDownloadAndInstall => '下载并安装';

  @override
  String get updateOpenedDownloadPage => '已打开此版本的下载页面，请手动完成升级';

  @override
  String get updateDownloading => '正在下载安装包…';

  @override
  String get updateVerifying => '正在校验安装包…';

  @override
  String get updatePreparing => '正在准备安装…';

  @override
  String get updateExiting => '正在结束传输，安装后将重新打开玉响…';

  @override
  String get updateHandedToSystem => '已交给系统安装，请完成系统提示';

  @override
  String get updateDownloadCancelled => '已取消下载';

  @override
  String get updateInstallIncomplete => '安装未完成，请重试';

  @override
  String get updateInstalled => '安装完成，请重新打开玉响';

  @override
  String get updatePendingUserAction => '请在系统安装界面确认更新';

  @override
  String updateCurrentVersion(String version) {
    return '当前版本 $version';
  }

  @override
  String get updateIncomplete => '更新未完成';

  @override
  String get updateCancelDownload => '取消下载';

  @override
  String get updateExitFailedHint =>
      '应用已停止共享和传输，可重试完成安装；如仍失败，请从系统托盘选择「退出玉响」后重新打开。';

  @override
  String get updateRetryInstall => '重试安装';

  @override
  String get updateCheckAgain => '重新检查';

  @override
  String get updateFinishExit => '完成退出并安装';

  @override
  String get updateSourceNote => '从 GitHub 获取已公开版本（包括预发布），需要互联网连接。';

  @override
  String get updateReleaseNotes => '更新说明';

  @override
  String get updateNoReleaseNotes => '此版本未提供更新说明。';

  @override
  String get aboutTitle => '关于';

  @override
  String get aboutSummary => '在局域网设备之间浏览与按需传递照片、视频，让美好的瞬间随手可及。';

  @override
  String get aboutVersion => '版本号';

  @override
  String get aboutReadingVersion => '正在读取版本…';

  @override
  String get aboutVersionUnavailable => '暂时无法读取版本信息';

  @override
  String get aboutProjectLicense => '项目开源许可';

  @override
  String get aboutThirdPartyLicenses => '第三方开源许可';

  @override
  String get aboutThirdPartyLicensesSubtitle => '感谢 Flutter 与开源社区';

  @override
  String get aboutMusings => '碎碎念';

  @override
  String get aboutMusingsSubtitle => '关于名字、摄影，还有一个特别的端口';

  @override
  String get licenseIntro => 'Tamayura 采用 Apache License 2.0 开源许可。以下为完整许可正文。';

  @override
  String get licenseReading => '正在读取许可…';

  @override
  String get licenseUnavailable => '暂时无法读取许可正文';

  @override
  String get musingNameTitle => '名字来自《玉响》';

  @override
  String get musingNameText =>
      '项目取名自动画《玉响》（Tamayura / たまゆら）。这是一部以摄影为线索、描绘日常与成长的动画：喜欢摄影的沢渡楓来到父亲的故乡——广岛县竹原市，用相机记录身边的风景，也与朋友们一起寻找生活中的小小幸福。';

  @override
  String get musingMomentsTitle => '把美好的瞬间，留在身边';

  @override
  String get musingMomentsText =>
      '摄影让转瞬即逝的光、风景和笑容有了可以重逢的地方。玉响这个项目也是为此而生：让记录下来的美好，在自己的设备之间轻松流动。无论照片留在哪一台设备里，都希望你能随时翻到、取回，再分享给在意的人。';

  @override
  String get musingPortTitle => '50728，一个小小的纪念';

  @override
  String musingPortText(int port) {
    return '沢渡（さわたり）楓（ふう）的生日是 1995 年 7 月 28 日。取年份末位的「5」和月日的「0728」，组成了玉响的默认端口 $port。每一次连接，也藏着对这部动画的一点喜欢。';
  }

  @override
  String get defaultDeviceName => '我的设备';

  @override
  String get lanDeviceFallback => '局域网设备';

  @override
  String get fallbackFolderName => '目录';

  @override
  String get spaceLocationDownloadDisk => '下载所在磁盘';

  @override
  String get spaceLocationStaging => '下载暂存目录';

  @override
  String get spaceLocationDestination => '接收目录';

  @override
  String get errorAppNotReady => '应用尚未完成初始化，请稍后重试';

  @override
  String get errorAppNotReadyTheme => '应用尚未完成初始化，请重试后切换主题';

  @override
  String get errorDeviceOrderSave => '设备顺序保存失败，请重试';

  @override
  String get errorThemeSave => '主题设置保存失败，请重试';

  @override
  String get errorLanguageSave => '语言设置保存失败，请重试';

  @override
  String get errorDetailedModeSave => '相册详细模式设置保存失败，请重试';

  @override
  String get errorAutoSyncRange => '自动同步间隔请输入 1–525600 的整数分钟';

  @override
  String get errorAutoSyncSave => '自动同步间隔保存失败，请重试';

  @override
  String errorStagingCleanup(String error) {
    return '部分下载暂存未能清理，可重试删除任务。$error';
  }

  @override
  String errorDiscoveryUnavailable(String error) {
    return '设备发现暂不可用，可手动输入 IP 连接。$error';
  }

  @override
  String get errorAutoDiscoveryUnavailable => '自动发现暂不可用，可在「设备」中手动连接。';

  @override
  String get errorAddressInUse => '此 IP 地址已由另一台设备使用，请重新发现设备';

  @override
  String get errorOwnAddress => '这是本机地址，请输入另一台设备的地址';

  @override
  String get errorFolderAlreadyShared => '这个目录已在共享列表中，无需重复添加';

  @override
  String get errorSharingIdentity => '共享服务身份核验失败';

  @override
  String get errorSharingConfirm => '后台共享启动确认失败，请重试';

  @override
  String get errorPeerStalled => '对端长时间没有响应，可能已休眠或离开局域网';

  @override
  String get errorSystemOperation => '系统操作失败，请重试';

  @override
  String get errorPeerFileMissing => '对端文件已删除或不可访问，请刷新相册';

  @override
  String get errorPeerFolderUnavailable => '对端共享目录不可用，请在对端重新选择目录并刷新';

  @override
  String get errorTransferIncomplete => '文件未传输完整，请重试';

  @override
  String get errorPeerUnreachable => '暂时连不上这台设备，请确认两台设备在同一局域网，且对端应用已打开';

  @override
  String get errorNetworkUnavailable => '无法连接局域网，请检查 Wi-Fi 后重试';

  @override
  String get errorFileSave => '文件保存失败，请检查剩余空间和目录权限';

  @override
  String errorUnknown(String error) {
    return '操作未完成，请重试。$error';
  }

  @override
  String get errorFolderOverlap => '此目录已共享，或与现有共享目录存在父子关系';

  @override
  String get errorFileChanged => '文件大小已改变，请刷新相册';

  @override
  String get errorScanCancelled => '共享目录已改变，请重新扫描';

  @override
  String get errorAddressRequired => '请输入局域网 IPv4 地址，或扫描 Tamayura 二维码';

  @override
  String errorAddressInvalid(int port) {
    return '请输入有效的局域网 IPv4 地址，例如 192.168.1.8:$port';
  }

  @override
  String get errorAddressNotPrivate => '当前原型仅支持局域网私有 IPv4 地址';

  @override
  String get errorPortRange => '端口应为 1 到 65535';

  @override
  String get errorVersionUnreadable => '无法读取应用版本信息，请重试';

  @override
  String get errorAppExiting => '应用正在退出，请重新打开后重试下载';

  @override
  String get errorSharedFolderConfig => '共享目录配置无效，请重新选择目录';

  @override
  String get errorMediaPath => '媒体文件的相对路径无效';

  @override
  String get errorMediaFolderPath => '媒体文件的共享目录或相对路径无效';

  @override
  String get errorCatalogChanged => '媒体目录已更新，请重试同步';

  @override
  String get errorSharedFoldersChanged => '共享目录已更新，请稍后重试';

  @override
  String get errorTaskIdMissing => '下载任务缺少 ID';

  @override
  String get errorAddressOwnedByOther => '该地址已属于另一台设备，请重新发现后重试';

  @override
  String errorSpaceInsufficient(String location) {
    return '$location空间不足，请释放空间后重试';
  }

  @override
  String get errorChunkSize => '收到的文件分片大小有误，请刷新后重试';

  @override
  String get errorChunkIncomplete => '文件分片未传输完整，请重试继续下载';

  @override
  String get errorDownloadSizeMismatch => '下载文件大小与目录记录不符，请刷新后重试';

  @override
  String get errorDatabaseDirectory => '本机数据库目录不可用，请检查用户目录权限后重试';

  @override
  String get errorTransferTarget => '媒体所属设备或共享目录无效，请刷新相册';

  @override
  String get errorStagingNotCleaned => '暂存文件尚未清理，请先重试删除任务';

  @override
  String get errorStagingCleanupFailed => '暂存清理失败，请重试删除任务';

  @override
  String get errorFileDeletedRedownload => '文件已删除，请重新下载';

  @override
  String get errorTaskInterrupted => '任务已中断，点重试继续下载';

  @override
  String get errorCatalogVersion => '无效的媒体目录版本';

  @override
  String get errorCatalogCursor => '无效的媒体目录分页断点';

  @override
  String get errorCatalogInvalidEntries => '对端媒体目录包含无效或重复的文件';

  @override
  String get errorCatalogInvalidEntriesRefresh => '对端媒体目录包含无效或重复的文件，请刷新后重试';

  @override
  String get errorCatalogDuplicate => '对端媒体目录包含重复文件，请重试';

  @override
  String get errorCatalogCount => '对端媒体目录数量不一致，请重试';

  @override
  String get errorCatalogIncomplete => '媒体目录尚未接收完整，原有离线相册保持不变';

  @override
  String get errorThumbnailTooLarge => '缩略图超过允许大小';

  @override
  String get errorIncompatiblePeer => '对端不是兼容的 Tamayura 设备，请确认两端应用版本一致';

  @override
  String get errorPeerPaging => '对端目录分页信息无效，请刷新后重试';

  @override
  String get errorPeerCatalogInvalid => '对端返回的媒体目录无效，请刷新后重试';

  @override
  String get errorPeerThumbnail => '对端缩略图无效，请刷新后重试';

  @override
  String get errorPeerCatalogCount => '对端目录数量不一致，请重试';

  @override
  String get errorPeerCatalogVersion => '对端目录版本发生变化，请重试';

  @override
  String get errorPeerCatalogPageRepeated => '对端目录分页重复，请重试';

  @override
  String get errorChunkInvalid => '收到的文件分片有误，请重新下载';

  @override
  String get errorTransferEnded => '文件传输提前结束，请重新下载';

  @override
  String get errorSharingStatus => '无法读取后台共享状态，请重试';

  @override
  String get errorStagingUnavailable => '下载暂存目录不可用';

  @override
  String get errorSaveFailed => '未能保存文件';

  @override
  String get errorCacheUnavailable => '临时目录不可用';

  @override
  String errorDeviceId(String platform) {
    return '无法读取 $platform 设备标识，请重启应用后重试';
  }

  @override
  String errorPlatformUnsupported(String platform) {
    return '尚未支持 $platform 平台';
  }

  @override
  String get updateErrorCancelled => '已取消更新下载';

  @override
  String get updateErrorCurrentVersion => '无法识别当前应用版本，请重新安装正式发布的安装包';

  @override
  String get updateErrorReleaseList => 'GitHub 版本列表格式不正确，请稍后重试';

  @override
  String get updateErrorPageUrl => '更新页面地址无效，请稍后重试';

  @override
  String get updateErrorNotes => '更新说明格式不正确，请稍后重试';

  @override
  String get updateErrorListTooLong => '版本列表过长，暂时无法确认最新版本，请前往 GitHub 查看';

  @override
  String get updateErrorManifest => '新版本的更新清单无效，暂时无法自动更新';

  @override
  String get updateErrorManifestMismatch => '新版本的更新清单与发布版本不一致';

  @override
  String get updateErrorAndroidBuild => '新版本的 Android 构建号无效，暂时无法覆盖安装';

  @override
  String get updateErrorPackageInfo => '新版本缺少有效的对应平台安装包信息';

  @override
  String get updateErrorArchitecture => '新版本的安装包架构不受支持';

  @override
  String get updateErrorPackageSize => '新版本的安装包大小与更新清单不一致';

  @override
  String get updateErrorInvalidPackage => '安装包信息无效，请重新检查更新';

  @override
  String get updateErrorDownloadSize => '安装包下载大小与更新清单不一致，请重试';

  @override
  String get updateErrorDownloadTooLarge => '安装包下载大小超出更新清单，请重试';

  @override
  String get updateErrorChecksum => '安装包完整性校验失败，请重新下载';

  @override
  String get updateErrorBusy => '已有更新操作正在进行，请稍候';

  @override
  String get updateErrorTimeout => '连接 GitHub 或下载安装包超时，请检查网络后重试';

  @override
  String get updateErrorConnect => '无法连接 GitHub，请检查网络后重试';

  @override
  String get updateErrorConnectionLost => 'GitHub 连接中断，请稍后重试';

  @override
  String get updateErrorStorage => '无法保存更新安装包，请检查可用空间和目录权限后重试';

  @override
  String get updateErrorFormat => '更新信息格式不正确，请稍后重试';

  @override
  String get updateErrorResponseTooLarge => '更新信息超过允许大小，请稍后重试';

  @override
  String get updateErrorRedirect => 'GitHub 下载地址重定向异常，请稍后重试';

  @override
  String get updateErrorForbidden => 'GitHub 拒绝访问或请求过于频繁，请稍后重试';

  @override
  String get updateErrorUnavailable => 'GitHub 更新信息或安装包暂时不可用，请稍后重试';

  @override
  String get updateErrorEncoding => 'GitHub 返回了不支持的下载编码，请稍后重试';

  @override
  String get updateErrorUntrustedUrl => '更新下载地址不受信任，已停止更新';

  @override
  String get updateErrorNoAssets => '新版本缺少发布附件，暂时无法自动更新';

  @override
  String get updateErrorAmbiguousAssets => '新版本缺少唯一且完整的发布附件，暂时无法自动更新';

  @override
  String get updateErrorAssetsPending => '新版本的发布附件尚未上传完成，请稍后重试';

  @override
  String get updateErrorAssetUrl => '更新附件地址与发布版本不一致';

  @override
  String get updateErrorPlatform => '当前平台尚不支持应用更新';

  @override
  String get updateErrorStagingDirectory => '无法创建更新暂存目录，请检查磁盘空间后重试';

  @override
  String get updateErrorInstallInfo => '此版本缺少有效的安装信息';

  @override
  String get updateErrorInstallStart => '无法确认安装是否已启动，请重试';

  @override
  String get updateErrorReleaseUrl => '更新页面地址无效';
}
