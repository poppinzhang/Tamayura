// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Tamayura · たまゆら';

  @override
  String get appLocalName => 'たまゆら';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonSave => '保存';

  @override
  String get commonSaving => '保存中…';

  @override
  String get commonRetry => '再試行';

  @override
  String get commonDone => '完了';

  @override
  String get commonConfirm => '確認';

  @override
  String get commonConnect => '接続';

  @override
  String get commonShare => '共有';

  @override
  String get commonOnline => 'オンライン';

  @override
  String get commonOffline => 'オフライン';

  @override
  String get commonVideo => '動画';

  @override
  String get commonImage => '画像';

  @override
  String get navAlbum => 'アルバム';

  @override
  String get navDevices => 'デバイス';

  @override
  String get navSettings => '設定';

  @override
  String get homeDownloadsTooltip => 'ダウンロード';

  @override
  String get homeRefreshTooltip => 'デバイスとアルバムを更新';

  @override
  String get homeOpening => 'アルバムを開いています…';

  @override
  String get homeActionFailed =>
      '操作を完了できませんでした。ネットワークとフォルダーの権限を確認して、もう一度お試しください。';

  @override
  String get homeErrorRetry => '再接続して更新';

  @override
  String get homeErrorDismiss => '閉じる';

  @override
  String get albumHeadline => 'どの瞬間も、すぐそばに。';

  @override
  String get albumSubtitle => '共有フォルダーごとにコレクションを閲覧。写真をタップするとこの端末に保存されます。';

  @override
  String get albumAllDevices => 'すべてのデバイス';

  @override
  String get albumAllCollections => 'すべてのコレクション';

  @override
  String get albumSharedCollectionFallback => '共有コレクション';

  @override
  String get albumDeleteLocalFiles => 'ローカルファイルを削除';

  @override
  String albumCollectionCount(int count) {
    return '$count 件のコレクション';
  }

  @override
  String albumMomentCount(int count) {
    return '$count 件の思い出';
  }

  @override
  String get albumSelectSavedHint => '保存済みの写真・動画を選択';

  @override
  String get albumTapToDownloadHint => 'タップでオリジナルをダウンロード';

  @override
  String get albumReceivingTitle => 'アルバムを受信中';

  @override
  String get albumReceivingDescription => 'サムネイルは順次表示されます。同期しながら閲覧できます。';

  @override
  String get albumSyncIncompleteTitle => '同期が完了していません';

  @override
  String get albumSyncIncompleteDescription =>
      '両方のデバイスの接続を確認してから、もう一度同期してください。';

  @override
  String get albumNoDevicesTitle => '写真をつなげよう';

  @override
  String get albumNoDevicesDescription =>
      '別のデバイスで Tamayura を開き、同じローカルネットワークに接続してください。\nデバイスが見つかると、共有フォルダーがコレクションとしてここに表示されます。';

  @override
  String get albumEmptyCollectionTitle => 'このコレクションにはまだ写真がありません';

  @override
  String get albumNoCollectionsTitle => 'まだコレクションがありません';

  @override
  String get albumNoMediaDesktopDescription =>
      '相手のデバイスで共有フォルダーを選び、Tamayura を起動したままにしてください。\n右上の更新をクリックすると、接続中のデバイスのアルバムを更新します。';

  @override
  String get albumNoMediaMobileDescription =>
      '相手のデバイスで共有フォルダーを選んでください。バックグラウンド共有をオンにすると、画面ロック中もアクセスできます。\n右上の更新をタップすると、接続中のデバイスのアルバムを更新します。';

  @override
  String get albumConnectDevice => 'デバイスを接続';

  @override
  String get albumLoadMoreFailed => '写真を追加で読み込めませんでした。もう一度お試しください。';

  @override
  String get albumLoadingMore => '写真をさらに読み込み中…';

  @override
  String get albumLoadMore => '写真をさらに読み込む';

  @override
  String get albumRetryLoad => '再読み込み';

  @override
  String get albumLoadingThumbnail => 'サムネイルを読み込み中';

  @override
  String get albumRetryThumbnail => 'サムネイルを再読み込み';

  @override
  String get albumSortTooltip => '名前または更新日で並べ替え';

  @override
  String get albumSorting => '並べ替え中…';

  @override
  String albumSortLabel(String order) {
    return '並べ替え：$order';
  }

  @override
  String get albumSortNameAscending => '名前（昇順）';

  @override
  String get albumSortNameDescending => '名前（降順）';

  @override
  String get albumSortDateAscending => '日付（古い順）';

  @override
  String get albumSortDateDescending => '日付（新しい順）';

  @override
  String albumSelectedCount(int count) {
    return '$count 件を選択中';
  }

  @override
  String get albumDeleting => '削除中…';

  @override
  String albumLocalDeleted(int count) {
    return '$count 件のローカルファイルを削除しました。サムネイルをタップすると再ダウンロードできます。';
  }

  @override
  String albumLocalDeletePartial(int deleted, int failed) {
    return '$deleted 件のローカルファイルを削除しましたが、$failed 件は削除できませんでした。フォルダーの権限を確認して、もう一度お試しください。';
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
    return 'アルバムを高速スクロール、$label';
  }

  @override
  String get rememberedDeviceFallback => '記憶済みのデバイス';

  @override
  String get setupTitle => 'まずはアルバムの準備から';

  @override
  String get setupDescription => '共有するフォルダーと、受け取った写真の保存先を追加してください。';

  @override
  String get setupShareFolder => '共有フォルダー';

  @override
  String get setupDownloadFolder => '保存先フォルダー';

  @override
  String collectionSemantics(String folder, String device, int count) {
    return '$folder、$device から、$count 件の思い出';
  }

  @override
  String mediaSemantics(String name, String device, String state) {
    return '$name、$device から、$state';
  }

  @override
  String get mediaStateSaved => '保存済み';

  @override
  String get mediaStateDownloading => 'ダウンロード中';

  @override
  String get mediaStateFailed => 'ダウンロード失敗、タップで再試行';

  @override
  String get mediaStateTapToDownload => 'タップでオリジナルをダウンロード';

  @override
  String get mediaStateOffline => 'デバイスはオフライン、タップで詳細を表示';

  @override
  String get mediaDeviceOffline => 'デバイスはオフライン';

  @override
  String mediaDownloadingName(String name) {
    return '$name をダウンロード中';
  }

  @override
  String mediaSelectName(String name) {
    return '$name を選択';
  }

  @override
  String mediaNotSavedName(String name) {
    return '$name はまだ保存されていません';
  }

  @override
  String get mediaDeleteLocalOnly => 'ローカルファイルのみ削除';

  @override
  String get mediaNotSaved => '未保存';

  @override
  String get mediaDownloadFailedRetry => '失敗 · 再試行';

  @override
  String get mediaReceivingOriginal => 'オリジナルを受信中…';

  @override
  String mediaCardDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.MMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get devicesTitle => '近くの仲間たち';

  @override
  String get devicesSubtitle => '同じローカルネットワークで、すべてのデバイスのアルバムをつなぎます。';

  @override
  String get devicesThisDevice => 'このデバイス';

  @override
  String get devicesNoAddress => 'ローカルネットワークのアドレスがありません。ネットワークに接続してから更新してください';

  @override
  String get devicesShowQr => '接続用 QR コードを表示';

  @override
  String get devicesConnectByIp => 'IP で接続';

  @override
  String get devicesScan => 'QR コードをスキャン';

  @override
  String get devicesConnecting => 'デバイスに接続中…';

  @override
  String get devicesRemembered => '記憶済みのデバイス';

  @override
  String devicesOnlineCount(int count) {
    return '$count 台がオンライン';
  }

  @override
  String get devicesReorder => '並べ替え';

  @override
  String get devicesEmptyTitle => 'もう一台の Tamayura を待っています';

  @override
  String get devicesEmptyDescription =>
      'デバイスはローカルネットワーク上で自動的に検出されます。\n見つからない場合は、IP を入力するか QR コードをスキャンして接続できます。';

  @override
  String get devicesFooterWindows =>
      'デバイスがオフラインでもアルバムのサムネイルは残ります。共有と受信には、Tamayura の起動、PC がスリープしていないこと、送信元デバイスと同じローカルネットワークにいることが必要です。';

  @override
  String get devicesFooterMac =>
      'デバイスがオフラインでもアルバムのサムネイルは残ります。共有と受信には、Tamayura の起動、Mac がスリープしていないこと、送信元デバイスと同じローカルネットワークにいることが必要です。';

  @override
  String get devicesFooterMobile =>
      'デバイスがオフラインでもアルバムのサムネイルは残ります。送信元でバックグラウンド共有をオンにすると、画面ロック中もオリジナルを提供できます。このデバイスは他のアプリに切り替えても受信を続けます。';

  @override
  String deviceLastSuccessfulSync(String time) {
    return '最終同期成功：$time';
  }

  @override
  String get deviceNeverSynced => 'なし';

  @override
  String get devicePendingApproval => '新しく見つかったデバイス · アルバム同期はオフ';

  @override
  String get deviceSyncDeclined => 'アルバム同期はオフ';

  @override
  String get deviceOfflineCached => 'オフライン · キャッシュを閲覧可能';

  @override
  String get deviceActions => 'デバイスの操作';

  @override
  String get deviceEnableAlbumSync => 'アルバム同期をオン';

  @override
  String get deviceForget => 'デバイスの登録を解除';

  @override
  String get deviceStartSync => '同期をオン';

  @override
  String deviceForgotten(String name) {
    return '「$name」の登録を解除しました。再び見つかった場合は、新しいデバイスとして同期するか確認します。';
  }

  @override
  String get deviceForgetFailed => 'このデバイスの登録を解除できませんでした。しばらくしてからもう一度お試しください。';

  @override
  String deviceForgetTitle(String name) {
    return '「$name」の登録を解除しますか？';
  }

  @override
  String get deviceForgetMessage =>
      'このデバイスをリストから外し、オフラインのアルバム情報、サムネイル、未完了の同期状況を削除します。\n\nこのデバイスにダウンロード済みのファイルとダウンロードタスクはそのまま残り、相手側のオリジナルも削除されません。ネットワーク上で再び見つかった場合は、新しいデバイスとして同期するか確認します。';

  @override
  String get syncApprovalTitle => '新しいデバイスが見つかりました';

  @override
  String syncApprovalMessage(String name, String address) {
    return '「$name」（$address）がローカルネットワーク上にあります。このデバイスが共有しているアルバムを同期しますか？\n\n同期ではファイル情報とサムネイルのみを取得し、オリジナルは開いたときにダウンロードします。「今はしない」を選んでも、「デバイス」ページからいつでもオンにできます。';
  }

  @override
  String get syncApprovalDecline => '今はしない';

  @override
  String get syncApprovalAccept => '同期を開始';

  @override
  String get connectDialogTitle => '別のデバイスに接続';

  @override
  String get connectDialogHint => '相手の「デバイス」ページで IP アドレスを確認してください。';

  @override
  String get connectDialogLabel => 'IP アドレスとポート';

  @override
  String get connectDialogEmpty => '相手の IP アドレスを入力してください';

  @override
  String get qrDialogHint => '別のデバイスの Tamayura でスキャン';

  @override
  String qrSemantics(String address, int port) {
    return 'このデバイスの接続用 QR コード、アドレス $address、ポート $port';
  }

  @override
  String get scannerTitle => 'デバイスの QR コードをスキャン';

  @override
  String get scannerInvalidCode =>
      'Tamayura のデバイス QR コードではありません。相手の「デバイス」ページの QR コードをスキャンしてください。';

  @override
  String get scannerCameraUnavailable =>
      'カメラを開けません。システム設定でカメラへのアクセスを許可するか、戻って IP で接続してください。';

  @override
  String get scannerBack => 'デバイスページに戻る';

  @override
  String get scannerHint =>
      '相手のデバイスの QR コードをカメラに映してください\n両方のデバイスが同じローカルネットワークに接続している必要があります';

  @override
  String get syncPhaseConnecting => '接続中';

  @override
  String get syncPhaseReceiving => 'アルバムを同期中';

  @override
  String get syncPhaseCommitting => '同期を完了中';

  @override
  String get syncPhaseCompleted => 'アルバムの同期が完了しました';

  @override
  String get syncPhaseFailed => '今回の同期は完了しませんでした';

  @override
  String syncConnectingResume(int count) {
    return '$count 件を保持しています。デバイスに接続して同期を再開しています。';
  }

  @override
  String get syncConnectingFresh => 'アルバム情報を取得中です。デバイスの接続を保ってください。';

  @override
  String syncReceivingOpen(int count) {
    return '$count 件の準備ができました。さらに写真を取得しています。';
  }

  @override
  String syncReceivingProgress(int ready, int total) {
    return '$total 件中 $ready 件の準備ができました。同期しながら閲覧できます。';
  }

  @override
  String get syncCommittingDetail => 'サムネイルの準備ができました。アルバムを整理しています。';

  @override
  String syncCompletedDetail(int count) {
    return '$count 件の準備ができました。';
  }

  @override
  String syncFailedResume(int count) {
    return '$count 件を保持しています。接続が戻ると同期を再開できます。';
  }

  @override
  String get syncFailedFresh => 'アルバムと同期状況は保持されています。接続を確認して、もう一度お試しください。';

  @override
  String get syncDismiss => '同期のお知らせを閉じる';

  @override
  String syncProgressSemantics(String device, String status, String detail) {
    return '$device、$status、$detail';
  }

  @override
  String get syncContinue => '同期を再開';

  @override
  String get settingsTitle => 'あなたのアルバムを、あなたらしく';

  @override
  String get settingsSubtitle => '選んだフォルダーだけを共有し、オリジナルは必要なときに取得します。';

  @override
  String get settingsAppearance => '外観';

  @override
  String get settingsThemeMode => 'テーマ';

  @override
  String get settingsThemeSystem => 'システム';

  @override
  String get settingsThemeLight => 'ライト';

  @override
  String get settingsThemeDark => 'ダーク';

  @override
  String get settingsThemeSaving => 'テーマを保存中…';

  @override
  String get settingsThemeSystemDescription => 'システムに合わせてライトとダークを自動で切り替えます。';

  @override
  String get settingsThemeLightDescription => '常にライトの外観を使用します。';

  @override
  String get settingsThemeDarkDescription => '常にダークの外観を使用します。';

  @override
  String get settingsLanguage => '言語';

  @override
  String get settingsLanguageSystem => 'システムに従う';

  @override
  String get settingsLanguageSaving => '言語を保存中…';

  @override
  String settingsLanguageSystemDescription(String language) {
    return 'システムの言語に従います（現在：$language）。中国語・日本語以外のシステム言語では英語で表示します。';
  }

  @override
  String settingsLanguageFixedDescription(String language) {
    return 'システムの言語にかかわらず、常に$languageで表示します。';
  }

  @override
  String get settingsAlbum => 'アルバム';

  @override
  String get settingsDetailedMode => '詳細モード';

  @override
  String get settingsDetailedModeSaving => '表示モードを保存中…';

  @override
  String get settingsDetailedModeDescription =>
      '標準モードでは正方形のコンパクトなグリッドで表示し、写真をタップすると詳細を確認できます。\n詳細モードでは、写真カードにファイル名、送信元デバイス、日付、ダウンロード状況を表示します。';

  @override
  String get settingsSync => '同期';

  @override
  String get settingsAutoSyncInterval => '自動同期の間隔';

  @override
  String get settingsAutoSyncSaving => '同期の間隔を保存中…';

  @override
  String settingsAutoSyncDescription(int minutes) {
    return '前回の同期の試行から $minutes 分を過ぎると自動で同期します。\n手動同期や同期の失敗でもタイマーはリセットされます。右上の更新ですぐに同期できます。';
  }

  @override
  String get settingsFilesStorage => 'ファイルとストレージ';

  @override
  String get settingsSharedFolders => '共有フォルダー';

  @override
  String get settingsSharedFoldersDescription =>
      '複数のフォルダーを追加でき、すべてのサブフォルダーも含まれます。追加済みのフォルダーと、その親フォルダー・サブフォルダーは重ねて追加できません。';

  @override
  String get settingsSharedFoldersEmpty => '未選択 · 他のデバイスにここの写真を見せましょう';

  @override
  String settingsRemoveSharedFolder(String name) {
    return '$name を削除';
  }

  @override
  String get settingsAddSharedFolder => '共有フォルダーを追加';

  @override
  String get settingsBackgroundSharing => 'バックグラウンド共有';

  @override
  String get settingsBackgroundSharingWindows =>
      'ウィンドウを閉じても Tamayura はシステムトレイに残ります。オンの場合は、ウィンドウを閉じても最小化しても共有を続けます。オフの場合は、ウィンドウが非表示の間は共有を停止します。PC をスリープさせないでください。';

  @override
  String get settingsBackgroundSharingMac =>
      'ウィンドウを閉じても Tamayura はメニューバーに残ります。オンの場合は、ウィンドウを閉じても、隠しても、最小化しても共有を続けます。オフの場合は、ウィンドウが非表示の間は共有を停止します。Mac をスリープさせないでください。';

  @override
  String get settingsBackgroundSharingLinux =>
      'デスクトップにステータストレイがある場合、ウィンドウを閉じても Tamayura はトレイに残ります。トレイがない場合は、ウィンドウを閉じると Tamayura は終了します。オンの場合は、ウィンドウが非表示または最小化されていても共有を続けます。オフの場合は、ウィンドウが非表示の間は共有を停止します。PC をスリープさせないでください。';

  @override
  String get settingsBackgroundSharingMobile =>
      'オンにすると画面ロック中もメディアを共有します。オフにするとアプリの使用中のみ共有し、バッテリーを節約できます。';

  @override
  String get backgroundSharingStarting => 'バックグラウンド共有を開始中…';

  @override
  String get backgroundSharingUpdating => 'バックグラウンド共有を更新中…';

  @override
  String get backgroundSharingStartFailed =>
      'バックグラウンド共有を開始できませんでした。もう一度お試しください。';

  @override
  String get backgroundSharingOff => 'バックグラウンド共有はオフです。';

  @override
  String get backgroundSharingRunningWindows =>
      'バックグラウンド共有を実行中です。PC がスリープするか Tamayura を終了すると共有は停止します。';

  @override
  String get backgroundSharingRunningMac =>
      'バックグラウンド共有を実行中です。Mac がスリープするか Tamayura を終了すると共有は停止します。';

  @override
  String get backgroundSharingRunningMobile =>
      'バックグラウンド共有を実行中です。画面ロック中も選択したフォルダーにアクセスできます。';

  @override
  String get backgroundSharingNotRunning => 'バックグラウンド共有はまだ実行されていません。';

  @override
  String get backgroundSharingRetry => 'バックグラウンド共有を再試行';

  @override
  String get backgroundSharingBatteryHint =>
      'システムの省電力制限により、スリープ中に共有が中断されることがあります。バッテリー設定で Tamayura の動作を制限しないよう許可してください。';

  @override
  String get backgroundSharingBatterySettings => 'バッテリー設定';

  @override
  String get settingsDownloadFolder => '保存先フォルダー';

  @override
  String get settingsDownloadFolderEmpty => '未選択 · ダウンロードしたオリジナルはここに保存されます';

  @override
  String settingsSharingSummary(int folders, int count) {
    return '$folders 個のフォルダーから $count 件のメディアを共有中';
  }

  @override
  String get settingsDownloadLayout =>
      'オリジナルは「相手のデバイス / 共有フォルダー / 元のサブフォルダー」の構成で保存され、フォルダー階層が保たれます。';

  @override
  String get settingsDeviceInfo => 'このデバイスの情報';

  @override
  String get settingsNoLan => 'ローカルネットワークに未接続';

  @override
  String get settingsTips => '使い方のヒント';

  @override
  String get tipNetworkTitle => '同じネットワークに接続';

  @override
  String get tipNetworkDescription =>
      '現在はローカルネットワークのみに対応しており、アカウントは不要です。フォルダーは信頼できるネットワークでのみ共有してください。';

  @override
  String get tipWindowsTitle => 'Windows で使うために';

  @override
  String get tipWindowsDescription =>
      'Windows 10 1809 以降、Windows 11（x64）に対応しています。プライベートネットワークのファイアウォールで Tamayura を許可してください。IP を入力して手動で接続することもできます。';

  @override
  String get tipLinuxTitle => 'Linux で使うために';

  @override
  String get tipLinuxDescription =>
      'Ubuntu 24.04 LTS と同世代以降のディストリビューション（x64、arm64）に対応しています。自動検出には Avahi（avahi-daemon）が必要です。ファイアウォールで mDNS（UDP 5353）と Tamayura のサービスポートを許可するか、IP を入力して手動で接続してください。';

  @override
  String get tipBackgroundReceiveTitle => 'ウィンドウを閉じても受信は続く';

  @override
  String get tipBackgroundReceiveWindows =>
      'ウィンドウを閉じても、開始済みのダウンロードは続きます。システムトレイの Tamayura アイコンをクリックすると再び開き、右クリックメニューから「Tamayura を終了」を選べます。PC のスリープや切断のあとは、ダウンロードから再試行できます。';

  @override
  String get tipBackgroundReceiveMac =>
      'ウィンドウを閉じても、開始済みのダウンロードは続きます。メニューバーまたは Dock から再び開けます。「Tamayura を終了」を選ぶか ⌘Q を押したときだけ終了します。Mac のスリープや切断のあとは、ダウンロードから再試行できます。';

  @override
  String get tipBackgroundReceiveLinux =>
      'デスクトップにステータストレイがある場合（KDE Plasma、Ubuntu の標準デスクトップ、Xfce など）、ウィンドウを閉じても開始済みのダウンロードは続きます。トレイの Tamayura アイコンをクリックすると再び開き、メニューから「Tamayura を終了」を選べます。トレイがない場合は、ウィンドウを閉じると終了します。Ctrl+Q でいつでも終了できます。PC のスリープや切断のあとは、ダウンロードから再試行できます。';

  @override
  String get tipKeyboardTitle => 'キーボードですばやく切り替え';

  @override
  String get tipKeyboardWindows =>
      'Ctrl+1 アルバム · Ctrl+2 デバイス · Ctrl+3 または Ctrl+, 設定 · Ctrl+R 更新。';

  @override
  String get tipKeyboardMac => '⌘1 アルバム · ⌘2 デバイス · ⌘3 または ⌘, 設定 · ⌘R 更新。';

  @override
  String get tipKeyboardLinux =>
      'Ctrl+1 アルバム · Ctrl+2 デバイス · Ctrl+3 または Ctrl+, 設定 · Ctrl+R 更新 · Ctrl+Q 終了。';

  @override
  String get tipMacTitle => 'Mac で使うために';

  @override
  String get tipMacDescription =>
      'macOS Sequoia 15、Tahoe 26 以降に対応しています。フォルダーへのアクセスとカメラの権限はシステムが管理しており、システム設定で変更できます。';

  @override
  String get tipAndroidTitle => '受信はバックグラウンドで継続';

  @override
  String get tipAndroidDescription =>
      'Android 16 以降に対応しています。通知の許可は任意で、通知がオフでもダウンロードでき、進行状況はダウンロード画面で確認できます。送信元でバックグラウンド共有をオンにすれば画面をロックできます。両方のデバイスが同じローカルネットワークにいる必要があります。';

  @override
  String get tipOpenTitle => 'タップで取得、ダウンロード後に開く';

  @override
  String get tipOpenDescription =>
      '共有フォルダーはそれぞれ独立したコレクションとして表示されます。クリックしてオリジナルをダウンロードし、システムのアプリで開くか、エクスプローラーで場所を表示できます。';

  @override
  String get tipOpenDescriptionLinux =>
      '共有フォルダーはそれぞれ独立したコレクションとして表示されます。クリックしてオリジナルをダウンロードし、システムのアプリで開くか、ファイルマネージャーで場所を表示できます。';

  @override
  String get tipShareTitle => 'タップで取得、ダウンロード後に共有';

  @override
  String get tipShareDescription =>
      '共有フォルダーはそれぞれ独立したコレクションとして表示され、すべてのサブフォルダーの写真と動画を含みます。タップしてオリジナルをダウンロードし、共有ボタンで他のアプリに送れます。';

  @override
  String get settingsAboutProject => 'プロジェクトについて';

  @override
  String get settingsCheckUpdates => 'アップデートを確認';

  @override
  String get settingsCheckUpdatesSubtitle =>
      'GitHub で新しいバージョンを確認し、確認後にアップデートします';

  @override
  String get settingsAbout => 'このアプリについて';

  @override
  String get settingsAboutSubtitle => 'バージョン、オープンソースライセンス、ちょっとした雑記';

  @override
  String get autoSyncDialogDescription =>
      '直近の同期の試行から計測し、設定した分数を過ぎると自動同期を試みます。手動同期や同期の失敗でもタイマーはリセットされます。';

  @override
  String get autoSyncDialogLabel => '間隔（分）';

  @override
  String get autoSyncDialogHelper => '1–525600 分、既定は 10 分';

  @override
  String get autoSyncDialogInvalid => '1–525600 の整数（分）を入力してください';

  @override
  String get autoSyncDialogSaveFailed => '同期の間隔を保存できませんでした。もう一度お試しください。';

  @override
  String get deviceOrderTitle => 'デバイスの並べ替え';

  @override
  String get deviceOrderDescription =>
      'ハンドルをドラッグするか矢印で並べ替えます。アルバムのデバイスもこの順に表示されます。';

  @override
  String deviceOrderDrag(String name) {
    return '$name をドラッグ';
  }

  @override
  String deviceOrderMoveUp(String name) {
    return '$name を上へ移動';
  }

  @override
  String deviceOrderMoveDown(String name) {
    return '$name を下へ移動';
  }

  @override
  String get deviceOrderSaveFailed => 'デバイスの順序を保存できませんでした。もう一度お試しください。';

  @override
  String get previewUnavailable =>
      'オリジナルは保存済みですが、アプリ内ではプレビューできません。他のアプリで開いてください。';

  @override
  String get previewReadFailed =>
      'オリジナルのプレビューを読み込めませんでした。再試行するか、他のアプリで開いてください。';

  @override
  String get previewActionFailed =>
      '操作を完了できませんでした。ネットワークまたはファイルの権限を確認して、もう一度お試しください。';

  @override
  String get previewLocalDeleted => 'ローカルファイルを削除しました。再ダウンロードできます。';

  @override
  String get previewLocalDeleteFailed =>
      'ローカルファイルを削除できませんでした。フォルダーの権限を確認して、もう一度お試しください。';

  @override
  String get previewDetails => '詳細情報';

  @override
  String get previewCloseDetails => '詳細情報を閉じる';

  @override
  String get detailFileName => 'ファイル名';

  @override
  String get detailSourceDevice => '送信元デバイス';

  @override
  String get detailDeviceStatus => 'デバイスの状態';

  @override
  String get detailDeviceUnknown => 'デバイスの記録がありません';

  @override
  String get detailModified => '更新日時（ローカル）';

  @override
  String get detailType => '種類';

  @override
  String get detailSize => 'サイズ';

  @override
  String detailSizeValue(String size, int bytes) {
    return '$size（$bytes バイト）';
  }

  @override
  String get detailCollection => 'コレクション';

  @override
  String get detailRelativePath => '相対パス';

  @override
  String get previewImageError => 'このプレビューを表示できません。ダウンロードして他のアプリで開いてください。';

  @override
  String get previewBack => 'アルバムに戻る';

  @override
  String get previewDeleteLocal => 'ローカルファイルを削除';

  @override
  String get previewZoomReset => 'ズームをリセット';

  @override
  String get previewZoomIn => '拡大';

  @override
  String get previewRotateClockwise => '右に回転';

  @override
  String get previewRotateCounterclockwise => '左に回転';

  @override
  String get previewPrevious => '前のメディア';

  @override
  String get previewNext => '次のメディア';

  @override
  String previewPosition(int current, int total) {
    return '$current / $total 件目';
  }

  @override
  String get previewSwipeHorizontal => '左右にスワイプして前後のメディアを表示';

  @override
  String get previewVideoHint => '動画のサムネイル · ダウンロード後にシステムのプレーヤーで開けます';

  @override
  String get previewReadingOriginal => 'ローカルのオリジナルを読み込み中…';

  @override
  String get previewOriginalDesktop => 'ローカルのオリジナル · ダブルクリックまたはスクロールでズーム';

  @override
  String get previewOriginalMobile => 'ローカルのオリジナル · ピンチでズーム';

  @override
  String get previewCachedThumbnail => 'キャッシュのサムネイル · ダウンロード後にオリジナルを表示';

  @override
  String get previewResetDesktop => 'ダブルクリックで元に戻す';

  @override
  String get previewResetMobile => 'ダブルタップで元に戻す';

  @override
  String get previewZoomDesktop => 'ダブルクリックで拡大';

  @override
  String get previewSwipeDown => '下にスワイプで戻る';

  @override
  String previewSource(String device) {
    return '$device から';
  }

  @override
  String get previewRetry => 'プレビューを再読み込み';

  @override
  String get downloadsTitle => 'ダウンロード';

  @override
  String get downloadsEmptyTitle => '次のお気に入りの一枚が、もうすぐ届きます';

  @override
  String get downloadsEmptyDescription =>
      'アルバムの写真や動画をタップすると、ここでダウンロードの進行状況を確認できます。';

  @override
  String get downloadsBackToAlbum => 'アルバムに戻る';

  @override
  String get downloadsAllDone => 'すべて、あるべき場所に。';

  @override
  String downloadsActive(int count) {
    return '$count 件のタスクを実行中';
  }

  @override
  String get downloadsHintWindows =>
      'ウィンドウを閉じても受信を続け、システムトレイから再び開けます。PC をスリープさせず、送信元デバイスと同じローカルネットワークにいてください。終了やスリープで中断した場合は再試行できます。';

  @override
  String get downloadsHintMac =>
      'ウィンドウを閉じても受信を続け、メニューバーまたは Dock から再び開けます。Mac をスリープさせず、送信元デバイスと同じローカルネットワークにいてください。終了やスリープで中断した場合は再試行できます。';

  @override
  String get downloadsHintLinux =>
      'ステータストレイがある場合は、ウィンドウを閉じても受信を続け、トレイから再び開けます。トレイがない場合は、ウィンドウを閉じると終了し、受信も中断します。PC をスリープさせず、送信元デバイスと同じローカルネットワークにいてください。終了やスリープで中断した場合は再試行できます。';

  @override
  String get downloadsHintMobile =>
      '受信はバックグラウンドで続きます。送信元デバイスでは Tamayura を起動したままにし、このデバイスと同じローカルネットワークにいる必要があります。';

  @override
  String get downloadsActionFailed => 'タスクの操作を完了できませんでした。もう一度お試しください。';

  @override
  String get downloadsMediaFallback => 'メディアファイル';

  @override
  String get transferQueued => 'ダウンロード待ち';

  @override
  String get transferDownloading => 'ダウンロード中';

  @override
  String get transferSaving => '保存先フォルダーに保存中';

  @override
  String get transferCompleted => 'このデバイスに保存済み';

  @override
  String get transferFailed => 'ダウンロード失敗';

  @override
  String get transferPaused => '一時停止中';

  @override
  String get transferDiscarded => '一時データの削除待ち';

  @override
  String get transferNotDownloaded => 'オリジナルは未ダウンロード';

  @override
  String get transferContinues => 'アルバムに戻ったり他のアプリに切り替えたりしても、受信は続きます。';

  @override
  String transferStaged(String size) {
    return '約 $size を一時保存済みです。一時停止しても保持され、タスクを削除すると容量を解放できます。';
  }

  @override
  String transferAttempt(int attempt) {
    return '$attempt 回目の試行';
  }

  @override
  String get transferShowInFolder => 'フォルダーに表示';

  @override
  String get transferPlayVideo => '動画を再生';

  @override
  String get transferOpenWith => '他のアプリで開く';

  @override
  String get transferPause => 'ダウンロードを一時停止';

  @override
  String get transferRetry => 'ダウンロードを再試行';

  @override
  String get transferResume => 'ダウンロードを再開';

  @override
  String get transferDownloadOriginal => 'オリジナルをダウンロード';

  @override
  String get transferCancelAndDelete => 'キャンセルして削除';

  @override
  String get transferDeleteTask => 'タスクを削除して容量を解放';

  @override
  String transferRetryLater(String error) {
    return '$error。しばらくすると自動で再試行します';
  }

  @override
  String get updateTitle => 'アップデートを確認';

  @override
  String get updateChecking => 'アップデートを確認中…';

  @override
  String get updateUpToDate => '最新バージョンです';

  @override
  String updateAvailable(String version) {
    return '新しいバージョン $version があります';
  }

  @override
  String get updateSystemFailed => 'システムがアップデートを完了できませんでした。もう一度お試しください';

  @override
  String get updateFailed =>
      'アップデートに失敗しました。ネットワーク、ディスクの空き容量、インストールの権限を確認して、もう一度お試しください';

  @override
  String updateConfirmTitle(String version) {
    return '$version にアップデートしますか？';
  }

  @override
  String get updateConfirmMac =>
      'このバージョンの GitHub Release ページを開きます。macOS 版のパッケージをダウンロードして、手動でアップグレードしてください。';

  @override
  String get updateConfirmLinux =>
      'このバージョンの GitHub Release ページを開きます。お使いのアーキテクチャの Linux 版アーカイブをダウンロードし、Tamayura を終了してから新しいフォルダーに展開し、そのフォルダーで install-desktop-entry.sh を再実行してください。新しいバージョンの動作を確認したら、古いフォルダーは削除できます。';

  @override
  String get updateConfirmAutomatic =>
      '確認後にパッケージをダウンロードして検証し、完了するとインストールを自動で開始します。アップデート中は共有と転送が中断されます。未完了のダウンロードは再度開いたあとに再試行できます。\n\nv1.0.0 より前は、古いデータやバージョン間の接続の互換性を保証しません。リリースノートをお読みください。必要に応じてフォルダーを選び直し、デバイスを再接続してください。';

  @override
  String get updateConfirmAndroid =>
      'Android では、この提供元からのアプリのインストール許可と、システム画面での確認を求められる場合があります。';

  @override
  String get updateConfirmWindows => 'Windows では Tamayura を終了して再起動します。';

  @override
  String get updateDecline => '今はしない';

  @override
  String get updateOpenDownloadPage => 'ダウンロードページを開く';

  @override
  String get updateDownloadAndInstall => 'ダウンロードしてインストール';

  @override
  String get updateOpenedDownloadPage =>
      'このバージョンのダウンロードページを開きました。手動でアップグレードしてください';

  @override
  String get updateDownloading => 'パッケージをダウンロード中…';

  @override
  String get updateVerifying => 'パッケージを検証中…';

  @override
  String get updatePreparing => 'インストールを準備中…';

  @override
  String get updateExiting => '転送を終了しています。インストール後に Tamayura を再び開きます…';

  @override
  String get updateHandedToSystem => 'システムのインストーラーに引き渡しました。システムの案内に従ってください';

  @override
  String get updateDownloadCancelled => 'ダウンロードをキャンセルしました';

  @override
  String get updateInstallIncomplete => 'インストールが完了しませんでした。もう一度お試しください';

  @override
  String get updateInstalled => 'インストールが完了しました。Tamayura を再び開いてください';

  @override
  String get updatePendingUserAction => 'システムのインストール画面でアップデートを確認してください';

  @override
  String updateCurrentVersion(String version) {
    return '現在のバージョン $version';
  }

  @override
  String get updateIncomplete => 'アップデートは完了していません';

  @override
  String get updateCancelDownload => 'ダウンロードをキャンセル';

  @override
  String get updateExitFailedHint =>
      'アプリは共有と転送を停止しました。インストールの完了を再試行できます。それでも失敗する場合は、システムトレイから「Tamayura を終了」を選び、もう一度開いてください。';

  @override
  String get updateRetryInstall => 'インストールを再試行';

  @override
  String get updateCheckAgain => '再確認';

  @override
  String get updateFinishExit => '終了してインストール';

  @override
  String get updateSourceNote =>
      '公開済みのバージョン（プレリリースを含む）を GitHub から取得します。インターネット接続が必要です。';

  @override
  String get updateReleaseNotes => 'リリースノート';

  @override
  String get updateNoReleaseNotes => 'このバージョンにはリリースノートがありません。';

  @override
  String get aboutTitle => 'このアプリについて';

  @override
  String get aboutSummary =>
      'ローカルネットワーク上のデバイス間で写真や動画を閲覧し、必要なときに受け取れます。すてきな瞬間を、いつでも手の届くところに。';

  @override
  String get aboutVersion => 'バージョン';

  @override
  String get aboutReadingVersion => 'バージョンを読み込み中…';

  @override
  String get aboutVersionUnavailable => 'バージョン情報を読み込めません';

  @override
  String get aboutProjectLicense => 'プロジェクトのライセンス';

  @override
  String get aboutThirdPartyLicenses => 'オープンソースライセンス';

  @override
  String get aboutThirdPartyLicensesSubtitle => 'Flutter とオープンソースコミュニティに感謝します';

  @override
  String get aboutMusings => 'ひとりごと';

  @override
  String get aboutMusingsSubtitle => '名前のこと、写真のこと、そして特別なポートのこと';

  @override
  String get licenseIntro =>
      'Tamayura は Apache License 2.0 で公開されています。以下はライセンスの全文です。';

  @override
  String get licenseReading => 'ライセンスを読み込み中…';

  @override
  String get licenseUnavailable => 'ライセンスの本文を読み込めません';

  @override
  String get musingNameTitle => '名前は『たまゆら』から';

  @override
  String get musingNameText =>
      'このプロジェクトの名前は、アニメ『たまゆら』（Tamayura）に由来します。写真を軸に、日常と成長を描いた作品です。写真が好きな沢渡楓が父の故郷である広島県竹原市にやって来て、カメラで身近な風景を写しながら、友だちと一緒に日々の小さな幸せを探していきます。';

  @override
  String get musingMomentsTitle => 'すてきな瞬間を、そばに';

  @override
  String get musingMomentsText =>
      '写真は、うつろいやすい光や風景、笑顔に、もう一度出会える場所をくれます。Tamayura もそのために生まれました。記録したすてきなものが、自分のデバイスの間で気軽に行き来できるように。写真がどのデバイスにあっても、いつでも見返して、取り戻して、大切な人と分かち合えますように。';

  @override
  String get musingPortTitle => '50728、ささやかな記念';

  @override
  String musingPortText(int port) {
    return '沢渡（さわたり）楓（ふう）の誕生日は 1995 年 7 月 28 日。西暦の末尾の「5」と月日の「0728」を合わせて、Tamayura の既定ポート $port になりました。接続のたびに、この作品へのちょっとした愛着が込められています。';
  }

  @override
  String get defaultDeviceName => 'マイデバイス';

  @override
  String get lanDeviceFallback => 'ローカルネットワークのデバイス';

  @override
  String get fallbackFolderName => 'フォルダー';

  @override
  String get spaceLocationDownloadDisk => 'ダウンロード先のディスク';

  @override
  String get spaceLocationStaging => 'ダウンロードの一時フォルダー';

  @override
  String get spaceLocationDestination => '保存先フォルダー';

  @override
  String get errorAppNotReady => 'アプリの初期化が完了していません。しばらくしてからもう一度お試しください';

  @override
  String get errorAppNotReadyTheme => 'アプリの初期化が完了していません。もう一度テーマを切り替えてください';

  @override
  String get errorDeviceOrderSave => 'デバイスの順序を保存できませんでした。もう一度お試しください';

  @override
  String get errorThemeSave => 'テーマの設定を保存できませんでした。もう一度お試しください';

  @override
  String get errorLanguageSave => '言語の設定を保存できませんでした。もう一度お試しください';

  @override
  String get errorDetailedModeSave => 'アルバムの詳細モードの設定を保存できませんでした。もう一度お試しください';

  @override
  String get errorAutoSyncRange => '自動同期の間隔は 1–525600 の整数（分）で入力してください';

  @override
  String get errorAutoSyncSave => '自動同期の間隔を保存できませんでした。もう一度お試しください';

  @override
  String errorStagingCleanup(String error) {
    return 'ダウンロードの一時データの一部を削除できませんでした。タスクの削除を再試行できます。$error';
  }

  @override
  String errorDiscoveryUnavailable(String error) {
    return 'デバイスの検出は現在利用できません。IP を入力して手動で接続できます。$error';
  }

  @override
  String get errorAutoDiscoveryUnavailable =>
      '自動検出は現在利用できません。「デバイス」で手動で接続できます。';

  @override
  String get errorAddressInUse => 'この IP アドレスは別のデバイスが使用しています。デバイスをもう一度検出してください';

  @override
  String get errorOwnAddress => 'これはこのデバイスのアドレスです。別のデバイスのアドレスを入力してください';

  @override
  String get errorFolderAlreadyShared => 'このフォルダーはすでに共有リストにあります';

  @override
  String get errorSharingIdentity => '共有サービスの本人確認に失敗しました';

  @override
  String get errorSharingConfirm => 'バックグラウンド共有の開始を確認できませんでした。もう一度お試しください';

  @override
  String get errorPeerStalled =>
      '相手のデバイスから長時間応答がありません。スリープしているか、ローカルネットワークから離れた可能性があります';

  @override
  String get errorSystemOperation => 'システムの操作に失敗しました。もう一度お試しください';

  @override
  String get errorPeerFileMissing => '相手側のファイルが削除されたか、アクセスできません。アルバムを更新してください';

  @override
  String get errorPeerFolderUnavailable =>
      '相手側の共有フォルダーを利用できません。相手側でフォルダーを選び直してから更新してください';

  @override
  String get errorTransferIncomplete => 'ファイルが完全に転送されませんでした。もう一度お試しください';

  @override
  String get errorPeerUnreachable =>
      '現在このデバイスに接続できません。両方のデバイスが同じローカルネットワークにあり、相手側でアプリが開いていることを確認してください';

  @override
  String get errorNetworkUnavailable =>
      'ローカルネットワークに接続できません。Wi-Fi を確認して、もう一度お試しください';

  @override
  String get errorFileSave => 'ファイルを保存できませんでした。空き容量とフォルダーの権限を確認してください';

  @override
  String errorUnknown(String error) {
    return '操作を完了できませんでした。もう一度お試しください。$error';
  }

  @override
  String get errorFolderOverlap => 'このフォルダーはすでに共有されているか、共有中のフォルダーと親子関係にあります';

  @override
  String get errorFileChanged => 'ファイルのサイズが変わりました。アルバムを更新してください';

  @override
  String get errorScanCancelled => '共有フォルダーが変更されました。もう一度スキャンしてください';

  @override
  String get errorAddressRequired =>
      'ローカルネットワークの IPv4 アドレスを入力するか、Tamayura の QR コードをスキャンしてください';

  @override
  String errorAddressInvalid(int port) {
    return '有効なローカルネットワークの IPv4 アドレスを入力してください（例：192.168.1.8:$port）';
  }

  @override
  String get errorAddressNotPrivate =>
      '現在はローカルネットワークのプライベート IPv4 アドレスのみに対応しています';

  @override
  String get errorPortRange => 'ポートは 1–65535 で指定してください';

  @override
  String get errorVersionUnreadable => 'アプリのバージョン情報を読み込めませんでした。もう一度お試しください';

  @override
  String get errorAppExiting => 'アプリを終了しています。再び開いてからダウンロードを再試行してください';

  @override
  String get errorSharedFolderConfig => '共有フォルダーの設定が無効です。フォルダーを選び直してください';

  @override
  String get errorMediaPath => 'メディアファイルの相対パスが無効です';

  @override
  String get errorMediaFolderPath => 'メディアファイルの共有フォルダーまたは相対パスが無効です';

  @override
  String get errorCatalogChanged => 'メディアの一覧が更新されました。もう一度同期してください';

  @override
  String get errorSharedFoldersChanged => '共有フォルダーが更新されました。しばらくしてからもう一度お試しください';

  @override
  String get errorTaskIdMissing => 'ダウンロードタスクに ID がありません';

  @override
  String get errorAddressOwnedByOther =>
      'このアドレスは別のデバイスのものです。デバイスを再検出してから、もう一度お試しください';

  @override
  String errorSpaceInsufficient(String location) {
    return '$locationの空き容量が不足しています。容量を空けてから、もう一度お試しください';
  }

  @override
  String get errorChunkSize => '受信したファイルの分割データのサイズが正しくありません。更新してから、もう一度お試しください';

  @override
  String get errorChunkIncomplete =>
      'ファイルの分割データが完全に転送されませんでした。再試行してダウンロードを続けてください';

  @override
  String get errorDownloadSizeMismatch =>
      'ダウンロードしたファイルのサイズが一覧の記録と一致しません。更新してから、もう一度お試しください';

  @override
  String get errorDatabaseDirectory =>
      'このデバイスのデータベースフォルダーを利用できません。ユーザーフォルダーの権限を確認して、もう一度お試しください';

  @override
  String get errorTransferTarget => 'メディアのデバイスまたは共有フォルダーが無効です。アルバムを更新してください';

  @override
  String get errorStagingNotCleaned => '一時ファイルがまだ削除されていません。先にタスクの削除を再試行してください';

  @override
  String get errorStagingCleanupFailed => '一時データを削除できませんでした。タスクの削除を再試行してください';

  @override
  String get errorFileDeletedRedownload => 'ファイルは削除されました。もう一度ダウンロードしてください';

  @override
  String get errorTaskInterrupted => 'タスクが中断されました。再試行をタップするとダウンロードを続けます';

  @override
  String get errorCatalogVersion => 'メディア一覧のバージョンが無効です';

  @override
  String get errorCatalogCursor => 'メディア一覧のページ位置が無効です';

  @override
  String get errorCatalogInvalidEntries => '相手側のメディア一覧に無効または重複したファイルが含まれています';

  @override
  String get errorCatalogInvalidEntriesRefresh =>
      '相手側のメディア一覧に無効または重複したファイルが含まれています。更新してから、もう一度お試しください';

  @override
  String get errorCatalogDuplicate => '相手側のメディア一覧に重複したファイルが含まれています。もう一度お試しください';

  @override
  String get errorCatalogCount => '相手側のメディア一覧の件数が一致しません。もう一度お試しください';

  @override
  String get errorCatalogIncomplete =>
      'メディア一覧を最後まで受信できませんでした。既存のオフラインアルバムは変更されていません';

  @override
  String get errorThumbnailTooLarge => 'サムネイルが許容サイズを超えています';

  @override
  String get errorIncompatiblePeer =>
      '相手は互換性のある Tamayura デバイスではありません。両方のアプリのバージョンが同じか確認してください';

  @override
  String get errorPeerPaging => '相手側の一覧のページ情報が無効です。更新してから、もう一度お試しください';

  @override
  String get errorPeerCatalogInvalid =>
      '相手側から返されたメディア一覧が無効です。更新してから、もう一度お試しください';

  @override
  String get errorPeerThumbnail => '相手側のサムネイルが無効です。更新してから、もう一度お試しください';

  @override
  String get errorPeerCatalogCount => '相手側の一覧の件数が一致しません。もう一度お試しください';

  @override
  String get errorPeerCatalogVersion => '相手側の一覧のバージョンが変わりました。もう一度お試しください';

  @override
  String get errorPeerCatalogPageRepeated => '相手側の一覧のページが重複しています。もう一度お試しください';

  @override
  String get errorChunkInvalid => '受信したファイルの分割データが正しくありません。もう一度ダウンロードしてください';

  @override
  String get errorTransferEnded => 'ファイルの転送が途中で終了しました。もう一度ダウンロードしてください';

  @override
  String get errorSharingStatus => 'バックグラウンド共有の状態を読み込めませんでした。もう一度お試しください';

  @override
  String get errorStagingUnavailable => 'ダウンロードの一時フォルダーを利用できません';

  @override
  String get errorSaveFailed => 'ファイルを保存できませんでした';

  @override
  String get errorCacheUnavailable => '一時フォルダーを利用できません';

  @override
  String errorDeviceId(String platform) {
    return '$platform のデバイス識別子を読み込めませんでした。アプリを再起動して、もう一度お試しください';
  }

  @override
  String errorPlatformUnsupported(String platform) {
    return '$platform にはまだ対応していません';
  }

  @override
  String get updateErrorCancelled => 'アップデートのダウンロードをキャンセルしました';

  @override
  String get updateErrorCurrentVersion =>
      '現在のアプリのバージョンを識別できません。正式リリースのパッケージを再インストールしてください';

  @override
  String get updateErrorReleaseList =>
      'GitHub のバージョン一覧の形式が正しくありません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorPageUrl => 'アップデートページのアドレスが無効です。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorNotes => 'リリースノートの形式が正しくありません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorListTooLong =>
      'バージョン一覧が長すぎるため、最新バージョンを確認できません。GitHub で確認してください';

  @override
  String get updateErrorManifest => '新しいバージョンのアップデートマニフェストが無効なため、自動アップデートできません';

  @override
  String get updateErrorManifestMismatch => '新しいバージョンのアップデートマニフェストがリリースと一致しません';

  @override
  String get updateErrorAndroidBuild =>
      '新しいバージョンの Android ビルド番号が無効なため、上書きインストールできません';

  @override
  String get updateErrorPackageInfo =>
      '新しいバージョンに、このプラットフォーム向けの有効なパッケージ情報がありません';

  @override
  String get updateErrorArchitecture => '新しいバージョンのパッケージのアーキテクチャには対応していません';

  @override
  String get updateErrorPackageSize => '新しいバージョンのパッケージサイズがアップデートマニフェストと一致しません';

  @override
  String get updateErrorInvalidPackage => 'パッケージ情報が無効です。もう一度アップデートを確認してください';

  @override
  String get updateErrorDownloadSize =>
      'ダウンロードしたパッケージのサイズがアップデートマニフェストと一致しません。もう一度お試しください';

  @override
  String get updateErrorDownloadTooLarge =>
      'ダウンロードしたパッケージがアップデートマニフェストのサイズを超えています。もう一度お試しください';

  @override
  String get updateErrorChecksum => 'パッケージの整合性チェックに失敗しました。もう一度ダウンロードしてください';

  @override
  String get updateErrorBusy => '別のアップデート操作を実行中です。しばらくお待ちください';

  @override
  String get updateErrorTimeout =>
      'GitHub への接続またはパッケージのダウンロードがタイムアウトしました。ネットワークを確認して、もう一度お試しください';

  @override
  String get updateErrorConnect => 'GitHub に接続できません。ネットワークを確認して、もう一度お試しください';

  @override
  String get updateErrorConnectionLost =>
      'GitHub との接続が中断されました。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorStorage =>
      'アップデートパッケージを保存できません。空き容量とフォルダーの権限を確認して、もう一度お試しください';

  @override
  String get updateErrorFormat => 'アップデート情報の形式が正しくありません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorResponseTooLarge =>
      'アップデート情報が許容サイズを超えています。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorRedirect =>
      'GitHub のダウンロードアドレスのリダイレクトが正しくありません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorForbidden =>
      'GitHub がアクセスを拒否したか、リクエストが多すぎます。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorUnavailable =>
      'GitHub のアップデート情報またはパッケージを一時的に利用できません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorEncoding =>
      'GitHub が未対応のダウンロード形式を返しました。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorUntrustedUrl =>
      'アップデートのダウンロードアドレスが信頼できないため、アップデートを中止しました';

  @override
  String get updateErrorNoAssets => '新しいバージョンにリリースファイルがないため、自動アップデートできません';

  @override
  String get updateErrorAmbiguousAssets =>
      '新しいバージョンに一意で完全なリリースファイルがないため、自動アップデートできません';

  @override
  String get updateErrorAssetsPending =>
      '新しいバージョンのリリースファイルのアップロードが完了していません。しばらくしてからもう一度お試しください';

  @override
  String get updateErrorAssetUrl => 'アップデートファイルのアドレスがリリースと一致しません';

  @override
  String get updateErrorPlatform => 'このプラットフォームはアプリのアップデートにまだ対応していません';

  @override
  String get updateErrorStagingDirectory =>
      'アップデートの一時フォルダーを作成できません。ディスクの空き容量を確認して、もう一度お試しください';

  @override
  String get updateErrorInstallInfo => 'このバージョンには有効なインストール情報がありません';

  @override
  String get updateErrorInstallStart => 'インストールが開始されたか確認できませんでした。もう一度お試しください';

  @override
  String get updateErrorReleaseUrl => 'アップデートページのアドレスが無効です';
}
