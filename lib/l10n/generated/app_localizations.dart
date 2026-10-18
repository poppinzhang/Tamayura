import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
  ];

  /// Window/task title and the project name on the About page.
  ///
  /// In zh, this message translates to:
  /// **'Tamayura · 玉响'**
  String get appTitle;

  /// Local-language name shown after the Latin brand in the app bar. Empty hides it.
  ///
  /// In zh, this message translates to:
  /// **'玉响'**
  String get appLocalName;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存…'**
  String get commonSaving;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @commonDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get commonConfirm;

  /// No description provided for @commonConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get commonConnect;

  /// No description provided for @commonShare.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get commonShare;

  /// No description provided for @commonOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get commonOnline;

  /// No description provided for @commonOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get commonOffline;

  /// No description provided for @commonVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get commonVideo;

  /// No description provided for @commonImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get commonImage;

  /// No description provided for @navAlbum.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get navAlbum;

  /// No description provided for @navDevices.
  ///
  /// In zh, this message translates to:
  /// **'设备'**
  String get navDevices;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @homeDownloadsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'下载任务'**
  String get homeDownloadsTooltip;

  /// No description provided for @homeRefreshTooltip.
  ///
  /// In zh, this message translates to:
  /// **'刷新设备和相册'**
  String get homeRefreshTooltip;

  /// No description provided for @homeOpening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开你的随身相册…'**
  String get homeOpening;

  /// No description provided for @homeActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作未能完成，请检查网络与目录权限后重试。'**
  String get homeActionFailed;

  /// No description provided for @homeErrorRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试连接与刷新'**
  String get homeErrorRetry;

  /// No description provided for @homeErrorDismiss.
  ///
  /// In zh, this message translates to:
  /// **'关闭提示'**
  String get homeErrorDismiss;

  /// No description provided for @albumHeadline.
  ///
  /// In zh, this message translates to:
  /// **'每一刻，都在手边。'**
  String get albumHeadline;

  /// No description provided for @albumSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'按共享文件夹浏览合集，轻点照片就存到这里。'**
  String get albumSubtitle;

  /// No description provided for @albumAllDevices.
  ///
  /// In zh, this message translates to:
  /// **'全部设备'**
  String get albumAllDevices;

  /// No description provided for @albumAllCollections.
  ///
  /// In zh, this message translates to:
  /// **'全部合集'**
  String get albumAllCollections;

  /// No description provided for @albumSharedCollectionFallback.
  ///
  /// In zh, this message translates to:
  /// **'共享合集'**
  String get albumSharedCollectionFallback;

  /// No description provided for @albumDeleteLocalFiles.
  ///
  /// In zh, this message translates to:
  /// **'删除本地文件'**
  String get albumDeleteLocalFiles;

  /// No description provided for @albumCollectionCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个合集'**
  String albumCollectionCount(int count);

  /// Number of photos and videos.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个瞬间'**
  String albumMomentCount(int count);

  /// No description provided for @albumSelectSavedHint.
  ///
  /// In zh, this message translates to:
  /// **'选择已保存的图片或视频'**
  String get albumSelectSavedHint;

  /// No description provided for @albumTapToDownloadHint.
  ///
  /// In zh, this message translates to:
  /// **'轻点下载原文件'**
  String get albumTapToDownloadHint;

  /// No description provided for @albumReceivingTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在接收相册'**
  String get albumReceivingTitle;

  /// No description provided for @albumReceivingDescription.
  ///
  /// In zh, this message translates to:
  /// **'缩略图会陆续显示，你可以边同步边浏览。'**
  String get albumReceivingDescription;

  /// No description provided for @albumSyncIncompleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步尚未完成'**
  String get albumSyncIncompleteTitle;

  /// No description provided for @albumSyncIncompleteDescription.
  ///
  /// In zh, this message translates to:
  /// **'请检查两台设备的连接，然后重试同步。'**
  String get albumSyncIncompleteDescription;

  /// No description provided for @albumNoDevicesTitle.
  ///
  /// In zh, this message translates to:
  /// **'让照片相遇'**
  String get albumNoDevicesTitle;

  /// No description provided for @albumNoDevicesDescription.
  ///
  /// In zh, this message translates to:
  /// **'在另一台设备上打开玉响，连接同一个局域网。\n发现设备后，共享文件夹会以合集出现在这里。'**
  String get albumNoDevicesDescription;

  /// No description provided for @albumEmptyCollectionTitle.
  ///
  /// In zh, this message translates to:
  /// **'这个合集还没有照片'**
  String get albumEmptyCollectionTitle;

  /// No description provided for @albumNoCollectionsTitle.
  ///
  /// In zh, this message translates to:
  /// **'这里还没有合集'**
  String get albumNoCollectionsTitle;

  /// No description provided for @albumNoMediaDesktopDescription.
  ///
  /// In zh, this message translates to:
  /// **'对方需要选择共享目录，并保持玉响运行。\n点击右上角刷新，更新已连接设备的相册。'**
  String get albumNoMediaDesktopDescription;

  /// No description provided for @albumNoMediaMobileDescription.
  ///
  /// In zh, this message translates to:
  /// **'对方需要选择共享目录，开启后台共享后锁屏也能访问。\n点击右上角刷新，更新已连接设备的相册。'**
  String get albumNoMediaMobileDescription;

  /// No description provided for @albumConnectDevice.
  ///
  /// In zh, this message translates to:
  /// **'连接一台设备'**
  String get albumConnectDevice;

  /// No description provided for @albumLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'更多照片暂时未能加载，请重试。'**
  String get albumLoadMoreFailed;

  /// No description provided for @albumLoadingMore.
  ///
  /// In zh, this message translates to:
  /// **'正在加载更多照片…'**
  String get albumLoadingMore;

  /// No description provided for @albumLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多照片'**
  String get albumLoadMore;

  /// No description provided for @albumRetryLoad.
  ///
  /// In zh, this message translates to:
  /// **'重试加载'**
  String get albumRetryLoad;

  /// No description provided for @albumLoadingThumbnail.
  ///
  /// In zh, this message translates to:
  /// **'正在加载缩略图'**
  String get albumLoadingThumbnail;

  /// No description provided for @albumRetryThumbnail.
  ///
  /// In zh, this message translates to:
  /// **'重试加载缩略图'**
  String get albumRetryThumbnail;

  /// No description provided for @albumSortTooltip.
  ///
  /// In zh, this message translates to:
  /// **'按名称或文件修改日期排序'**
  String get albumSortTooltip;

  /// No description provided for @albumSorting.
  ///
  /// In zh, this message translates to:
  /// **'正在排序…'**
  String get albumSorting;

  /// No description provided for @albumSortLabel.
  ///
  /// In zh, this message translates to:
  /// **'排序：{order}'**
  String albumSortLabel(String order);

  /// No description provided for @albumSortNameAscending.
  ///
  /// In zh, this message translates to:
  /// **'名称升序'**
  String get albumSortNameAscending;

  /// No description provided for @albumSortNameDescending.
  ///
  /// In zh, this message translates to:
  /// **'名称降序'**
  String get albumSortNameDescending;

  /// No description provided for @albumSortDateAscending.
  ///
  /// In zh, this message translates to:
  /// **'日期升序'**
  String get albumSortDateAscending;

  /// No description provided for @albumSortDateDescending.
  ///
  /// In zh, this message translates to:
  /// **'日期降序'**
  String get albumSortDateDescending;

  /// No description provided for @albumSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {count} 项'**
  String albumSelectedCount(int count);

  /// No description provided for @albumDeleting.
  ///
  /// In zh, this message translates to:
  /// **'正在删除…'**
  String get albumDeleting;

  /// No description provided for @albumLocalDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {count} 个本地文件，可轻点缩略图重新下载。'**
  String albumLocalDeleted(int count);

  /// No description provided for @albumLocalDeletePartial.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {deleted} 个本地文件，{failed} 个未能删除，请检查目录权限后重试。'**
  String albumLocalDeletePartial(int deleted, int failed);

  /// Fast-scroll section label for a month.
  ///
  /// In zh, this message translates to:
  /// **'{date}'**
  String albumMonthLabel(DateTime date);

  /// Fast-scroll date with weekday.
  ///
  /// In zh, this message translates to:
  /// **'{date}'**
  String albumDateLabel(DateTime date);

  /// No description provided for @albumFastScrollLabel.
  ///
  /// In zh, this message translates to:
  /// **'快速滚动相册，{label}'**
  String albumFastScrollLabel(String label);

  /// Name for a source device whose record is unavailable.
  ///
  /// In zh, this message translates to:
  /// **'已记住的设备'**
  String get rememberedDeviceFallback;

  /// No description provided for @setupTitle.
  ///
  /// In zh, this message translates to:
  /// **'先安顿好你的相册'**
  String get setupTitle;

  /// No description provided for @setupDescription.
  ///
  /// In zh, this message translates to:
  /// **'添加要分享的文件夹，以及收到照片后存放的位置。'**
  String get setupDescription;

  /// No description provided for @setupShareFolder.
  ///
  /// In zh, this message translates to:
  /// **'共享文件夹'**
  String get setupShareFolder;

  /// No description provided for @setupDownloadFolder.
  ///
  /// In zh, this message translates to:
  /// **'接收目录'**
  String get setupDownloadFolder;

  /// No description provided for @collectionSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{folder}，来自{device}，{count} 个瞬间'**
  String collectionSemantics(String folder, String device, int count);

  /// No description provided for @mediaSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}，来自{device}，{state}'**
  String mediaSemantics(String name, String device, String state);

  /// No description provided for @mediaStateSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get mediaStateSaved;

  /// No description provided for @mediaStateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载'**
  String get mediaStateDownloading;

  /// No description provided for @mediaStateFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败，点击重试'**
  String get mediaStateFailed;

  /// No description provided for @mediaStateTapToDownload.
  ///
  /// In zh, this message translates to:
  /// **'点击下载原文件'**
  String get mediaStateTapToDownload;

  /// No description provided for @mediaStateOffline.
  ///
  /// In zh, this message translates to:
  /// **'设备离线，点击查看详情'**
  String get mediaStateOffline;

  /// No description provided for @mediaDeviceOffline.
  ///
  /// In zh, this message translates to:
  /// **'设备离线'**
  String get mediaDeviceOffline;

  /// No description provided for @mediaDownloadingName.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {name}'**
  String mediaDownloadingName(String name);

  /// No description provided for @mediaSelectName.
  ///
  /// In zh, this message translates to:
  /// **'选择 {name}'**
  String mediaSelectName(String name);

  /// No description provided for @mediaNotSavedName.
  ///
  /// In zh, this message translates to:
  /// **'{name} 尚未保存'**
  String mediaNotSavedName(String name);

  /// No description provided for @mediaDeleteLocalOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅删除本地文件'**
  String get mediaDeleteLocalOnly;

  /// No description provided for @mediaNotSaved.
  ///
  /// In zh, this message translates to:
  /// **'尚未保存'**
  String get mediaNotSaved;

  /// No description provided for @mediaDownloadFailedRetry.
  ///
  /// In zh, this message translates to:
  /// **'下载失败 · 重试'**
  String get mediaDownloadFailedRetry;

  /// No description provided for @mediaReceivingOriginal.
  ///
  /// In zh, this message translates to:
  /// **'正在接收原文件…'**
  String get mediaReceivingOriginal;

  /// Modified date on a detailed album card.
  ///
  /// In zh, this message translates to:
  /// **'{date}'**
  String mediaCardDate(DateTime date);

  /// No description provided for @devicesTitle.
  ///
  /// In zh, this message translates to:
  /// **'附近的伙伴'**
  String get devicesTitle;

  /// No description provided for @devicesSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'同一个局域网，让每台设备的相册连在一起。'**
  String get devicesSubtitle;

  /// No description provided for @devicesThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'这台设备'**
  String get devicesThisDevice;

  /// No description provided for @devicesNoAddress.
  ///
  /// In zh, this message translates to:
  /// **'暂无局域网地址，请连接网络后刷新'**
  String get devicesNoAddress;

  /// No description provided for @devicesShowQr.
  ///
  /// In zh, this message translates to:
  /// **'展示连接二维码'**
  String get devicesShowQr;

  /// No description provided for @devicesConnectByIp.
  ///
  /// In zh, this message translates to:
  /// **'输入 IP 连接'**
  String get devicesConnectByIp;

  /// No description provided for @devicesScan.
  ///
  /// In zh, this message translates to:
  /// **'扫一扫'**
  String get devicesScan;

  /// No description provided for @devicesConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接设备…'**
  String get devicesConnecting;

  /// No description provided for @devicesRemembered.
  ///
  /// In zh, this message translates to:
  /// **'已记住的设备'**
  String get devicesRemembered;

  /// No description provided for @devicesOnlineCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 台在线'**
  String devicesOnlineCount(int count);

  /// No description provided for @devicesReorder.
  ///
  /// In zh, this message translates to:
  /// **'调整顺序'**
  String get devicesReorder;

  /// No description provided for @devicesEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'等待另一台玉响'**
  String get devicesEmptyTitle;

  /// No description provided for @devicesEmptyDescription.
  ///
  /// In zh, this message translates to:
  /// **'设备会通过局域网自动发现。\n如果暂时没找到，可以输入 IP 或扫描二维码连接。'**
  String get devicesEmptyDescription;

  /// No description provided for @devicesFooterWindows.
  ///
  /// In zh, this message translates to:
  /// **'设备离线后仍会保留相册缩略图。共享与接收需要玉响运行、电脑保持唤醒，并与来源设备处于同一局域网。'**
  String get devicesFooterWindows;

  /// No description provided for @devicesFooterMac.
  ///
  /// In zh, this message translates to:
  /// **'设备离线后仍会保留相册缩略图。共享与接收需要玉响保持运行、Mac 保持唤醒，并与来源设备处于同一局域网。'**
  String get devicesFooterMac;

  /// No description provided for @devicesFooterMobile.
  ///
  /// In zh, this message translates to:
  /// **'设备离线后仍会保留相册缩略图。来源设备开启后台共享后，锁屏也能提供原文件；这台设备可以切换到其他应用继续接收。'**
  String get devicesFooterMobile;

  /// No description provided for @deviceLastSuccessfulSync.
  ///
  /// In zh, this message translates to:
  /// **'最后成功同步：{time}'**
  String deviceLastSuccessfulSync(String time);

  /// No description provided for @deviceNeverSynced.
  ///
  /// In zh, this message translates to:
  /// **'尚未成功同步'**
  String get deviceNeverSynced;

  /// No description provided for @devicePendingApproval.
  ///
  /// In zh, this message translates to:
  /// **'新发现的设备 · 尚未开启相册同步'**
  String get devicePendingApproval;

  /// No description provided for @deviceSyncDeclined.
  ///
  /// In zh, this message translates to:
  /// **'未开启相册同步'**
  String get deviceSyncDeclined;

  /// No description provided for @deviceOfflineCached.
  ///
  /// In zh, this message translates to:
  /// **'离线 · 可浏览缓存'**
  String get deviceOfflineCached;

  /// No description provided for @deviceActions.
  ///
  /// In zh, this message translates to:
  /// **'设备操作'**
  String get deviceActions;

  /// No description provided for @deviceEnableAlbumSync.
  ///
  /// In zh, this message translates to:
  /// **'开启相册同步'**
  String get deviceEnableAlbumSync;

  /// No description provided for @deviceForget.
  ///
  /// In zh, this message translates to:
  /// **'忘记设备'**
  String get deviceForget;

  /// No description provided for @deviceStartSync.
  ///
  /// In zh, this message translates to:
  /// **'开启同步'**
  String get deviceStartSync;

  /// No description provided for @deviceForgotten.
  ///
  /// In zh, this message translates to:
  /// **'已忘记「{name}」，再次发现时会作为新设备询问是否同步。'**
  String deviceForgotten(String name);

  /// No description provided for @deviceForgetFailed.
  ///
  /// In zh, this message translates to:
  /// **'未能忘记这台设备，请稍后重试。'**
  String get deviceForgetFailed;

  /// No description provided for @deviceForgetTitle.
  ///
  /// In zh, this message translates to:
  /// **'忘记「{name}」？'**
  String deviceForgetTitle(String name);

  /// No description provided for @deviceForgetMessage.
  ///
  /// In zh, this message translates to:
  /// **'将从设备列表移除这台设备，并删除它的离线相册信息、缩略图和未完成的同步进度。\n\n已下载到本机的文件和下载任务不受影响，对端的原文件也不会被删除。再次在局域网中发现它时，会作为新设备询问是否同步。'**
  String get deviceForgetMessage;

  /// No description provided for @syncApprovalTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现新设备'**
  String get syncApprovalTitle;

  /// Quotes the decline button and the Devices tab.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」（{address}）出现在局域网中。是否同步它共享的相册？\n\n同步只获取文件信息和缩略图，原文件仍在点开时下载。选择「暂不同步」后，可以随时在「设备」页面开启。'**
  String syncApprovalMessage(String name, String address);

  /// No description provided for @syncApprovalDecline.
  ///
  /// In zh, this message translates to:
  /// **'暂不同步'**
  String get syncApprovalDecline;

  /// No description provided for @syncApprovalAccept.
  ///
  /// In zh, this message translates to:
  /// **'开始同步'**
  String get syncApprovalAccept;

  /// No description provided for @connectDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接另一台设备'**
  String get connectDialogTitle;

  /// No description provided for @connectDialogHint.
  ///
  /// In zh, this message translates to:
  /// **'在对方的「设备」页面找到 IP 地址。'**
  String get connectDialogHint;

  /// No description provided for @connectDialogLabel.
  ///
  /// In zh, this message translates to:
  /// **'IP 地址与端口'**
  String get connectDialogLabel;

  /// No description provided for @connectDialogEmpty.
  ///
  /// In zh, this message translates to:
  /// **'请输入对方的 IP 地址'**
  String get connectDialogEmpty;

  /// No description provided for @qrDialogHint.
  ///
  /// In zh, this message translates to:
  /// **'另一台设备打开玉响扫一扫'**
  String get qrDialogHint;

  /// No description provided for @qrSemantics.
  ///
  /// In zh, this message translates to:
  /// **'本机连接二维码，地址 {address}，端口 {port}'**
  String qrSemantics(String address, int port);

  /// No description provided for @scannerTitle.
  ///
  /// In zh, this message translates to:
  /// **'扫描设备二维码'**
  String get scannerTitle;

  /// No description provided for @scannerInvalidCode.
  ///
  /// In zh, this message translates to:
  /// **'这不是玉响的设备二维码，请扫描对方「设备」页面的二维码。'**
  String get scannerInvalidCode;

  /// No description provided for @scannerCameraUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法打开相机。请在系统设置中允许相机权限，或返回后输入 IP 连接。'**
  String get scannerCameraUnavailable;

  /// No description provided for @scannerBack.
  ///
  /// In zh, this message translates to:
  /// **'返回设备页面'**
  String get scannerBack;

  /// No description provided for @scannerHint.
  ///
  /// In zh, this message translates to:
  /// **'将对方的设备二维码放入镜头中\n双方需要连接同一个局域网'**
  String get scannerHint;

  /// No description provided for @syncPhaseConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接'**
  String get syncPhaseConnecting;

  /// No description provided for @syncPhaseReceiving.
  ///
  /// In zh, this message translates to:
  /// **'正在同步相册'**
  String get syncPhaseReceiving;

  /// No description provided for @syncPhaseCommitting.
  ///
  /// In zh, this message translates to:
  /// **'正在完成同步'**
  String get syncPhaseCommitting;

  /// No description provided for @syncPhaseCompleted.
  ///
  /// In zh, this message translates to:
  /// **'相册同步完成'**
  String get syncPhaseCompleted;

  /// No description provided for @syncPhaseFailed.
  ///
  /// In zh, this message translates to:
  /// **'本次同步未完成'**
  String get syncPhaseFailed;

  /// No description provided for @syncConnectingResume.
  ///
  /// In zh, this message translates to:
  /// **'已保留 {count} 项，正在连接设备继续同步。'**
  String syncConnectingResume(int count);

  /// No description provided for @syncConnectingFresh.
  ///
  /// In zh, this message translates to:
  /// **'正在获取相册信息，请保持设备连接。'**
  String get syncConnectingFresh;

  /// No description provided for @syncReceivingOpen.
  ///
  /// In zh, this message translates to:
  /// **'已就绪 {count} 项，正在获取更多照片。'**
  String syncReceivingOpen(int count);

  /// No description provided for @syncReceivingProgress.
  ///
  /// In zh, this message translates to:
  /// **'已就绪 {ready} / {total} 项，可边同步边浏览。'**
  String syncReceivingProgress(int ready, int total);

  /// No description provided for @syncCommittingDetail.
  ///
  /// In zh, this message translates to:
  /// **'缩略图已就绪，正在整理相册。'**
  String get syncCommittingDetail;

  /// No description provided for @syncCompletedDetail.
  ///
  /// In zh, this message translates to:
  /// **'已就绪 {count} 项。'**
  String syncCompletedDetail(int count);

  /// No description provided for @syncFailedResume.
  ///
  /// In zh, this message translates to:
  /// **'已保留 {count} 项，恢复连接后可继续同步。'**
  String syncFailedResume(int count);

  /// No description provided for @syncFailedFresh.
  ///
  /// In zh, this message translates to:
  /// **'相册和同步进度已保留，请检查连接后重试。'**
  String get syncFailedFresh;

  /// No description provided for @syncDismiss.
  ///
  /// In zh, this message translates to:
  /// **'关闭同步提示'**
  String get syncDismiss;

  /// No description provided for @syncProgressSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{device}，{status}，{detail}'**
  String syncProgressSemantics(String device, String status, String detail);

  /// No description provided for @syncContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续同步'**
  String get syncContinue;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'你的相册，你来安排'**
  String get settingsTitle;

  /// No description provided for @settingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'只分享选定的目录，原文件按需获取。'**
  String get settingsSubtitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsAppearance;

  /// No description provided for @settingsThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题模式'**
  String get settingsThemeMode;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存主题…'**
  String get settingsThemeSaving;

  /// No description provided for @settingsThemeSystemDescription.
  ///
  /// In zh, this message translates to:
  /// **'随系统自动切换浅色和深色外观。'**
  String get settingsThemeSystemDescription;

  /// No description provided for @settingsThemeLightDescription.
  ///
  /// In zh, this message translates to:
  /// **'已固定为浅色外观。'**
  String get settingsThemeLightDescription;

  /// No description provided for @settingsThemeDarkDescription.
  ///
  /// In zh, this message translates to:
  /// **'已固定为深色外观。'**
  String get settingsThemeDarkDescription;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsLanguageSystem;

  /// No description provided for @settingsLanguageSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存语言…'**
  String get settingsLanguageSaving;

  /// The placeholder is the language's own name, such as 日本語.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统语言，当前显示{language}。系统语言不是中文或日文时显示英文。'**
  String settingsLanguageSystemDescription(String language);

  /// No description provided for @settingsLanguageFixedDescription.
  ///
  /// In zh, this message translates to:
  /// **'已固定为{language}，不随系统语言切换。'**
  String settingsLanguageFixedDescription(String language);

  /// No description provided for @settingsAlbum.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get settingsAlbum;

  /// No description provided for @settingsDetailedMode.
  ///
  /// In zh, this message translates to:
  /// **'详细模式'**
  String get settingsDetailedMode;

  /// No description provided for @settingsDetailedModeSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存显示模式…'**
  String get settingsDetailedModeSaving;

  /// No description provided for @settingsDetailedModeDescription.
  ///
  /// In zh, this message translates to:
  /// **'默认模式使用紧凑的正方形网格，点击照片查看详细信息。\n开启详细模式后，照片卡片会显示文件名、来源设备、日期和下载状态。'**
  String get settingsDetailedModeDescription;

  /// No description provided for @settingsSync.
  ///
  /// In zh, this message translates to:
  /// **'同步'**
  String get settingsSync;

  /// No description provided for @settingsAutoSyncInterval.
  ///
  /// In zh, this message translates to:
  /// **'自动同步间隔'**
  String get settingsAutoSyncInterval;

  /// No description provided for @settingsAutoSyncSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存同步间隔…'**
  String get settingsAutoSyncSaving;

  /// No description provided for @settingsAutoSyncDescription.
  ///
  /// In zh, this message translates to:
  /// **'上次同步尝试超过 {minutes} 分钟后自动同步。\n手动同步和同步失败都会重新计时。点击右上角刷新可立即同步。'**
  String settingsAutoSyncDescription(int minutes);

  /// No description provided for @settingsFilesStorage.
  ///
  /// In zh, this message translates to:
  /// **'文件与存储'**
  String get settingsFilesStorage;

  /// No description provided for @settingsSharedFolders.
  ///
  /// In zh, this message translates to:
  /// **'共享文件夹'**
  String get settingsSharedFolders;

  /// No description provided for @settingsSharedFoldersDescription.
  ///
  /// In zh, this message translates to:
  /// **'可添加多个文件夹，自动包含所有子目录。已添加的目录及其父目录、子目录不能重复添加。'**
  String get settingsSharedFoldersDescription;

  /// No description provided for @settingsSharedFoldersEmpty.
  ///
  /// In zh, this message translates to:
  /// **'尚未选择 · 让其他设备看到这里的照片'**
  String get settingsSharedFoldersEmpty;

  /// No description provided for @settingsRemoveSharedFolder.
  ///
  /// In zh, this message translates to:
  /// **'移除 {name}'**
  String settingsRemoveSharedFolder(String name);

  /// No description provided for @settingsAddSharedFolder.
  ///
  /// In zh, this message translates to:
  /// **'添加共享文件夹'**
  String get settingsAddSharedFolder;

  /// No description provided for @settingsBackgroundSharing.
  ///
  /// In zh, this message translates to:
  /// **'后台共享'**
  String get settingsBackgroundSharing;

  /// No description provided for @settingsBackgroundSharingWindows.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后玉响会留在系统托盘。开启此项后，关闭或最小化窗口仍可共享；关闭此项后在窗口隐藏时停止共享。电脑需要保持唤醒。'**
  String get settingsBackgroundSharingWindows;

  /// No description provided for @settingsBackgroundSharingMac.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后玉响会留在菜单栏。开启此项后，关闭、隐藏或最小化窗口仍可共享；关闭此项后在窗口隐藏时停止共享。Mac 需要保持唤醒。'**
  String get settingsBackgroundSharingMac;

  /// No description provided for @settingsBackgroundSharingMobile.
  ///
  /// In zh, this message translates to:
  /// **'开启后锁屏仍可共享媒体；关闭后仅在使用应用时共享，更省电。'**
  String get settingsBackgroundSharingMobile;

  /// No description provided for @backgroundSharingStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动后台共享…'**
  String get backgroundSharingStarting;

  /// No description provided for @backgroundSharingUpdating.
  ///
  /// In zh, this message translates to:
  /// **'正在更新后台共享…'**
  String get backgroundSharingUpdating;

  /// No description provided for @backgroundSharingStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'后台共享启动失败，请重试。'**
  String get backgroundSharingStartFailed;

  /// No description provided for @backgroundSharingOff.
  ///
  /// In zh, this message translates to:
  /// **'后台共享已关闭。'**
  String get backgroundSharingOff;

  /// No description provided for @backgroundSharingRunningWindows.
  ///
  /// In zh, this message translates to:
  /// **'后台共享正在运行。电脑睡眠或退出玉响后，共享会停止。'**
  String get backgroundSharingRunningWindows;

  /// No description provided for @backgroundSharingRunningMac.
  ///
  /// In zh, this message translates to:
  /// **'后台共享正在运行。Mac 睡眠或退出玉响后，共享会停止。'**
  String get backgroundSharingRunningMac;

  /// No description provided for @backgroundSharingRunningMobile.
  ///
  /// In zh, this message translates to:
  /// **'后台共享正在运行，锁屏后仍可访问已选目录。'**
  String get backgroundSharingRunningMobile;

  /// No description provided for @backgroundSharingNotRunning.
  ///
  /// In zh, this message translates to:
  /// **'后台共享尚未运行。'**
  String get backgroundSharingNotRunning;

  /// No description provided for @backgroundSharingRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试后台共享'**
  String get backgroundSharingRetry;

  /// No description provided for @backgroundSharingBatteryHint.
  ///
  /// In zh, this message translates to:
  /// **'系统省电限制可能在休眠时中断共享。可在电池设置中允许玉响不受限制地运行。'**
  String get backgroundSharingBatteryHint;

  /// No description provided for @backgroundSharingBatterySettings.
  ///
  /// In zh, this message translates to:
  /// **'电池设置'**
  String get backgroundSharingBatterySettings;

  /// No description provided for @settingsDownloadFolder.
  ///
  /// In zh, this message translates to:
  /// **'接收目录'**
  String get settingsDownloadFolder;

  /// No description provided for @settingsDownloadFolderEmpty.
  ///
  /// In zh, this message translates to:
  /// **'尚未选择 · 下载的原文件会保存在这里'**
  String get settingsDownloadFolderEmpty;

  /// No description provided for @settingsSharingSummary.
  ///
  /// In zh, this message translates to:
  /// **'当前从 {folders} 个目录共享 {count} 个媒体文件'**
  String settingsSharingSummary(int folders, int count);

  /// No description provided for @settingsDownloadLayout.
  ///
  /// In zh, this message translates to:
  /// **'原文件按「对端设备 / 共享文件夹 / 原有子目录」保存，保留目录层级。'**
  String get settingsDownloadLayout;

  /// No description provided for @settingsDeviceInfo.
  ///
  /// In zh, this message translates to:
  /// **'本机信息'**
  String get settingsDeviceInfo;

  /// No description provided for @settingsNoLan.
  ///
  /// In zh, this message translates to:
  /// **'尚未连接局域网'**
  String get settingsNoLan;

  /// No description provided for @settingsTips.
  ///
  /// In zh, this message translates to:
  /// **'使用小提示'**
  String get settingsTips;

  /// No description provided for @tipNetworkTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接同一个网络'**
  String get tipNetworkTitle;

  /// No description provided for @tipNetworkDescription.
  ///
  /// In zh, this message translates to:
  /// **'目前仅支持局域网，设备无需登录账号。请只在可信的网络中共享目录。'**
  String get tipNetworkDescription;

  /// No description provided for @tipWindowsTitle.
  ///
  /// In zh, this message translates to:
  /// **'为 Windows 准备'**
  String get tipWindowsTitle;

  /// No description provided for @tipWindowsDescription.
  ///
  /// In zh, this message translates to:
  /// **'支持 Windows 10 1809 及更新版本、Windows 11（x64）。请允许玉响通过专用网络防火墙；也可使用手动 IP 连接。'**
  String get tipWindowsDescription;

  /// No description provided for @tipBackgroundReceiveTitle.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口，接收继续'**
  String get tipBackgroundReceiveTitle;

  /// Quotes the Windows tray menu item that exits the app.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后，已开始的下载继续。点击系统托盘中的玉响图标可重新打开，右键菜单可选择「退出玉响」。电脑睡眠或断网后可在下载任务中重试。'**
  String get tipBackgroundReceiveWindows;

  /// Quotes the macOS menu bar item that quits the app.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后，已开始的下载继续。从右上角菜单栏或 Dock 可重新打开；选择「退出玉响」或按 ⌘Q 才会退出。Mac 睡眠或断网后可在下载任务中重试。'**
  String get tipBackgroundReceiveMac;

  /// No description provided for @tipKeyboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'用键盘快速切换'**
  String get tipKeyboardTitle;

  /// No description provided for @tipKeyboardWindows.
  ///
  /// In zh, this message translates to:
  /// **'Ctrl+1 相册 · Ctrl+2 设备 · Ctrl+3 或 Ctrl+, 设置 · Ctrl+R 刷新。'**
  String get tipKeyboardWindows;

  /// No description provided for @tipKeyboardMac.
  ///
  /// In zh, this message translates to:
  /// **'⌘1 相册 · ⌘2 设备 · ⌘3 或 ⌘, 设置 · ⌘R 刷新。'**
  String get tipKeyboardMac;

  /// No description provided for @tipMacTitle.
  ///
  /// In zh, this message translates to:
  /// **'为 Mac 准备'**
  String get tipMacTitle;

  /// No description provided for @tipMacDescription.
  ///
  /// In zh, this message translates to:
  /// **'支持 macOS Sequoia 15、Tahoe 26 及后续版本。目录访问和相机权限由系统管理，可在系统设置中调整。'**
  String get tipMacDescription;

  /// No description provided for @tipAndroidTitle.
  ///
  /// In zh, this message translates to:
  /// **'接收可在后台继续'**
  String get tipAndroidTitle;

  /// No description provided for @tipAndroidDescription.
  ///
  /// In zh, this message translates to:
  /// **'支持 Android 16 及更新版本。通知权限为可选项，关闭通知仍可下载并在下载中心查看进度；来源设备开启后台共享后可以锁屏，双方需要处于同一局域网。'**
  String get tipAndroidDescription;

  /// No description provided for @tipOpenTitle.
  ///
  /// In zh, this message translates to:
  /// **'轻点获取，下载后打开'**
  String get tipOpenTitle;

  /// No description provided for @tipOpenDescription.
  ///
  /// In zh, this message translates to:
  /// **'每个共享文件夹显示为独立合集；点击下载原文件，可用系统应用打开，或在资源管理器中定位文件。'**
  String get tipOpenDescription;

  /// No description provided for @tipShareTitle.
  ///
  /// In zh, this message translates to:
  /// **'轻点获取，下载后分享'**
  String get tipShareTitle;

  /// No description provided for @tipShareDescription.
  ///
  /// In zh, this message translates to:
  /// **'每个共享文件夹显示为独立合集，包含其所有子目录的照片与视频；点击下载原文件，再使用分享按钮发送到其他应用。'**
  String get tipShareDescription;

  /// No description provided for @settingsAboutProject.
  ///
  /// In zh, this message translates to:
  /// **'关于项目'**
  String get settingsAboutProject;

  /// No description provided for @settingsCheckUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settingsCheckUpdates;

  /// No description provided for @settingsCheckUpdatesSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'从 GitHub 检查新版本，由你确认后更新'**
  String get settingsCheckUpdatesSubtitle;

  /// No description provided for @settingsAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsAbout;

  /// No description provided for @settingsAboutSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'版本、开源许可与一点碎碎念'**
  String get settingsAboutSubtitle;

  /// No description provided for @autoSyncDialogDescription.
  ///
  /// In zh, this message translates to:
  /// **'从最近一次同步尝试开始计时，超过设定分钟数后尝试自动同步。手动同步和同步失败都会重新计时。'**
  String get autoSyncDialogDescription;

  /// No description provided for @autoSyncDialogLabel.
  ///
  /// In zh, this message translates to:
  /// **'间隔分钟数'**
  String get autoSyncDialogLabel;

  /// No description provided for @autoSyncDialogHelper.
  ///
  /// In zh, this message translates to:
  /// **'1–525600 分钟，默认 10 分钟'**
  String get autoSyncDialogHelper;

  /// No description provided for @autoSyncDialogInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1–525600 之间的整数分钟'**
  String get autoSyncDialogInvalid;

  /// No description provided for @autoSyncDialogSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'同步间隔未能保存，请重试。'**
  String get autoSyncDialogSaveFailed;

  /// No description provided for @deviceOrderTitle.
  ///
  /// In zh, this message translates to:
  /// **'调整设备顺序'**
  String get deviceOrderTitle;

  /// No description provided for @deviceOrderDescription.
  ///
  /// In zh, this message translates to:
  /// **'拖动手柄或使用箭头调整，相册中的设备也会按此顺序展示。'**
  String get deviceOrderDescription;

  /// No description provided for @deviceOrderDrag.
  ///
  /// In zh, this message translates to:
  /// **'拖动 {name}'**
  String deviceOrderDrag(String name);

  /// No description provided for @deviceOrderMoveUp.
  ///
  /// In zh, this message translates to:
  /// **'上移 {name}'**
  String deviceOrderMoveUp(String name);

  /// No description provided for @deviceOrderMoveDown.
  ///
  /// In zh, this message translates to:
  /// **'下移 {name}'**
  String deviceOrderMoveDown(String name);

  /// No description provided for @deviceOrderSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'设备顺序保存失败，请重试。'**
  String get deviceOrderSaveFailed;

  /// No description provided for @previewUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'原文件已保存，暂无法在应用内预览。可用其他应用打开。'**
  String get previewUnavailable;

  /// No description provided for @previewReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'原文件预览读取失败，可重试或用其他应用打开。'**
  String get previewReadFailed;

  /// No description provided for @previewActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作未完成，请检查网络或文件权限后重试。'**
  String get previewActionFailed;

  /// No description provided for @previewLocalDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除本地文件，可重新下载。'**
  String get previewLocalDeleted;

  /// No description provided for @previewLocalDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'本地文件未能删除，请检查目录权限后重试。'**
  String get previewLocalDeleteFailed;

  /// No description provided for @previewDetails.
  ///
  /// In zh, this message translates to:
  /// **'详细信息'**
  String get previewDetails;

  /// No description provided for @previewCloseDetails.
  ///
  /// In zh, this message translates to:
  /// **'关闭详细信息'**
  String get previewCloseDetails;

  /// No description provided for @detailFileName.
  ///
  /// In zh, this message translates to:
  /// **'文件名'**
  String get detailFileName;

  /// No description provided for @detailSourceDevice.
  ///
  /// In zh, this message translates to:
  /// **'来源设备'**
  String get detailSourceDevice;

  /// No description provided for @detailDeviceStatus.
  ///
  /// In zh, this message translates to:
  /// **'设备状态'**
  String get detailDeviceStatus;

  /// No description provided for @detailDeviceUnknown.
  ///
  /// In zh, this message translates to:
  /// **'设备记录不可用'**
  String get detailDeviceUnknown;

  /// No description provided for @detailModified.
  ///
  /// In zh, this message translates to:
  /// **'修改时间（本地）'**
  String get detailModified;

  /// No description provided for @detailType.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get detailType;

  /// No description provided for @detailSize.
  ///
  /// In zh, this message translates to:
  /// **'大小'**
  String get detailSize;

  /// No description provided for @detailSizeValue.
  ///
  /// In zh, this message translates to:
  /// **'{size}（{bytes} 字节）'**
  String detailSizeValue(String size, int bytes);

  /// No description provided for @detailCollection.
  ///
  /// In zh, this message translates to:
  /// **'合集'**
  String get detailCollection;

  /// No description provided for @detailRelativePath.
  ///
  /// In zh, this message translates to:
  /// **'相对路径'**
  String get detailRelativePath;

  /// No description provided for @previewImageError.
  ///
  /// In zh, this message translates to:
  /// **'无法显示这张预览图，可下载后用其他应用打开。'**
  String get previewImageError;

  /// No description provided for @previewBack.
  ///
  /// In zh, this message translates to:
  /// **'返回相册'**
  String get previewBack;

  /// No description provided for @previewDeleteLocal.
  ///
  /// In zh, this message translates to:
  /// **'删除本地文件'**
  String get previewDeleteLocal;

  /// No description provided for @previewZoomReset.
  ///
  /// In zh, this message translates to:
  /// **'还原缩放'**
  String get previewZoomReset;

  /// No description provided for @previewZoomIn.
  ///
  /// In zh, this message translates to:
  /// **'放大预览'**
  String get previewZoomIn;

  /// No description provided for @previewVideoHint.
  ///
  /// In zh, this message translates to:
  /// **'视频缩略图 · 下载后可用系统播放器打开'**
  String get previewVideoHint;

  /// No description provided for @previewReadingOriginal.
  ///
  /// In zh, this message translates to:
  /// **'正在读取本机原图…'**
  String get previewReadingOriginal;

  /// No description provided for @previewOriginalDesktop.
  ///
  /// In zh, this message translates to:
  /// **'本机原图 · 双击或滚轮缩放'**
  String get previewOriginalDesktop;

  /// No description provided for @previewOriginalMobile.
  ///
  /// In zh, this message translates to:
  /// **'本机原图 · 双指缩放'**
  String get previewOriginalMobile;

  /// No description provided for @previewCachedThumbnail.
  ///
  /// In zh, this message translates to:
  /// **'缓存缩略图 · 下载完成后显示原图'**
  String get previewCachedThumbnail;

  /// No description provided for @previewResetDesktop.
  ///
  /// In zh, this message translates to:
  /// **'双击还原'**
  String get previewResetDesktop;

  /// Shown on touch devices; double-tap restores the zoom.
  ///
  /// In zh, this message translates to:
  /// **'双击还原'**
  String get previewResetMobile;

  /// No description provided for @previewZoomDesktop.
  ///
  /// In zh, this message translates to:
  /// **'双击放大'**
  String get previewZoomDesktop;

  /// No description provided for @previewSwipeDown.
  ///
  /// In zh, this message translates to:
  /// **'下滑返回'**
  String get previewSwipeDown;

  /// No description provided for @previewSource.
  ///
  /// In zh, this message translates to:
  /// **'来自 {device}'**
  String previewSource(String device);

  /// No description provided for @previewRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新读取预览'**
  String get previewRetry;

  /// No description provided for @downloadsTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载任务'**
  String get downloadsTitle;

  /// No description provided for @downloadsEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'下一张心动的照片，在路上'**
  String get downloadsEmptyTitle;

  /// No description provided for @downloadsEmptyDescription.
  ///
  /// In zh, this message translates to:
  /// **'轻点相册中的照片或视频，即可在这里查看下载进度。'**
  String get downloadsEmptyDescription;

  /// No description provided for @downloadsBackToAlbum.
  ///
  /// In zh, this message translates to:
  /// **'返回相册'**
  String get downloadsBackToAlbum;

  /// No description provided for @downloadsAllDone.
  ///
  /// In zh, this message translates to:
  /// **'每一份，都有着落。'**
  String get downloadsAllDone;

  /// No description provided for @downloadsActive.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个任务正在进行'**
  String downloadsActive(int count);

  /// No description provided for @downloadsHintWindows.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后仍可继续接收，从系统托盘可重新打开。请保持电脑唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。'**
  String get downloadsHintWindows;

  /// No description provided for @downloadsHintMac.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口后仍可继续接收，从菜单栏或 Dock 可重新打开。请保持 Mac 唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。'**
  String get downloadsHintMac;

  /// No description provided for @downloadsHintMobile.
  ///
  /// In zh, this message translates to:
  /// **'接收可在后台继续。来源设备需要保持玉响运行，并与这台设备处于同一局域网。'**
  String get downloadsHintMobile;

  /// No description provided for @downloadsActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'任务操作未完成，请重试。'**
  String get downloadsActionFailed;

  /// No description provided for @downloadsMediaFallback.
  ///
  /// In zh, this message translates to:
  /// **'媒体文件'**
  String get downloadsMediaFallback;

  /// No description provided for @transferQueued.
  ///
  /// In zh, this message translates to:
  /// **'等待下载'**
  String get transferQueued;

  /// No description provided for @transferDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载'**
  String get transferDownloading;

  /// No description provided for @transferSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存到接收目录'**
  String get transferSaving;

  /// No description provided for @transferCompleted.
  ///
  /// In zh, this message translates to:
  /// **'已保存到本机'**
  String get transferCompleted;

  /// No description provided for @transferFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get transferFailed;

  /// No description provided for @transferPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get transferPaused;

  /// No description provided for @transferDiscarded.
  ///
  /// In zh, this message translates to:
  /// **'等待清理暂存'**
  String get transferDiscarded;

  /// No description provided for @transferNotDownloaded.
  ///
  /// In zh, this message translates to:
  /// **'原文件尚未下载'**
  String get transferNotDownloaded;

  /// No description provided for @transferContinues.
  ///
  /// In zh, this message translates to:
  /// **'可返回相册或切换应用，接收任务会继续进行。'**
  String get transferContinues;

  /// No description provided for @transferStaged.
  ///
  /// In zh, this message translates to:
  /// **'已暂存约 {size}，暂停会保留，删除任务可释放空间。'**
  String transferStaged(String size);

  /// No description provided for @transferAttempt.
  ///
  /// In zh, this message translates to:
  /// **'第 {attempt} 次尝试'**
  String transferAttempt(int attempt);

  /// No description provided for @transferShowInFolder.
  ///
  /// In zh, this message translates to:
  /// **'在文件夹中显示'**
  String get transferShowInFolder;

  /// No description provided for @transferPlayVideo.
  ///
  /// In zh, this message translates to:
  /// **'播放视频'**
  String get transferPlayVideo;

  /// No description provided for @transferOpenWith.
  ///
  /// In zh, this message translates to:
  /// **'用其他应用打开'**
  String get transferOpenWith;

  /// No description provided for @transferPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停下载'**
  String get transferPause;

  /// No description provided for @transferRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试下载'**
  String get transferRetry;

  /// No description provided for @transferResume.
  ///
  /// In zh, this message translates to:
  /// **'继续下载'**
  String get transferResume;

  /// No description provided for @transferDownloadOriginal.
  ///
  /// In zh, this message translates to:
  /// **'下载原文件'**
  String get transferDownloadOriginal;

  /// No description provided for @transferCancelAndDelete.
  ///
  /// In zh, this message translates to:
  /// **'取消并删除'**
  String get transferCancelAndDelete;

  /// No description provided for @transferDeleteTask.
  ///
  /// In zh, this message translates to:
  /// **'删除任务并释放空间'**
  String get transferDeleteTask;

  /// No description provided for @transferRetryLater.
  ///
  /// In zh, this message translates to:
  /// **'{error}；稍后会自动重试'**
  String transferRetryLater(String error);

  /// No description provided for @updateTitle.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get updateTitle;

  /// No description provided for @updateChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get updateChecking;

  /// No description provided for @updateUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get updateUpToDate;

  /// No description provided for @updateAvailable.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateAvailable(String version);

  /// No description provided for @updateSystemFailed.
  ///
  /// In zh, this message translates to:
  /// **'系统无法完成更新，请重试'**
  String get updateSystemFailed;

  /// No description provided for @updateFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新操作失败，请检查网络、磁盘空间及安装权限后重试'**
  String get updateFailed;

  /// No description provided for @updateConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'更新至 {version}？'**
  String updateConfirmTitle(String version);

  /// No description provided for @updateConfirmMac.
  ///
  /// In zh, this message translates to:
  /// **'将打开此版本的 GitHub Release 页面，请下载 macOS 安装包并手动完成升级。'**
  String get updateConfirmMac;

  /// No description provided for @updateConfirmAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'确认后下载并校验安装包，完成后自动发起安装。更新会中断共享和传输，未完成的下载可在重新打开后重试。\n\nv1.0.0 前不保证旧数据或跨版本互联兼容，请阅读更新说明；必要时需重新选择目录并连接设备。'**
  String get updateConfirmAutomatic;

  /// No description provided for @updateConfirmAndroid.
  ///
  /// In zh, this message translates to:
  /// **'Android 可能要求允许安装此来源的应用，并在系统界面确认。'**
  String get updateConfirmAndroid;

  /// No description provided for @updateConfirmWindows.
  ///
  /// In zh, this message translates to:
  /// **'Windows 将退出并重新启动玉响。'**
  String get updateConfirmWindows;

  /// No description provided for @updateDecline.
  ///
  /// In zh, this message translates to:
  /// **'暂不更新'**
  String get updateDecline;

  /// No description provided for @updateOpenDownloadPage.
  ///
  /// In zh, this message translates to:
  /// **'打开下载页面'**
  String get updateOpenDownloadPage;

  /// No description provided for @updateDownloadAndInstall.
  ///
  /// In zh, this message translates to:
  /// **'下载并安装'**
  String get updateDownloadAndInstall;

  /// No description provided for @updateOpenedDownloadPage.
  ///
  /// In zh, this message translates to:
  /// **'已打开此版本的下载页面，请手动完成升级'**
  String get updateOpenedDownloadPage;

  /// No description provided for @updateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载安装包…'**
  String get updateDownloading;

  /// No description provided for @updateVerifying.
  ///
  /// In zh, this message translates to:
  /// **'正在校验安装包…'**
  String get updateVerifying;

  /// No description provided for @updatePreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在准备安装…'**
  String get updatePreparing;

  /// No description provided for @updateExiting.
  ///
  /// In zh, this message translates to:
  /// **'正在结束传输，安装后将重新打开玉响…'**
  String get updateExiting;

  /// No description provided for @updateHandedToSystem.
  ///
  /// In zh, this message translates to:
  /// **'已交给系统安装，请完成系统提示'**
  String get updateHandedToSystem;

  /// No description provided for @updateDownloadCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消下载'**
  String get updateDownloadCancelled;

  /// No description provided for @updateInstallIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'安装未完成，请重试'**
  String get updateInstallIncomplete;

  /// No description provided for @updateInstalled.
  ///
  /// In zh, this message translates to:
  /// **'安装完成，请重新打开玉响'**
  String get updateInstalled;

  /// No description provided for @updatePendingUserAction.
  ///
  /// In zh, this message translates to:
  /// **'请在系统安装界面确认更新'**
  String get updatePendingUserAction;

  /// No description provided for @updateCurrentVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前版本 {version}'**
  String updateCurrentVersion(String version);

  /// No description provided for @updateIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'更新未完成'**
  String get updateIncomplete;

  /// No description provided for @updateCancelDownload.
  ///
  /// In zh, this message translates to:
  /// **'取消下载'**
  String get updateCancelDownload;

  /// Windows only; quotes the tray menu item that exits the app.
  ///
  /// In zh, this message translates to:
  /// **'应用已停止共享和传输，可重试完成安装；如仍失败，请从系统托盘选择「退出玉响」后重新打开。'**
  String get updateExitFailedHint;

  /// No description provided for @updateRetryInstall.
  ///
  /// In zh, this message translates to:
  /// **'重试安装'**
  String get updateRetryInstall;

  /// No description provided for @updateCheckAgain.
  ///
  /// In zh, this message translates to:
  /// **'重新检查'**
  String get updateCheckAgain;

  /// No description provided for @updateFinishExit.
  ///
  /// In zh, this message translates to:
  /// **'完成退出并安装'**
  String get updateFinishExit;

  /// No description provided for @updateSourceNote.
  ///
  /// In zh, this message translates to:
  /// **'从 GitHub 获取已公开版本（包括预发布），需要互联网连接。'**
  String get updateSourceNote;

  /// No description provided for @updateReleaseNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新说明'**
  String get updateReleaseNotes;

  /// No description provided for @updateNoReleaseNotes.
  ///
  /// In zh, this message translates to:
  /// **'此版本未提供更新说明。'**
  String get updateNoReleaseNotes;

  /// No description provided for @aboutTitle.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get aboutTitle;

  /// No description provided for @aboutSummary.
  ///
  /// In zh, this message translates to:
  /// **'在局域网设备之间浏览与按需传递照片、视频，让美好的瞬间随手可及。'**
  String get aboutSummary;

  /// No description provided for @aboutVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本号'**
  String get aboutVersion;

  /// No description provided for @aboutReadingVersion.
  ///
  /// In zh, this message translates to:
  /// **'正在读取版本…'**
  String get aboutReadingVersion;

  /// No description provided for @aboutVersionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法读取版本信息'**
  String get aboutVersionUnavailable;

  /// No description provided for @aboutProjectLicense.
  ///
  /// In zh, this message translates to:
  /// **'项目开源许可'**
  String get aboutProjectLicense;

  /// No description provided for @aboutThirdPartyLicenses.
  ///
  /// In zh, this message translates to:
  /// **'第三方开源许可'**
  String get aboutThirdPartyLicenses;

  /// No description provided for @aboutThirdPartyLicensesSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'感谢 Flutter 与开源社区'**
  String get aboutThirdPartyLicensesSubtitle;

  /// No description provided for @aboutMusings.
  ///
  /// In zh, this message translates to:
  /// **'碎碎念'**
  String get aboutMusings;

  /// No description provided for @aboutMusingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'关于名字、摄影，还有一个特别的端口'**
  String get aboutMusingsSubtitle;

  /// No description provided for @licenseIntro.
  ///
  /// In zh, this message translates to:
  /// **'Tamayura 采用 Apache License 2.0 开源许可。以下为完整许可正文。'**
  String get licenseIntro;

  /// No description provided for @licenseReading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取许可…'**
  String get licenseReading;

  /// No description provided for @licenseUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法读取许可正文'**
  String get licenseUnavailable;

  /// No description provided for @musingNameTitle.
  ///
  /// In zh, this message translates to:
  /// **'名字来自《玉响》'**
  String get musingNameTitle;

  /// No description provided for @musingNameText.
  ///
  /// In zh, this message translates to:
  /// **'项目取名自动画《玉响》（Tamayura / たまゆら）。这是一部以摄影为线索、描绘日常与成长的动画：喜欢摄影的沢渡楓来到父亲的故乡——广岛县竹原市，用相机记录身边的风景，也与朋友们一起寻找生活中的小小幸福。'**
  String get musingNameText;

  /// No description provided for @musingMomentsTitle.
  ///
  /// In zh, this message translates to:
  /// **'把美好的瞬间，留在身边'**
  String get musingMomentsTitle;

  /// No description provided for @musingMomentsText.
  ///
  /// In zh, this message translates to:
  /// **'摄影让转瞬即逝的光、风景和笑容有了可以重逢的地方。玉响这个项目也是为此而生：让记录下来的美好，在自己的设备之间轻松流动。无论照片留在哪一台设备里，都希望你能随时翻到、取回，再分享给在意的人。'**
  String get musingMomentsText;

  /// No description provided for @musingPortTitle.
  ///
  /// In zh, this message translates to:
  /// **'50728，一个小小的纪念'**
  String get musingPortTitle;

  /// No description provided for @musingPortText.
  ///
  /// In zh, this message translates to:
  /// **'沢渡（さわたり）楓（ふう）的生日是 1995 年 7 月 28 日。取年份末位的「5」和月日的「0728」，组成了玉响的默认端口 {port}。每一次连接，也藏着对这部动画的一点喜欢。'**
  String musingPortText(int port);

  /// No description provided for @defaultDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'我的设备'**
  String get defaultDeviceName;

  /// No description provided for @lanDeviceFallback.
  ///
  /// In zh, this message translates to:
  /// **'局域网设备'**
  String get lanDeviceFallback;

  /// Name of a receive subfolder when the source folder name is unusable.
  ///
  /// In zh, this message translates to:
  /// **'目录'**
  String get fallbackFolderName;

  /// No description provided for @spaceLocationDownloadDisk.
  ///
  /// In zh, this message translates to:
  /// **'下载所在磁盘'**
  String get spaceLocationDownloadDisk;

  /// No description provided for @spaceLocationStaging.
  ///
  /// In zh, this message translates to:
  /// **'下载暂存目录'**
  String get spaceLocationStaging;

  /// No description provided for @spaceLocationDestination.
  ///
  /// In zh, this message translates to:
  /// **'接收目录'**
  String get spaceLocationDestination;

  /// No description provided for @errorAppNotReady.
  ///
  /// In zh, this message translates to:
  /// **'应用尚未完成初始化，请稍后重试'**
  String get errorAppNotReady;

  /// No description provided for @errorAppNotReadyTheme.
  ///
  /// In zh, this message translates to:
  /// **'应用尚未完成初始化，请重试后切换主题'**
  String get errorAppNotReadyTheme;

  /// No description provided for @errorDeviceOrderSave.
  ///
  /// In zh, this message translates to:
  /// **'设备顺序保存失败，请重试'**
  String get errorDeviceOrderSave;

  /// No description provided for @errorThemeSave.
  ///
  /// In zh, this message translates to:
  /// **'主题设置保存失败，请重试'**
  String get errorThemeSave;

  /// No description provided for @errorLanguageSave.
  ///
  /// In zh, this message translates to:
  /// **'语言设置保存失败，请重试'**
  String get errorLanguageSave;

  /// No description provided for @errorDetailedModeSave.
  ///
  /// In zh, this message translates to:
  /// **'相册详细模式设置保存失败，请重试'**
  String get errorDetailedModeSave;

  /// No description provided for @errorAutoSyncRange.
  ///
  /// In zh, this message translates to:
  /// **'自动同步间隔请输入 1–525600 的整数分钟'**
  String get errorAutoSyncRange;

  /// No description provided for @errorAutoSyncSave.
  ///
  /// In zh, this message translates to:
  /// **'自动同步间隔保存失败，请重试'**
  String get errorAutoSyncSave;

  /// No description provided for @errorStagingCleanup.
  ///
  /// In zh, this message translates to:
  /// **'部分下载暂存未能清理，可重试删除任务。{error}'**
  String errorStagingCleanup(String error);

  /// No description provided for @errorDiscoveryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'设备发现暂不可用，可手动输入 IP 连接。{error}'**
  String errorDiscoveryUnavailable(String error);

  /// No description provided for @errorAutoDiscoveryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'自动发现暂不可用，可在「设备」中手动连接。'**
  String get errorAutoDiscoveryUnavailable;

  /// No description provided for @errorAddressInUse.
  ///
  /// In zh, this message translates to:
  /// **'此 IP 地址已由另一台设备使用，请重新发现设备'**
  String get errorAddressInUse;

  /// No description provided for @errorOwnAddress.
  ///
  /// In zh, this message translates to:
  /// **'这是本机地址，请输入另一台设备的地址'**
  String get errorOwnAddress;

  /// No description provided for @errorFolderAlreadyShared.
  ///
  /// In zh, this message translates to:
  /// **'这个目录已在共享列表中，无需重复添加'**
  String get errorFolderAlreadyShared;

  /// No description provided for @errorSharingIdentity.
  ///
  /// In zh, this message translates to:
  /// **'共享服务身份核验失败'**
  String get errorSharingIdentity;

  /// No description provided for @errorSharingConfirm.
  ///
  /// In zh, this message translates to:
  /// **'后台共享启动确认失败，请重试'**
  String get errorSharingConfirm;

  /// No description provided for @errorPeerStalled.
  ///
  /// In zh, this message translates to:
  /// **'对端长时间没有响应，可能已休眠或离开局域网'**
  String get errorPeerStalled;

  /// No description provided for @errorSystemOperation.
  ///
  /// In zh, this message translates to:
  /// **'系统操作失败，请重试'**
  String get errorSystemOperation;

  /// No description provided for @errorPeerFileMissing.
  ///
  /// In zh, this message translates to:
  /// **'对端文件已删除或不可访问，请刷新相册'**
  String get errorPeerFileMissing;

  /// No description provided for @errorPeerFolderUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'对端共享目录不可用，请在对端重新选择目录并刷新'**
  String get errorPeerFolderUnavailable;

  /// No description provided for @errorTransferIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'文件未传输完整，请重试'**
  String get errorTransferIncomplete;

  /// No description provided for @errorPeerUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'暂时连不上这台设备，请确认两台设备在同一局域网，且对端应用已打开'**
  String get errorPeerUnreachable;

  /// No description provided for @errorNetworkUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法连接局域网，请检查 Wi-Fi 后重试'**
  String get errorNetworkUnavailable;

  /// No description provided for @errorFileSave.
  ///
  /// In zh, this message translates to:
  /// **'文件保存失败，请检查剩余空间和目录权限'**
  String get errorFileSave;

  /// No description provided for @errorUnknown.
  ///
  /// In zh, this message translates to:
  /// **'操作未完成，请重试。{error}'**
  String errorUnknown(String error);

  /// No description provided for @errorFolderOverlap.
  ///
  /// In zh, this message translates to:
  /// **'此目录已共享，或与现有共享目录存在父子关系'**
  String get errorFolderOverlap;

  /// No description provided for @errorFileChanged.
  ///
  /// In zh, this message translates to:
  /// **'文件大小已改变，请刷新相册'**
  String get errorFileChanged;

  /// No description provided for @errorScanCancelled.
  ///
  /// In zh, this message translates to:
  /// **'共享目录已改变，请重新扫描'**
  String get errorScanCancelled;

  /// No description provided for @errorAddressRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入局域网 IPv4 地址，或扫描 Tamayura 二维码'**
  String get errorAddressRequired;

  /// No description provided for @errorAddressInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的局域网 IPv4 地址，例如 192.168.1.8:{port}'**
  String errorAddressInvalid(int port);

  /// No description provided for @errorAddressNotPrivate.
  ///
  /// In zh, this message translates to:
  /// **'当前原型仅支持局域网私有 IPv4 地址'**
  String get errorAddressNotPrivate;

  /// No description provided for @errorPortRange.
  ///
  /// In zh, this message translates to:
  /// **'端口应为 1 到 65535'**
  String get errorPortRange;

  /// No description provided for @errorVersionUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取应用版本信息，请重试'**
  String get errorVersionUnreadable;

  /// No description provided for @errorAppExiting.
  ///
  /// In zh, this message translates to:
  /// **'应用正在退出，请重新打开后重试下载'**
  String get errorAppExiting;

  /// No description provided for @errorSharedFolderConfig.
  ///
  /// In zh, this message translates to:
  /// **'共享目录配置无效，请重新选择目录'**
  String get errorSharedFolderConfig;

  /// No description provided for @errorMediaPath.
  ///
  /// In zh, this message translates to:
  /// **'媒体文件的相对路径无效'**
  String get errorMediaPath;

  /// No description provided for @errorMediaFolderPath.
  ///
  /// In zh, this message translates to:
  /// **'媒体文件的共享目录或相对路径无效'**
  String get errorMediaFolderPath;

  /// No description provided for @errorCatalogChanged.
  ///
  /// In zh, this message translates to:
  /// **'媒体目录已更新，请重试同步'**
  String get errorCatalogChanged;

  /// No description provided for @errorSharedFoldersChanged.
  ///
  /// In zh, this message translates to:
  /// **'共享目录已更新，请稍后重试'**
  String get errorSharedFoldersChanged;

  /// No description provided for @errorTaskIdMissing.
  ///
  /// In zh, this message translates to:
  /// **'下载任务缺少 ID'**
  String get errorTaskIdMissing;

  /// No description provided for @errorAddressOwnedByOther.
  ///
  /// In zh, this message translates to:
  /// **'该地址已属于另一台设备，请重新发现后重试'**
  String get errorAddressOwnedByOther;

  /// No description provided for @errorSpaceInsufficient.
  ///
  /// In zh, this message translates to:
  /// **'{location}空间不足，请释放空间后重试'**
  String errorSpaceInsufficient(String location);

  /// No description provided for @errorChunkSize.
  ///
  /// In zh, this message translates to:
  /// **'收到的文件分片大小有误，请刷新后重试'**
  String get errorChunkSize;

  /// No description provided for @errorChunkIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'文件分片未传输完整，请重试继续下载'**
  String get errorChunkIncomplete;

  /// No description provided for @errorDownloadSizeMismatch.
  ///
  /// In zh, this message translates to:
  /// **'下载文件大小与目录记录不符，请刷新后重试'**
  String get errorDownloadSizeMismatch;

  /// No description provided for @errorDatabaseDirectory.
  ///
  /// In zh, this message translates to:
  /// **'本机数据库目录不可用，请检查用户目录权限后重试'**
  String get errorDatabaseDirectory;

  /// No description provided for @errorTransferTarget.
  ///
  /// In zh, this message translates to:
  /// **'媒体所属设备或共享目录无效，请刷新相册'**
  String get errorTransferTarget;

  /// No description provided for @errorStagingNotCleaned.
  ///
  /// In zh, this message translates to:
  /// **'暂存文件尚未清理，请先重试删除任务'**
  String get errorStagingNotCleaned;

  /// No description provided for @errorStagingCleanupFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂存清理失败，请重试删除任务'**
  String get errorStagingCleanupFailed;

  /// No description provided for @errorFileDeletedRedownload.
  ///
  /// In zh, this message translates to:
  /// **'文件已删除，请重新下载'**
  String get errorFileDeletedRedownload;

  /// No description provided for @errorTaskInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'任务已中断，点重试继续下载'**
  String get errorTaskInterrupted;

  /// No description provided for @errorCatalogVersion.
  ///
  /// In zh, this message translates to:
  /// **'无效的媒体目录版本'**
  String get errorCatalogVersion;

  /// No description provided for @errorCatalogCursor.
  ///
  /// In zh, this message translates to:
  /// **'无效的媒体目录分页断点'**
  String get errorCatalogCursor;

  /// No description provided for @errorCatalogInvalidEntries.
  ///
  /// In zh, this message translates to:
  /// **'对端媒体目录包含无效或重复的文件'**
  String get errorCatalogInvalidEntries;

  /// No description provided for @errorCatalogInvalidEntriesRefresh.
  ///
  /// In zh, this message translates to:
  /// **'对端媒体目录包含无效或重复的文件，请刷新后重试'**
  String get errorCatalogInvalidEntriesRefresh;

  /// No description provided for @errorCatalogDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'对端媒体目录包含重复文件，请重试'**
  String get errorCatalogDuplicate;

  /// No description provided for @errorCatalogCount.
  ///
  /// In zh, this message translates to:
  /// **'对端媒体目录数量不一致，请重试'**
  String get errorCatalogCount;

  /// No description provided for @errorCatalogIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'媒体目录尚未接收完整，原有离线相册保持不变'**
  String get errorCatalogIncomplete;

  /// No description provided for @errorThumbnailTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'缩略图超过允许大小'**
  String get errorThumbnailTooLarge;

  /// No description provided for @errorIncompatiblePeer.
  ///
  /// In zh, this message translates to:
  /// **'对端不是兼容的 Tamayura 设备，请确认两端应用版本一致'**
  String get errorIncompatiblePeer;

  /// No description provided for @errorPeerPaging.
  ///
  /// In zh, this message translates to:
  /// **'对端目录分页信息无效，请刷新后重试'**
  String get errorPeerPaging;

  /// No description provided for @errorPeerCatalogInvalid.
  ///
  /// In zh, this message translates to:
  /// **'对端返回的媒体目录无效，请刷新后重试'**
  String get errorPeerCatalogInvalid;

  /// No description provided for @errorPeerThumbnail.
  ///
  /// In zh, this message translates to:
  /// **'对端缩略图无效，请刷新后重试'**
  String get errorPeerThumbnail;

  /// No description provided for @errorPeerCatalogCount.
  ///
  /// In zh, this message translates to:
  /// **'对端目录数量不一致，请重试'**
  String get errorPeerCatalogCount;

  /// No description provided for @errorPeerCatalogVersion.
  ///
  /// In zh, this message translates to:
  /// **'对端目录版本发生变化，请重试'**
  String get errorPeerCatalogVersion;

  /// No description provided for @errorPeerCatalogPageRepeated.
  ///
  /// In zh, this message translates to:
  /// **'对端目录分页重复，请重试'**
  String get errorPeerCatalogPageRepeated;

  /// No description provided for @errorChunkInvalid.
  ///
  /// In zh, this message translates to:
  /// **'收到的文件分片有误，请重新下载'**
  String get errorChunkInvalid;

  /// No description provided for @errorTransferEnded.
  ///
  /// In zh, this message translates to:
  /// **'文件传输提前结束，请重新下载'**
  String get errorTransferEnded;

  /// No description provided for @errorSharingStatus.
  ///
  /// In zh, this message translates to:
  /// **'无法读取后台共享状态，请重试'**
  String get errorSharingStatus;

  /// No description provided for @errorStagingUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'下载暂存目录不可用'**
  String get errorStagingUnavailable;

  /// No description provided for @errorSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'未能保存文件'**
  String get errorSaveFailed;

  /// No description provided for @errorCacheUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'临时目录不可用'**
  String get errorCacheUnavailable;

  /// No description provided for @errorDeviceId.
  ///
  /// In zh, this message translates to:
  /// **'无法读取 {platform} 设备标识，请重启应用后重试'**
  String errorDeviceId(String platform);

  /// No description provided for @errorPlatformUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'尚未支持 {platform} 平台'**
  String errorPlatformUnsupported(String platform);

  /// No description provided for @updateErrorCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消更新下载'**
  String get updateErrorCancelled;

  /// No description provided for @updateErrorCurrentVersion.
  ///
  /// In zh, this message translates to:
  /// **'无法识别当前应用版本，请重新安装正式发布的安装包'**
  String get updateErrorCurrentVersion;

  /// No description provided for @updateErrorReleaseList.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 版本列表格式不正确，请稍后重试'**
  String get updateErrorReleaseList;

  /// No description provided for @updateErrorPageUrl.
  ///
  /// In zh, this message translates to:
  /// **'更新页面地址无效，请稍后重试'**
  String get updateErrorPageUrl;

  /// No description provided for @updateErrorNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新说明格式不正确，请稍后重试'**
  String get updateErrorNotes;

  /// No description provided for @updateErrorListTooLong.
  ///
  /// In zh, this message translates to:
  /// **'版本列表过长，暂时无法确认最新版本，请前往 GitHub 查看'**
  String get updateErrorListTooLong;

  /// No description provided for @updateErrorManifest.
  ///
  /// In zh, this message translates to:
  /// **'新版本的更新清单无效，暂时无法自动更新'**
  String get updateErrorManifest;

  /// No description provided for @updateErrorManifestMismatch.
  ///
  /// In zh, this message translates to:
  /// **'新版本的更新清单与发布版本不一致'**
  String get updateErrorManifestMismatch;

  /// No description provided for @updateErrorAndroidBuild.
  ///
  /// In zh, this message translates to:
  /// **'新版本的 Android 构建号无效，暂时无法覆盖安装'**
  String get updateErrorAndroidBuild;

  /// No description provided for @updateErrorPackageInfo.
  ///
  /// In zh, this message translates to:
  /// **'新版本缺少有效的对应平台安装包信息'**
  String get updateErrorPackageInfo;

  /// No description provided for @updateErrorArchitecture.
  ///
  /// In zh, this message translates to:
  /// **'新版本的安装包架构不受支持'**
  String get updateErrorArchitecture;

  /// No description provided for @updateErrorPackageSize.
  ///
  /// In zh, this message translates to:
  /// **'新版本的安装包大小与更新清单不一致'**
  String get updateErrorPackageSize;

  /// No description provided for @updateErrorInvalidPackage.
  ///
  /// In zh, this message translates to:
  /// **'安装包信息无效，请重新检查更新'**
  String get updateErrorInvalidPackage;

  /// No description provided for @updateErrorDownloadSize.
  ///
  /// In zh, this message translates to:
  /// **'安装包下载大小与更新清单不一致，请重试'**
  String get updateErrorDownloadSize;

  /// No description provided for @updateErrorDownloadTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'安装包下载大小超出更新清单，请重试'**
  String get updateErrorDownloadTooLarge;

  /// No description provided for @updateErrorChecksum.
  ///
  /// In zh, this message translates to:
  /// **'安装包完整性校验失败，请重新下载'**
  String get updateErrorChecksum;

  /// No description provided for @updateErrorBusy.
  ///
  /// In zh, this message translates to:
  /// **'已有更新操作正在进行，请稍候'**
  String get updateErrorBusy;

  /// No description provided for @updateErrorTimeout.
  ///
  /// In zh, this message translates to:
  /// **'连接 GitHub 或下载安装包超时，请检查网络后重试'**
  String get updateErrorTimeout;

  /// No description provided for @updateErrorConnect.
  ///
  /// In zh, this message translates to:
  /// **'无法连接 GitHub，请检查网络后重试'**
  String get updateErrorConnect;

  /// No description provided for @updateErrorConnectionLost.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 连接中断，请稍后重试'**
  String get updateErrorConnectionLost;

  /// No description provided for @updateErrorStorage.
  ///
  /// In zh, this message translates to:
  /// **'无法保存更新安装包，请检查可用空间和目录权限后重试'**
  String get updateErrorStorage;

  /// No description provided for @updateErrorFormat.
  ///
  /// In zh, this message translates to:
  /// **'更新信息格式不正确，请稍后重试'**
  String get updateErrorFormat;

  /// No description provided for @updateErrorResponseTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'更新信息超过允许大小，请稍后重试'**
  String get updateErrorResponseTooLarge;

  /// No description provided for @updateErrorRedirect.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 下载地址重定向异常，请稍后重试'**
  String get updateErrorRedirect;

  /// No description provided for @updateErrorForbidden.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 拒绝访问或请求过于频繁，请稍后重试'**
  String get updateErrorForbidden;

  /// No description provided for @updateErrorUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 更新信息或安装包暂时不可用，请稍后重试'**
  String get updateErrorUnavailable;

  /// No description provided for @updateErrorEncoding.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 返回了不支持的下载编码，请稍后重试'**
  String get updateErrorEncoding;

  /// No description provided for @updateErrorUntrustedUrl.
  ///
  /// In zh, this message translates to:
  /// **'更新下载地址不受信任，已停止更新'**
  String get updateErrorUntrustedUrl;

  /// No description provided for @updateErrorNoAssets.
  ///
  /// In zh, this message translates to:
  /// **'新版本缺少发布附件，暂时无法自动更新'**
  String get updateErrorNoAssets;

  /// No description provided for @updateErrorAmbiguousAssets.
  ///
  /// In zh, this message translates to:
  /// **'新版本缺少唯一且完整的发布附件，暂时无法自动更新'**
  String get updateErrorAmbiguousAssets;

  /// No description provided for @updateErrorAssetsPending.
  ///
  /// In zh, this message translates to:
  /// **'新版本的发布附件尚未上传完成，请稍后重试'**
  String get updateErrorAssetsPending;

  /// No description provided for @updateErrorAssetUrl.
  ///
  /// In zh, this message translates to:
  /// **'更新附件地址与发布版本不一致'**
  String get updateErrorAssetUrl;

  /// No description provided for @updateErrorPlatform.
  ///
  /// In zh, this message translates to:
  /// **'当前平台尚不支持应用更新'**
  String get updateErrorPlatform;

  /// No description provided for @updateErrorStagingDirectory.
  ///
  /// In zh, this message translates to:
  /// **'无法创建更新暂存目录，请检查磁盘空间后重试'**
  String get updateErrorStagingDirectory;

  /// No description provided for @updateErrorInstallInfo.
  ///
  /// In zh, this message translates to:
  /// **'此版本缺少有效的安装信息'**
  String get updateErrorInstallInfo;

  /// No description provided for @updateErrorInstallStart.
  ///
  /// In zh, this message translates to:
  /// **'无法确认安装是否已启动，请重试'**
  String get updateErrorInstallStart;

  /// No description provided for @updateErrorReleaseUrl.
  ///
  /// In zh, this message translates to:
  /// **'更新页面地址无效'**
  String get updateErrorReleaseUrl;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
