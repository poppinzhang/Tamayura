import Foundation

/// Native text in the interface language chosen in Tamayura. Dart sends the
/// preference (`system`, `zh`, `ja` or `en`); `system` resolves as in Dart:
/// the first supported preferred language, otherwise English.
enum AppText {
  static let system = "system"
  static let supported = ["zh", "ja", "en"]
  /// Posted on the main thread after the preference changes.
  static let didChange = Notification.Name("dev.tamayura.languageDidChange")
  /// Replaceable so tests keep the preference out of the user's defaults.
  static var defaults = UserDefaults.standard
  private static let key = "tamayura.language"

  enum Key: CaseIterable {
    case appName, statusTitle, statusTooltip, openApp, quitApp
    case choosePrompt, chooseMessage, appClosed, openWindowFirst, pickerOpen, shareInProgress
    case missingArgument, missingDirectories, invalidDirectoryConfig, missingRange, missingSize
    case missingSharingState, missingTransferActivity, missingPort, invalidLanguage
    case invalidReleaseUrl, openReleaseFailed
    case invalidDiscoveryArguments, discoveryFailed
    case permissionLost, permissionRestoreFailed, fileOutsideGrant
    case previewRange, videoThumbnailTimeout, cannotDecode, cannotCreatePreview, cannotEncodePreview
    case cannotScalePreview, previewTooLarge, invalidVideoRange, videoThumbnailUnreadable
    case invalidMediaName, invalidRelativePath, driveLetterPath, fileOutsideAuthorizedDirectory
    case localFileUriRequired, cannotAccess, cannotCreateSubdirectory, emptyPath, cannotReadDeletion
    case onlyRegularFiles, cannotDelete, cannotReadMediaInfo, mediaMissing, invalidRange, fileChanged
    case fileEnded, scanCancelled, directoryOverlap, duplicateDirectoryId, cannotReadSharedDirectory
    case fileNotShared, partsInvalid, sourceLocation, partsSize, cannotCreateFile, cannotReadStaging
    case partsChanged, cannotSaveSpace, cannotFinishSave
  }

  static var language: String {
    guard let value = defaults.string(forKey: key), value == system || supported.contains(value) else {
      return system
    }
    return value
  }

  static func setLanguage(_ value: String) -> Bool {
    guard value == system || supported.contains(value) else { return false }
    defaults.set(value, forKey: key)
    return true
  }

  static func resolve(_ language: String, preferred: [String]) -> String {
    if supported.contains(language) { return language }
    for identifier in preferred {
      if let code = Locale.Language(identifier: identifier).languageCode?.identifier,
         supported.contains(code) {
        return code
      }
    }
    return "en"
  }

  static var current: String { resolve(language, preferred: Locale.preferredLanguages) }

  static func text(_ key: Key, _ arguments: CVarArg...) -> String {
    let format = table[current]?[key] ?? table["en"]![key]!
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
  }

  static let table: [String: [Key: String]] = [
    "zh": [
      .appName: "玉响",
      .statusTitle: "玉",
      .statusTooltip: "玉响 · 关闭窗口后继续在后台运行",
      .openApp: "打开玉响",
      .quitApp: "退出玉响",
      .choosePrompt: "选择目录",
      .chooseMessage: "选择要共享或接收媒体文件的目录",
      .appClosed: "应用已退出",
      .openWindowFirst: "请先打开应用窗口",
      .pickerOpen: "目录选择器已打开",
      .shareInProgress: "请先完成当前分享",
      .missingArgument: "缺少 %@",
      .missingDirectories: "缺少共享目录",
      .invalidDirectoryConfig: "共享目录配置无效",
      .missingRange: "缺少文件分块范围",
      .missingSize: "缺少下载大小",
      .missingSharingState: "缺少共享状态",
      .missingTransferActivity: "缺少下载活动状态",
      .missingPort: "缺少服务端口",
      .invalidLanguage: "不支持的界面语言",
      .invalidReleaseUrl: "更新页面地址无效",
      .openReleaseFailed: "无法打开更新页面，请检查默认浏览器后重试",
      .invalidDiscoveryArguments: "无效的设备 ID 或服务端口",
      .discoveryFailed: "局域网发现失败，请检查系统设置中的本地网络权限；也可使用手动连接",
      .permissionLost: "目录授权已失效，请重新选择目录",
      .permissionRestoreFailed: "无法恢复目录授权，请重新选择目录",
      .fileOutsideGrant: "文件不在已授权目录中，请重新选择接收目录",
      .previewRange: "预览尺寸必须在 1 至 2560 之间",
      .videoThumbnailTimeout: "视频缩略图生成超时",
      .cannotDecode: "无法解码此媒体文件",
      .cannotCreatePreview: "无法生成预览",
      .cannotEncodePreview: "无法编码预览",
      .cannotScalePreview: "无法缩小预览",
      .previewTooLarge: "预览图过大",
      .invalidVideoRange: "无效的视频读取范围",
      .videoThumbnailUnreadable: "无法读取视频缩略图",
      .invalidMediaName: "媒体目录或文件名称无效",
      .invalidRelativePath: "媒体相对路径无效",
      .driveLetterPath: "媒体相对路径不能使用盘符",
      .fileOutsideAuthorizedDirectory: "文件不在授权目录中",
      .localFileUriRequired: "需要本机文件 URI",
      .cannotAccess: "无法访问文件或目录，请检查授权和路径",
      .cannotCreateSubdirectory: "无法创建接收子目录",
      .emptyPath: "文件路径为空",
      .cannotReadDeletion: "无法读取待删除的本地文件",
      .onlyRegularFiles: "只能删除本地普通文件",
      .cannotDelete: "无法删除本地文件，请检查目录权限",
      .cannotReadMediaInfo: "无法读取媒体文件信息",
      .mediaMissing: "媒体文件不存在或不是普通文件",
      .invalidRange: "无效的文件分块范围",
      .fileChanged: "文件大小已改变，请刷新相册",
      .fileEnded: "文件提前结束，请刷新相册",
      .scanCancelled: "共享目录已改变，请重新扫描",
      .directoryOverlap: "共享目录不能重复或互相包含",
      .duplicateDirectoryId: "共享目录标识重复",
      .cannotReadSharedDirectory: "无法读取共享目录",
      .fileNotShared: "文件未被共享，请刷新相册",
      .partsInvalid: "下载分片或大小无效",
      .sourceLocation: "下载源文件必须在应用私有目录中",
      .partsSize: "下载分片大小与预期不符",
      .cannotCreateFile: "无法创建接收文件",
      .cannotReadStaging: "无法读取下载暂存文件",
      .partsChanged: "下载分片在保存时已变化",
      .cannotSaveSpace: "无法保存下载文件，可能磁盘空间不足",
      .cannotFinishSave: "无法完成文件保存",
    ],
    "ja": [
      .appName: "Tamayura",
      .statusTitle: "T",
      .statusTooltip: "Tamayura · ウィンドウを閉じてもバックグラウンドで動作します",
      .openApp: "Tamayura を開く",
      .quitApp: "Tamayura を終了",
      .choosePrompt: "フォルダーを選択",
      .chooseMessage: "メディアファイルを共有または受信するフォルダーを選んでください",
      .appClosed: "アプリは終了しました",
      .openWindowFirst: "先にアプリのウィンドウを開いてください",
      .pickerOpen: "フォルダーの選択画面はすでに開いています",
      .shareInProgress: "先に現在の共有を完了してください",
      .missingArgument: "%@ がありません",
      .missingDirectories: "共有フォルダーがありません",
      .invalidDirectoryConfig: "共有フォルダーの設定が無効です",
      .missingRange: "ファイルの分割範囲がありません",
      .missingSize: "ダウンロードのサイズがありません",
      .missingSharingState: "共有の状態がありません",
      .missingTransferActivity: "ダウンロードの動作状態がありません",
      .missingPort: "サービスのポートがありません",
      .invalidLanguage: "対応していない表示言語です",
      .invalidReleaseUrl: "アップデートページのアドレスが無効です",
      .openReleaseFailed: "アップデートページを開けません。既定のブラウザーを確認して、もう一度お試しください",
      .invalidDiscoveryArguments: "デバイス ID またはサービスのポートが無効です",
      .discoveryFailed: "ローカルネットワークの検出に失敗しました。システム設定のローカルネットワークの許可を確認するか、手動で接続してください",
      .permissionLost: "フォルダーへのアクセス許可が失効しました。フォルダーを選び直してください",
      .permissionRestoreFailed: "フォルダーへのアクセス許可を復元できません。フォルダーを選び直してください",
      .fileOutsideGrant: "ファイルが許可されたフォルダーにありません。保存先フォルダーを選び直してください",
      .previewRange: "プレビューのサイズは 1–2560 で指定してください",
      .videoThumbnailTimeout: "動画のサムネイル作成がタイムアウトしました",
      .cannotDecode: "このメディアファイルをデコードできません",
      .cannotCreatePreview: "プレビューを作成できません",
      .cannotEncodePreview: "プレビューをエンコードできません",
      .cannotScalePreview: "プレビューを縮小できません",
      .previewTooLarge: "プレビュー画像が大きすぎます",
      .invalidVideoRange: "動画の読み込み範囲が無効です",
      .videoThumbnailUnreadable: "動画のサムネイルを読み込めません",
      .invalidMediaName: "メディアのフォルダー名またはファイル名が無効です",
      .invalidRelativePath: "メディアの相対パスが無効です",
      .driveLetterPath: "メディアの相対パスにドライブ文字は使えません",
      .fileOutsideAuthorizedDirectory: "ファイルが許可されたフォルダーにありません",
      .localFileUriRequired: "このデバイスのファイル URI が必要です",
      .cannotAccess: "ファイルまたはフォルダーにアクセスできません。許可とパスを確認してください",
      .cannotCreateSubdirectory: "保存先のサブフォルダーを作成できません",
      .emptyPath: "ファイルのパスが空です",
      .cannotReadDeletion: "削除するローカルファイルを読み込めません",
      .onlyRegularFiles: "削除できるのはローカルの通常ファイルのみです",
      .cannotDelete: "ローカルファイルを削除できません。フォルダーの権限を確認してください",
      .cannotReadMediaInfo: "メディアファイルの情報を読み込めません",
      .mediaMissing: "メディアファイルが存在しないか、通常ファイルではありません",
      .invalidRange: "ファイルの分割範囲が無効です",
      .fileChanged: "ファイルのサイズが変わりました。アルバムを更新してください",
      .fileEnded: "ファイルが途中で終わっています。アルバムを更新してください",
      .scanCancelled: "共有フォルダーが変更されました。もう一度スキャンしてください",
      .directoryOverlap: "共有フォルダーは重複したり、互いに含んだりできません",
      .duplicateDirectoryId: "共有フォルダーの識別子が重複しています",
      .cannotReadSharedDirectory: "共有フォルダーを読み込めません",
      .fileNotShared: "ファイルは共有されていません。アルバムを更新してください",
      .partsInvalid: "ダウンロードの分割データまたはサイズが無効です",
      .sourceLocation: "ダウンロード元のファイルはアプリのプライベートフォルダーにある必要があります",
      .partsSize: "ダウンロードの分割データのサイズが想定と一致しません",
      .cannotCreateFile: "保存先のファイルを作成できません",
      .cannotReadStaging: "ダウンロードの一時ファイルを読み込めません",
      .partsChanged: "保存中にダウンロードの分割データが変わりました",
      .cannotSaveSpace: "ダウンロードしたファイルを保存できません。ディスクの空き容量が不足している可能性があります",
      .cannotFinishSave: "ファイルの保存を完了できません",
    ],
    "en": [
      .appName: "Tamayura",
      .statusTitle: "T",
      .statusTooltip: "Tamayura · Keeps running in the background after the window closes",
      .openApp: "Open Tamayura",
      .quitApp: "Quit Tamayura",
      .choosePrompt: "Choose Folder",
      .chooseMessage: "Choose a folder to share media from or receive media into",
      .appClosed: "The app has quit",
      .openWindowFirst: "Open the app window first",
      .pickerOpen: "The folder picker is already open",
      .shareInProgress: "Finish the current share first",
      .missingArgument: "Missing %@",
      .missingDirectories: "Missing shared folders",
      .invalidDirectoryConfig: "Invalid shared folder settings",
      .missingRange: "Missing file chunk range",
      .missingSize: "Missing download size",
      .missingSharingState: "Missing sharing state",
      .missingTransferActivity: "Missing download activity state",
      .missingPort: "Missing service port",
      .invalidLanguage: "Unsupported interface language",
      .invalidReleaseUrl: "The update page address is invalid",
      .openReleaseFailed: "Can't open the update page. Check your default browser and try again.",
      .invalidDiscoveryArguments: "Invalid device ID or service port",
      .discoveryFailed: "Local network discovery failed. Check Local Network access in System Settings, or connect manually.",
      .permissionLost: "Folder access has expired. Choose the folder again.",
      .permissionRestoreFailed: "Can't restore folder access. Choose the folder again.",
      .fileOutsideGrant: "The file isn't in an authorized folder. Choose the download folder again.",
      .previewRange: "The preview size must be from 1 to 2560",
      .videoThumbnailTimeout: "Creating the video thumbnail timed out",
      .cannotDecode: "Can't decode this media file",
      .cannotCreatePreview: "Can't create a preview",
      .cannotEncodePreview: "Can't encode the preview",
      .cannotScalePreview: "Can't scale down the preview",
      .previewTooLarge: "The preview image is too large",
      .invalidVideoRange: "Invalid video read range",
      .videoThumbnailUnreadable: "Can't read the video thumbnail",
      .invalidMediaName: "Invalid media folder or file name",
      .invalidRelativePath: "Invalid media relative path",
      .driveLetterPath: "Media relative paths can't use drive letters",
      .fileOutsideAuthorizedDirectory: "The file isn't in an authorized folder",
      .localFileUriRequired: "A local file URI is required",
      .cannotAccess: "Can't access the file or folder. Check permissions and the path.",
      .cannotCreateSubdirectory: "Can't create the download subfolder",
      .emptyPath: "The file path is empty",
      .cannotReadDeletion: "Can't read the local file to delete",
      .onlyRegularFiles: "Only regular local files can be deleted",
      .cannotDelete: "Can't delete the local file. Check folder permissions.",
      .cannotReadMediaInfo: "Can't read the media file information",
      .mediaMissing: "The media file doesn't exist or isn't a regular file",
      .invalidRange: "Invalid file chunk range",
      .fileChanged: "The file size changed. Refresh the album.",
      .fileEnded: "The file ended early. Refresh the album.",
      .scanCancelled: "Shared folders changed. Scan again.",
      .directoryOverlap: "Shared folders can't repeat or contain each other",
      .duplicateDirectoryId: "Shared folder identifiers are duplicated",
      .cannotReadSharedDirectory: "Can't read the shared folder",
      .fileNotShared: "The file isn't shared. Refresh the album.",
      .partsInvalid: "Invalid download parts or size",
      .sourceLocation: "Download source files must be in the app's private folder",
      .partsSize: "The download parts don't match the expected size",
      .cannotCreateFile: "Can't create the download file",
      .cannotReadStaging: "Can't read the staged download file",
      .partsChanged: "The download parts changed while saving",
      .cannotSaveSpace: "Can't save the downloaded file. The disk may be full.",
      .cannotFinishSave: "Can't finish saving the file",
    ],
  ]
}
