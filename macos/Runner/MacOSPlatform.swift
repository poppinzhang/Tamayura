import Cocoa
import FlutterMacOS

final class SharingEvents: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private let key = "tamayura.backgroundSharing"
  var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
  var status: [String: Any] { ["enabled": enabled, "running": enabled, "batteryExempt": true] }
  func setEnabled(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: key)
    sink?(status)
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; events(status); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}

final class MacOSPlatform: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  private let bookmarks: DirectoryBookmarks
  private let media: MediaCatalog
  private let discovery = LanDiscovery()
  private let activity = NetworkActivity()
  private let sharing = SharingEvents()
  private let workers = DispatchQueue(label: "dev.tamayura.platform", qos: .userInitiated, attributes: .concurrent)
  private weak var viewController: FlutterViewController?
  private var channels: [Any] = []
  private var directoryPicker: NSOpenPanel?
  private var sharePicker: NSSharingServicePicker?
  private var shareAccess: AuthorizedFile?

  init(viewController: FlutterViewController) {
    self.viewController = viewController
    bookmarks = DirectoryBookmarks()
    media = MediaCatalog(access: bookmarks)
    super.init()
    let messenger = viewController.engine.binaryMessenger
    let methods = FlutterMethodChannel(name: "tamayura/platform", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "APP_CLOSED", message: "应用已退出", details: nil)); return }
      self.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: "tamayura/discovery", binaryMessenger: messenger)
    events.setStreamHandler(discovery)
    let sharingEvents = FlutterEventChannel(name: "tamayura/sharing", binaryMessenger: messenger)
    sharingEvents.setStreamHandler(sharing)
    channels = [methods, events, sharingEvents]
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    func string(_ key: String) throws -> String {
      guard let value = args[key] as? String, !value.isEmpty else { throw PlatformFailure.invalid("缺少 \(key)") }
      return value
    }
    func strings(_ key: String) throws -> [String] {
      guard let value = args[key] as? [String] else { throw PlatformFailure.invalid("缺少 \(key)") }
      return value
    }
    do {
      switch call.method {
      case "pickDirectory": try pickDirectory(result)
      case "validateSharedDirectory":
        let uri = try string("uri"), existing = try strings("existingUris")
        background(result) { try self.media.validate(uri, existing: existing); return nil }
      case "scanDirectoriesMetadata":
        let generation = media.clear()
        guard let values = args["directories"] as? [[String: String]] else { throw PlatformFailure.invalid("缺少共享目录") }
        let directories = try values.map { value -> SharedDirectory in
          guard let id = value["id"], let uri = value["uri"], let name = value["name"] else {
            throw PlatformFailure.invalid("共享目录配置无效")
          }
          return SharedDirectory(id: id, uri: uri, name: name)
        }
        background(result) {
          // The first scan precedes gRPC/discovery startup, so it needs its own
          // bounded activity before the service's long-lived activity exists.
          let process = ProcessInfo.processInfo
          let token = process.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                            reason: "Tamayura shared media scan")
          defer { process.endActivity(token) }
          return try self.media.scan(directories, expected: generation)
        }
      case "clearSharedDirectory": media.clear(); result(nil)
      case "thumbnail":
        let id = try string("id")
        background(result) {
          try self.media.withMedia(id) { entry, file in
            // Unsupported media still has metadata; only its thumbnail is empty.
            let bytes = (try? MediaPreview.jpeg(file: file, video: entry.mimeType.hasPrefix("video/"), maximum: 256, mimeType: entry.mimeType)) ?? Data()
            return FlutterStandardTypedData(bytes: bytes)
          }
        }
      case "readRange":
        let id = try string("id")
        guard let offset = args["offset"] as? Int64, let length = args["length"] as? Int else {
          throw PlatformFailure.invalid("缺少文件分块范围")
        }
        background(result) { FlutterStandardTypedData(bytes: try self.media.read(id, offset: offset, length: length)) }
      case "readPreview":
        let uri = try string("uri")
        let maximum = args["maxDimension"] as? Int ?? 2560
        background(result) {
          try self.bookmarks.withFile(uri) { _, file in
            FlutterStandardTypedData(bytes: try MediaPreview.jpeg(file: file, video: false, maximum: maximum))
          }
        }
      case "saveDownload":
        let source = try string("sourcePath"), uri = try string("directoryUri"), name = try string("name")
        let directories = try strings("directories")
        background(result) {
          try self.bookmarks.withDirectory(uri) { root in
            let saved = try DownloadWriter.save(source: URL(fileURLWithPath: source),
              allowedRoots: [self.cacheDirectory(), self.transferDirectory()], destination: root,
              directories: directories, name: name)
            // Preserve the original bookmark URI so downloaded-file access also
            // survives moving its selected directory between app launches.
            let original = try StoragePaths.fileURL(uri)
            let relative = try StoragePaths.relative(saved, root: root)
            return relative.reduce(original) { $0.appendingPathComponent($1) }.absoluteString
          }
        }
      case "temporaryDirectory": result(try cacheDirectory().path)
      case "transferDirectory": result(try transferDirectory().path)
      case "deviceId":
        let key = "tamayura.deviceId"
        if let id = UserDefaults.standard.string(forKey: key),
           id.range(of: "^macos-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", options: .regularExpression) != nil {
          result(id)
        } else {
          let id = "macos-\(UUID().uuidString.lowercased())"
          UserDefaults.standard.set(id, forKey: key)
          result(id)
        }
      case "localInfo": background(result) { LanDiscovery.localInfo() }
      case "sharingStatus": result(sharing.status)
      case "setBackgroundSharing":
        guard let enabled = args["enabled"] as? Bool else { throw PlatformFailure.invalid("缺少共享状态") }
        sharing.setEnabled(enabled); result(sharing.status)
      case "setTransferActivity":
        let taskID = try string("taskId")
        guard let active = args["active"] as? Bool else { throw PlatformFailure.invalid("缺少下载活动状态") }
        activity.setTransferActive(taskID, active: active)
        result(nil)
      case "startDiscovery":
        guard let port = args["port"] as? Int else { throw PlatformFailure.invalid("缺少服务端口") }
        try discovery.start(id: string("id"), name: string("name"), port: port)
        // Discovery is started/stopped together with the Dart gRPC listener.
        // Protect visible-but-unfocused sharing as well as background sharing.
        activity.setSharingActive(true)
        result(nil)
      case "stopDiscovery":
        discovery.stop()
        activity.setSharingActive(false)
        result(nil)
      case "open", "share": try launch(try string("uri"), share: call.method == "share", result: result)
      default: result(FlutterMethodNotImplemented)
      }
    } catch { report(error, result: result) }
  }

  private func cacheDirectory() throws -> URL {
    try privateDirectory(.cachesDirectory, suffix: "media")
  }
  private func transferDirectory() throws -> URL {
    try privateDirectory(.applicationSupportDirectory, suffix: "transfers")
  }
  private func privateDirectory(_ kind: FileManager.SearchPathDirectory, suffix: String) throws -> URL {
    let directory = try FileManager.default.url(for: kind, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("dev.tamayura.app", isDirectory: true).appendingPathComponent(suffix, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
  }

  private func pickDirectory(_ result: @escaping FlutterResult) throws {
    guard directoryPicker == nil else { throw PlatformFailure.invalid("目录选择器已打开") }
    guard let window = viewController?.view.window else { throw PlatformFailure.invalid("请先打开应用窗口") }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择目录"
    panel.message = "选择要共享或接收媒体文件的目录"
    directoryPicker = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { result(FlutterError(code: "APP_CLOSED", message: "应用已退出", details: nil)); return }
      self.directoryPicker = nil
      guard response == .OK, let url = panel.url else { result(nil); return }
      do { result(["uri": try self.bookmarks.remember(url), "name": url.lastPathComponent]) }
      catch { self.report(error, result: result) }
    }
  }

  private func launch(_ uri: String, share: Bool, result: @escaping FlutterResult) throws {
    let access = try bookmarks.fileAccess(uri)
    if share {
      guard shareAccess == nil else { throw PlatformFailure.invalid("请先完成当前分享") }
      guard let view = viewController?.view else { throw PlatformFailure.invalid("请先打开应用窗口") }
      let picker = NSSharingServicePicker(items: [access.url])
      shareAccess = access
      sharePicker = picker
      picker.delegate = self
      picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
      result(nil)
    } else {
      NSWorkspace.shared.open(access.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        withExtendedLifetime(access) {
          DispatchQueue.main.async {
            if let error { self.report(error, result: result) } else { result(nil) }
          }
        }
      }
    }
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
    if service == nil { releaseShare() }
  }
  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                            delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { releaseShare() }
  func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { releaseShare() }
  private func releaseShare() { sharePicker = nil; shareAccess = nil }

  private func background(_ result: @escaping FlutterResult, operation: @escaping () throws -> Any?) {
    workers.async {
      do {
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch { DispatchQueue.main.async { self.report(error, result: result) } }
    }
  }
  private func report(_ error: Error, result: FlutterResult) {
    if let failure = error as? PlatformFailure {
      result(FlutterError(code: failure.code, message: failure.message, details: nil))
    } else {
      let ns = error as NSError
      let code = ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code)
        ? "PERMISSION_LOST" : "PLATFORM_ERROR"
      result(FlutterError(code: code, message: error.localizedDescription, details: nil))
    }
  }
}
