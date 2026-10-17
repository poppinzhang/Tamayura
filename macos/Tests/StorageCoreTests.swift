import Foundation
import AppKit
import AVFoundation
import ImageIO

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw TestFailure(message: message) }
}
private func rejects(_ message: String, code: String? = nil, _ operation: () throws -> Void) throws {
  do { try operation() }
  catch {
    if let code { try expect((error as? PlatformFailure)?.code == code, "\(message): wrong error \(error)") }
    return
  }
  throw TestFailure(message: "Expected rejection: \(message)")
}
private final class TestAccess: DirectoryAccess {
  var roots: [String: URL] = [:]
  func withDirectory<T>(_ uri: String, _ operation: (URL) throws -> T) throws -> T {
    guard let root = roots[uri] else { throw PlatformFailure(code: "PERMISSION_LOST", message: "Revoked") }
    return try operation(root)
  }
}

@main
struct StorageCoreTests {
  static func main() throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("tamayura-native-\(UUID())").resolvingSymlinksInPath()
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
      try body(); passed += 1; print("PASS \(name)")
    }
    func directory(_ name: String) throws -> URL {
      let path = temporary.appendingPathComponent(name)
      try fm.createDirectory(at: path, withIntermediateDirectories: true)
      return path
    }
    let root = try directory("photos"), destination = try directory("downloads"), staging = try directory("staging")
    let nested = root.appendingPathComponent("旅行")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let photo = nested.appendingPathComponent("a.jpg")
    let bytes = Data((0..<1000).map { UInt8($0 % 251) })
    try bytes.write(to: photo)
    try Data("text".utf8).write(to: root.appendingPathComponent("ignore.txt"))
    let access = TestAccess(); access.roots["chosen"] = root
    let catalog = MediaCatalog(access: access)
    let shared = SharedDirectory(id: "folder-one", uri: "chosen", name: "照片")
    var id = ""
    try test("reject unsafe paths and remote file URIs") {
      for name in ["", ".", "..", "a/b", "a\\b", "\u{0}", "\n", "\u{7f}"] {
        try rejects("segment \(name)") { try StoragePaths.segment(name) }
      }
      for path in ["C:drive.jpg", "/absolute", "../file", "a//file", "a/../file", "a/"] {
        try rejects("path \(path)") { _ = try StoragePaths.components(path) }
      }
      try rejects("remote URI") { _ = try StoragePaths.fileURL("file://other-host/a") }
      try rejects("content URI") { _ = try StoragePaths.fileURL("content://provider/a") }
      try StoragePaths.segment("旅行 图片.jpg")
    }
    try test("overlap compares components instead of string prefixes") {
      try expect(StoragePaths.overlap(root, nested), "nested root")
      try expect(!StoragePaths.overlap(root, temporary.appendingPathComponent("photos-other")), "sibling root")
      access.roots["nested"] = nested
      try rejects("overlap", code: "DIR_OVERLAP") { try catalog.validate("nested", existing: ["chosen"]) }
    }
    try test("scan recursive image metadata and stable opaque IDs") {
      let metadata = try catalog.scan([shared], expected: catalog.clear())
      try expect(metadata.count == 1, "only images and videos")
      id = metadata[0]["id"] as! String
      try expect(id.count == 64, "SHA256 id")
      try expect(metadata[0]["relativePath"] as? String == "旅行/a.jpg", "relative nesting")
      try expect(metadata[0]["sharedFolderName"] as? String == "照片", "folder label")
      try expect(metadata[0]["mimeType"] as? String == "image/jpeg", "MIME")
      try expect(metadata[0]["size"] as? Int64 == 1000, "size")
      let again = try catalog.scan([shared], expected: catalog.clear())
      try expect(again[0]["id"] as? String == id, "stable id")
    }
    try test("macOS names containing colons preserve metadata and readable IDs") {
      let colon = nested.appendingPathComponent("IMG 12:30.jpg")
      try bytes.write(to: colon)
      let entries = try catalog.scan([shared], expected: catalog.clear())
      let entry = entries.first { ($0["name"] as? String) == "IMG 12:30.jpg" }!
      try expect(entry["relativePath"] as? String == "旅行/IMG 12:30.jpg", "colon relative path")
      try expect(catalog.read(entry["id"] as! String, offset: 0, length: 1000) == bytes, "colon file read")
      try fm.removeItem(at: colon)
      _ = try catalog.scan([shared], expected: catalog.clear())
    }
    try test("scan skips unreadable files and subfolders and names peers cannot store") {
      let unreadable = root.appendingPathComponent("private.jpg")
      let blocked = root.appendingPathComponent("blocked")
      let backslash = root.appendingPathComponent("a\\b.jpg")
      let control = root.appendingPathComponent("bad\u{1}name.jpg")
      try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
      for file in [unreadable, blocked.appendingPathComponent("inside.jpg"), backslash, control] {
        try bytes.write(to: file)
      }
      func permissions(_ value: Int, _ url: URL) throws {
        try fm.setAttributes([.posixPermissions: value], ofItemAtPath: url.path)
      }
      defer {
        try? permissions(0o755, blocked); try? permissions(0o644, unreadable)
      }
      try permissions(0o000, unreadable); try permissions(0o000, blocked)
      let entries = try catalog.scan([shared], expected: catalog.clear())
      try expect(entries.map { $0["relativePath"] as? String } == ["旅行/a.jpg"], "only readable, storable media: \(entries)")
      try expect(catalog.read(id, offset: 0, length: 10) == bytes.subdata(in: 0..<10), "readable media is served")
      try permissions(0o644, unreadable); try permissions(0o755, blocked)
      let released = try catalog.scan([shared], expected: catalog.clear())
      try expect(Set(released.compactMap { $0["relativePath"] as? String }) ==
        ["旅行/a.jpg", "private.jpg", "blocked/inside.jpg"], "readable again: \(released)")
      for item in [unreadable, blocked, backslash, control] { try fm.removeItem(at: item) }
      access.roots["missing"] = root.appendingPathComponent("missing-root")
      try rejects("missing shared folder", code: "FILE_NOT_FOUND") {
        _ = try catalog.scan([SharedDirectory(id: "gone", uri: "missing", name: "Gone")], expected: catalog.clear())
      }
      access.roots.removeValue(forKey: "missing")
      _ = try catalog.scan([shared], expected: catalog.clear())
    }
    try test("range boundaries, partial tails, invalid limits and changed files") {
      try expect(catalog.read(id, offset: 10, length: 20) == bytes.subdata(in: 10..<30), "range data")
      try expect(catalog.read(id, offset: 990, length: 20) == bytes.subdata(in: 990..<1000), "tail")
      try expect(catalog.read(id, offset: 1000, length: 1).isEmpty, "EOF")
      try rejects("negative", code: "INVALID_ARGUMENT") { _ = try catalog.read(id, offset: -1, length: 2) }
      try rejects("past EOF", code: "INVALID_ARGUMENT") { _ = try catalog.read(id, offset: 1001, length: 0) }
      try rejects("oversized", code: "INVALID_ARGUMENT") { _ = try catalog.read(id, offset: 0, length: 262145) }
      try rejects("unknown ID", code: "FILE_NOT_FOUND") { _ = try catalog.read("unknown", offset: 0, length: 1) }
      try Data([1]).write(to: photo)
      try rejects("changed", code: "FILE_CHANGED") { _ = try catalog.read(id, offset: 0, length: 1) }
      try bytes.write(to: photo)
    }
    try test("scan cancellation and failed refresh revoke the previous snapshot") {
      let old = catalog.clear(); _ = catalog.clear()
      try rejects("old generation", code: "SCAN_CANCELLED") { _ = try catalog.scan([shared], expected: old) }
      _ = try catalog.scan([shared], expected: catalog.clear())
      try rejects("read crossing revocation", code: "SCAN_CANCELLED") {
        _ = try catalog.withMedia(id) { _, _ in catalog.clear(); return Data() }
      }
      _ = try catalog.scan([shared], expected: catalog.clear())
      let generation = catalog.clear(); access.roots.removeValue(forKey: "chosen")
      try rejects("revoked scan", code: "PERMISSION_LOST") { _ = try catalog.scan([shared], expected: generation) }
      try rejects("stale ID", code: "FILE_NOT_FOUND") { _ = try catalog.read(id, offset: 0, length: 1) }
      access.roots["chosen"] = root
    }
    try test("missing and changed individual thumbnails are empty without weakening file reads") {
      _ = try catalog.scan([shared], expected: catalog.clear())
      try fm.removeItem(at: photo)
      let missing = try catalog.thumbnail(id) { _, _ in throw TestFailure(message: "missing file reached decoder") }
      try expect(missing.isEmpty, "deleted photo has an empty thumbnail")
      try rejects("deleted photo download", code: "FILE_NOT_FOUND") { _ = try catalog.read(id, offset: 0, length: 1) }
      try Data([1]).write(to: photo)
      let changed = try catalog.thumbnail(id) { _, _ in throw TestFailure(message: "changed file reached decoder") }
      try expect(changed.isEmpty, "changed photo has an empty thumbnail")
      try rejects("changed photo download", code: "FILE_CHANGED") { _ = try catalog.read(id, offset: 0, length: 1) }
      try bytes.write(to: photo)
      let valid = try catalog.thumbnail(id) { _, _ in Data([3, 4]) }
      try expect(valid == Data([3, 4]), "other usable previews are preserved")
      let damaged = try catalog.thumbnail(id) { _, file in try MediaPreview.jpeg(file: file, video: false, maximum: 256) }
      try expect(damaged.isEmpty, "damaged image has an empty thumbnail")
      try fm.removeItem(at: photo)
      let rescanned = try catalog.scan([shared], expected: catalog.beginScan([shared]))
      try expect(rescanned.isEmpty, "rescan removes deleted photo")
      try bytes.write(to: photo)
      _ = try catalog.scan([shared], expected: catalog.clear())
    }
    try test("thumbnail fallback preserves permission, root and catalog errors") {
      access.roots.removeValue(forKey: "chosen")
      try rejects("revoked thumbnail", code: "PERMISSION_LOST") { _ = try catalog.thumbnail(id) { _, _ in Data() } }
      access.roots["chosen"] = root.appendingPathComponent("missing-root")
      try rejects("missing root", code: "FILE_NOT_FOUND") { _ = try catalog.thumbnail(id) { _, _ in Data() } }
      access.roots["chosen"] = root
      for code in ["PERMISSION_LOST", "SCAN_CANCELLED", "INVALID_ARGUMENT"] {
        try rejects("preview error \(code)", code: code) {
          _ = try catalog.thumbnail(id) { _, _ in throw PlatformFailure(code: code, message: code) }
        }
      }
      try rejects("unpublished photo", code: "FILE_NOT_FOUND") { _ = try catalog.thumbnail("unknown") { _, _ in Data() } }
      try rejects("fallback crossing revocation", code: "SCAN_CANCELLED") {
        _ = try catalog.thumbnail(id) { _, _ in
          catalog.clear()
          throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", message: "bad image")
        }
      }
      _ = try catalog.scan([shared], expected: catalog.clear())
    }
    try test("thumbnail fallback preserves resource, storage and general I/O failures") {
      let failures: [(Int32, String)] = [
        (EACCES, "PERMISSION_LOST"), (EPERM, "PERMISSION_LOST"),
        (ENOSPC, "STORAGE_FULL"), (EDQUOT, "STORAGE_FULL"),
        (EMFILE, "RESOURCE_EXHAUSTED"), (ENFILE, "RESOURCE_EXHAUSTED"),
        (EIO, "IO_ERROR"), (ELOOP, "IO_ERROR"),
      ]
      for (number, code) in failures {
        try rejects("I/O error \(number)", code: code) {
          _ = try catalog.thumbnail(id) { _, _ in
            errno = number
            throw PlatformFailure.io("Simulated file operation failure")
          }
        }
      }
      for number in [ENOENT, ENOTDIR] {
        let thumbnail = try catalog.thumbnail(id) { _, _ in
          errno = number
          throw PlatformFailure.io("Missing media path")
        }
        try expect(thumbnail.isEmpty, "missing media path still falls back")
      }
    }
    try test("real descriptor exhaustion is not cached as an empty thumbnail") {
      try rejects("exhausted file descriptors", code: "RESOURCE_EXHAUSTED") {
        _ = try catalog.thumbnail(id) { _, _ in
          var previous = rlimit()
          guard getrlimit(RLIMIT_NOFILE, &previous) == 0 else { throw TestFailure(message: "read descriptor limit") }
          var limited = previous
          limited.rlim_cur = min(previous.rlim_cur, 128)
          guard setrlimit(RLIMIT_NOFILE, &limited) == 0 else { throw TestFailure(message: "lower descriptor limit") }
          var descriptors: [Int32] = []
          defer {
            for descriptor in descriptors { Darwin.close(descriptor) }
            _ = setrlimit(RLIMIT_NOFILE, &previous)
          }
          while true {
            let descriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            if descriptor < 0 { break }
            descriptors.append(descriptor)
          }
          // Exercise the real open -> PlatformFailure.io -> thumbnail boundary.
          _ = try SafeFile.directory(root)
          throw TestFailure(message: "descriptor exhaustion did not fail the open")
        }
      }
      let recovered = try catalog.thumbnail(id) { _, _ in Data([1]) }
      try expect(recovered == Data([1]), "descriptor limit and handles restored")
    }
    try test("rescan keeps serving retained files until it publishes") {
      _ = try catalog.scan([shared], expected: catalog.clear())
      let ticket = catalog.beginScan([shared])
      try expect(catalog.read(id, offset: 0, length: 10) == bytes.subdata(in: 0..<10), "read during rescan")
      // A read spanning an unchanged republication completes normally.
      let spanning = try catalog.withMedia(id) { _, _ in
        _ = try catalog.scan([shared], expected: ticket)
        return Data([1])
      }
      try expect(spanning == Data([1]), "read across republication")
      _ = catalog.beginScan([])
      try rejects("removed folder", code: "FILE_NOT_FOUND") { _ = try catalog.read(id, offset: 0, length: 1) }
    }
    try test("failed rescan revokes the previous catalog but a stale one does not") {
      _ = try catalog.scan([shared], expected: catalog.clear())
      let stale = catalog.beginScan([shared])
      _ = catalog.beginScan([shared])
      try rejects("superseded scan", code: "SCAN_CANCELLED") { _ = try catalog.scan([shared], expected: stale) }
      try expect(catalog.read(id, offset: 0, length: 1) == bytes.subdata(in: 0..<1), "stale failure keeps serving")
      access.roots.removeValue(forKey: "chosen")
      try rejects("revoked rescan", code: "PERMISSION_LOST") {
        _ = try catalog.scan([shared], expected: catalog.beginScan([shared]))
      }
      access.roots["chosen"] = root
      try rejects("revoked catalog", code: "FILE_NOT_FOUND") { _ = try catalog.read(id, offset: 0, length: 1) }
      _ = try catalog.scan([shared], expected: catalog.clear())
    }
    try test("scan and read reject symlink escapes") {
      let outside = temporary.appendingPathComponent("outside.jpg")
      try bytes.write(to: outside)
      try fm.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: outside)
      try fm.createSymbolicLink(at: root.appendingPathComponent("linked-dir"), withDestinationURL: temporary)
      let entries = try catalog.scan([shared], expected: catalog.clear())
      try expect(entries.count == 1, "skip symbolic links: \(entries)")
      try fm.removeItem(at: photo)
      try fm.createSymbolicLink(at: photo, withDestinationURL: outside)
      try rejects("file replaced by link") { _ = try catalog.read(id, offset: 0, length: 1) }
      try fm.removeItem(at: photo); try bytes.write(to: photo)
      try fm.moveItem(at: nested, to: root.appendingPathComponent("old"))
      try fm.createSymbolicLink(at: nested, withDestinationURL: root.appendingPathComponent("old"))
      try rejects("parent replaced by link") { _ = try catalog.read(id, offset: 0, length: 1) }
      try fm.removeItem(at: nested); try fm.moveItem(at: root.appendingPathComponent("old"), to: nested)
    }
    let source = staging.appendingPathComponent("complete.part"); try bytes.write(to: source)
    try test("save concatenates ordered private parts directly and validates total size") {
      let first = staging.appendingPathComponent("0.part"), second = staging.appendingPathComponent("1.part")
      try bytes.subdata(in: 0..<333).write(to: first)
      try bytes.subdata(in: 333..<1000).write(to: second)
      let saved = try DownloadWriter.save(sources: [first, second], expectedSize: 1000,
        allowedRoots: [staging], destination: destination, directories: [], name: "parts.jpg")
      try expect(Data(contentsOf: saved) == bytes, "parts preserve source order")
      try expect(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path), "parts remain resumable until commit")
      for size: Int64 in [-1, 999, 1001] {
        try rejects("wrong total", code: "INVALID_ARGUMENT") {
          _ = try DownloadWriter.save(sources: [first, second], expectedSize: size,
            allowedRoots: [staging], destination: destination, directories: [], name: "invalid.jpg")
        }
      }
      try expect(!fm.fileExists(atPath: destination.appendingPathComponent("invalid.jpg").path), "invalid inputs do not reserve a target")
      let empty = staging.appendingPathComponent("empty.part"); try Data().write(to: empty)
      let savedEmpty = try DownloadWriter.save(sources: [empty], expectedSize: 0,
        allowedRoots: [staging], destination: destination, directories: [], name: "empty.jpg")
      try expect(Data(contentsOf: savedEmpty).isEmpty, "empty file can be saved")
    }
    try test("transfer space reports both private and destination volumes") {
      let space = try DownloadWriter.space(staging: staging, destination: destination)
      try expect((space["stagingAvailableBytes"] as? Int64 ?? -1) >= 0, "staging capacity")
      try expect((space["destinationAvailableBytes"] as? Int64 ?? -1) >= 0, "destination capacity")
      try expect(space["sameVolume"] as? Bool == true, "same temporary volume")
    }
    try test("save preserves nesting and never overwrites a name collision") {
      let first = try DownloadWriter.save(sources: [source], expectedSize: 1000, allowedRoots: [staging], destination: destination,
        directories: ["Peer", "Album", "旅行"], name: "a.jpg")
      let next = try DownloadWriter.save(sources: [source], expectedSize: 1000, allowedRoots: [staging], destination: destination,
        directories: ["Peer", "Album", "旅行"], name: "a.jpg")
      try expect(first.lastPathComponent == "a.jpg" && next.lastPathComponent == "a (1).jpg", "collision suffix")
      try expect(Data(contentsOf: first) == bytes && Data(contentsOf: next) == bytes, "saved bytes")
      try expect(first.path.hasSuffix("/Peer/Album/旅行/a.jpg"), "nested hierarchy")
    }
    try test("save rejects traversal, private-source escape and symlink parents") {
      try rejects("traversal") { _ = try DownloadWriter.save(sources: [source], expectedSize: 1000, allowedRoots: [staging], destination: destination, directories: [".."], name: "a.jpg") }
      try rejects("source outside sandbox") { _ = try DownloadWriter.save(sources: [photo], expectedSize: 1000, allowedRoots: [staging], destination: destination, directories: [], name: "a.jpg") }
      try fm.createSymbolicLink(at: destination.appendingPathComponent("escape"), withDestinationURL: root)
      try rejects("destination symlink") { _ = try DownloadWriter.save(sources: [source], expectedSize: 1000, allowedRoots: [staging], destination: destination, directories: ["escape"], name: "a.jpg") }
      let sourceLink = staging.appendingPathComponent("linked.part")
      try fm.createSymbolicLink(at: sourceLink, withDestinationURL: photo)
      try rejects("source symlink") { _ = try DownloadWriter.save(sources: [sourceLink], expectedSize: 1000, allowedRoots: [staging], destination: destination, directories: [], name: "a.jpg") }
      try expect(!fm.fileExists(atPath: root.appendingPathComponent("a.jpg").path), "outside unchanged")
    }
    try test("unauthorized bookmarks are rejected") {
      let suite = "dev.tamayura.tests.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let bookmarks = DirectoryBookmarks(defaults: defaults)
      try rejects("unknown bookmark", code: "PERMISSION_LOST") { try bookmarks.withDirectory(root.absoluteString) { _ in } }
      try rejects("unknown preview", code: "PERMISSION_LOST") { try bookmarks.withFile(photo.absoluteString) { _, _ in } }
    }
    try test("persisted bookmarks recover access and follow moved directories") {
      let suite = "dev.tamayura.tests.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let selected = try directory("bookmarked")
      try bytes.write(to: selected.appendingPathComponent("saved.jpg"))
      let first = DirectoryBookmarks(defaults: defaults)
      let uri = try first.remember(selected)
      let restored = DirectoryBookmarks(defaults: defaults)
      let savedURI = selected.appendingPathComponent("saved.jpg").absoluteString
      try restored.withFile(savedURI) { _, file in
        try expect(file.read(offset: 0, length: 1000, expectedSize: 1000) == bytes, "restored file")
      }
      let moved = temporary.appendingPathComponent("bookmarked-moved")
      try fm.moveItem(at: selected, to: moved)
      try restored.withDirectory(uri) { root in try expect(root.path == moved.path, "bookmark tracks move: \(root.path) vs \(moved.path)") }
      try restored.withFile(savedURI) { resolved, file in
        try expect(resolved == moved.appendingPathComponent("saved.jpg"), "stable original URI")
        try expect(file.read(offset: 0, length: 1000, expectedSize: 1000) == bytes, "moved file bytes")
      }
    }
    try test("valid descendant bookmark survives a stale ancestor bookmark") {
      let suite = "dev.tamayura.tests.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let bookmarks = DirectoryBookmarks(defaults: defaults)
      _ = try bookmarks.remember(nested)
      var records = defaults.dictionary(forKey: "tamayura.directoryBookmarks") as! [String: Data]
      records[root.absoluteString] = Data("invalid stale bookmark".utf8)
      defaults.set(records, forKey: "tamayura.directoryBookmarks")
      try bookmarks.withFile(photo.absoluteString) { _, file in
        try expect(file.read(offset: 0, length: 1000, expectedSize: 1000) == bytes, "valid nested grant")
      }
    }
    try test("real image preview through validated descriptor is bounded") {
      let context = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
      let target = root.appendingPathComponent("real.png")
      let writer = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)!
      CGImageDestinationAddImage(writer, context.makeImage()!, nil)
      try expect(CGImageDestinationFinalize(writer), "write fixture")
      let file = try SafeFile.directory(root).file(["real.png"])
      let jpeg = try MediaPreview.jpeg(file: file, video: false, maximum: 256)
      let image = CGImageSourceCreateWithData(jpeg as CFData, nil)!
      let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
      try expect(props[kCGImagePropertyPixelWidth] as? Int == 256, "thumbnail width")
      try expect(props[kCGImagePropertyPixelHeight] as? Int == 128, "aspect ratio")
      try rejects("invalid preview bound", code: "INVALID_ARGUMENT") { _ = try MediaPreview.jpeg(file: file, video: false, maximum: 3000) }
      try rejects("invalid media") { _ = try MediaPreview.jpeg(file: SafeFile.directory(root).file(["旅行", "a.jpg"]), video: false, maximum: 256) }
    }
    try test("real video thumbnail through validated descriptor") {
      let video = root.appendingPathComponent("sample.mov")
      try createVideo(video)
      let file = try SafeFile.directory(root).file(["sample.mov"])
      let jpeg = try MediaPreview.jpeg(file: file, video: true, maximum: 64)
      let image = CGImageSourceCreateWithData(jpeg as CFData, nil)
      try expect(image != nil, "video frame is JPEG")
      let props = CGImageSourceCopyPropertiesAtIndex(image!, 0, nil)! as NSDictionary
      try expect((props[kCGImagePropertyPixelWidth] as? Int ?? 1000) <= 64, "video bounded width")
    }
    try test("real MP4 thumbnail uses its source content type") {
      let video = root.appendingPathComponent("sample.mp4")
      try createVideo(video, fileType: .mp4, codec: .h264)
      let file = try SafeFile.directory(root).file(["sample.mp4"])
      let jpeg = try MediaPreview.jpeg(file: file, video: true, maximum: 64, mimeType: "video/mp4")
      try expect(CGImageSourceCreateWithData(jpeg as CFData, nil) != nil, "MP4 frame is JPEG")
    }
    print("\(passed) macOS native tests passed")
  }

  private static func createVideo(_ url: URL, fileType: AVFileType = .mov, codec: AVVideoCodecType = .jpeg) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec,
      AVVideoWidthKey: 128, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 64])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32ARGB, nil, &pixel)
    try expect(status == kCVReturnSuccess && pixel != nil, "video pixel buffer")
    CVPixelBufferLockBaseAddress(pixel!, [])
    memset(CVPixelBufferGetBaseAddress(pixel!), 200, CVPixelBufferGetDataSize(pixel!))
    CVPixelBufferUnlockBaseAddress(pixel!, [])
    let deadline = Date().addingTimeInterval(10)
    while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try expect(input.isReadyForMoreMediaData, "video writer ready")
    try expect(adaptor.append(pixel!, withPresentationTime: .zero), "append video")
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 10))
    input.markAsFinished()
    let complete = DispatchSemaphore(value: 0)
    writer.finishWriting { complete.signal() }
    try expect(complete.wait(timeout: .now() + 20) == .success, "video writer completion")
    guard writer.status == .completed else { throw writer.error! }
  }
}
