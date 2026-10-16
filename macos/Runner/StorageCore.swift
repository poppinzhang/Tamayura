import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

struct PlatformFailure: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
  static func invalid(_ message: String) -> PlatformFailure {
    PlatformFailure(code: "INVALID_ARGUMENT", message: message)
  }
  static func io(_ message: String) -> PlatformFailure {
    let code = errno == EACCES || errno == EPERM ? "PERMISSION_LOST" : "FILE_NOT_FOUND"
    return PlatformFailure(code: code, message: message)
  }
}

/// Path rules are also used for untrusted peer metadata. Never interpret a
/// component as a path, and never traverse a symbolic link inside a chosen root.
enum StoragePaths {
  static func segment(_ value: String) throws {
    guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
          !value.contains("/"), !value.contains("\\"),
          !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
      throw PlatformFailure.invalid("媒体目录或文件名称无效")
    }
  }

  static func components(_ path: String) throws -> [String] {
    guard !path.isEmpty, path.utf8.count <= 4096 else {
      throw PlatformFailure.invalid("媒体相对路径无效")
    }
    guard path.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else {
      throw PlatformFailure.invalid("媒体相对路径不能使用盘符")
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    try parts.forEach(segment)
    return parts
  }

  static func contains(_ root: URL, _ child: URL) -> Bool {
    let a = root.standardizedFileURL.pathComponents
    let b = child.standardizedFileURL.pathComponents
    return b.count >= a.count && Array(b.prefix(a.count)) == a
  }

  static func overlap(_ a: URL, _ b: URL) -> Bool {
    contains(a, b) || contains(b, a)
  }

  static func relative(_ url: URL, root: URL) throws -> [String] {
    guard contains(root, url), url.standardizedFileURL != root.standardizedFileURL else {
      throw PlatformFailure.invalid("文件不在授权目录中")
    }
    let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
    try parts.forEach(segment)
    return parts
  }

  static func fileURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.isFileURL,
          url.host == nil || url.host == "" || url.host == "localhost",
          url.query == nil, url.fragment == nil else {
      throw PlatformFailure.invalid("需要本机文件 URI")
    }
    return url.standardizedFileURL
  }

  static func availableName(_ name: String, attempt: Int) -> String {
    guard attempt > 0 else { return name }
    let file = name as NSString
    let ext = file.pathExtension
    return ext.isEmpty ? "\(name) (\(attempt))" : "\(file.deletingPathExtension) (\(attempt)).\(ext)"
  }
}

/// Directory descriptors pin each traversed component; openat + O_NOFOLLOW
/// prevents both symlink escapes and parent-directory replacement races.
final class SafeFile {
  let fd: Int32
  init(fd: Int32) throws {
    guard fd >= 0 else { throw PlatformFailure.io("无法访问文件或目录，请检查授权和路径") }
    self.fd = fd
  }
  deinit { Darwin.close(fd) }

  static func directory(_ root: URL) throws -> SafeFile {
    try SafeFile(fd: Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
  }

  func directory(_ parts: [String], create: Bool = false) throws -> SafeFile {
    var current = try SafeFile(fd: dup(fd))
    for part in parts {
      try StoragePaths.segment(part)
      if create && mkdirat(current.fd, part, 0o755) != 0 && errno != EEXIST {
        throw PlatformFailure.io("无法创建接收子目录")
      }
      current = try SafeFile(fd: openat(current.fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }
    return current
  }

  func file(_ parts: [String]) throws -> SafeFile {
    guard let name = parts.last else { throw PlatformFailure.invalid("文件路径为空") }
    try StoragePaths.segment(name)
    let parent = try directory(Array(parts.dropLast()))
    let file = try SafeFile(fd: openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
    _ = try file.info()
    return file
  }

  func info() throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
      throw PlatformFailure(code: "FILE_NOT_FOUND", message: "媒体文件不存在或不是普通文件")
    }
    return value
  }

  func read(offset: Int64, length: Int, expectedSize: Int64) throws -> Data {
    guard offset >= 0, offset <= expectedSize, (0...(256 * 1024)).contains(length) else {
      throw PlatformFailure.invalid("无效的文件分块范围")
    }
    guard try info().st_size == expectedSize else {
      throw PlatformFailure(code: "FILE_CHANGED", message: "文件大小已改变，请刷新相册")
    }
    let count = min(length, Int(expectedSize - offset))
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { raw in
      var read = 0
      while read < count {
        let amount = pread(fd, raw.baseAddress!.advanced(by: read), count - read, offset + Int64(read))
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { throw PlatformFailure.io("文件提前结束，请刷新相册") }
        read += amount
      }
    }
    return data
  }
}

protocol DirectoryAccess {
  func withDirectory<T>(_ uri: String, _ operation: (URL) throws -> T) throws -> T
}

struct SharedDirectory {
  let id: String
  let uri: String
  let name: String
}

struct SharedMedia {
  let directoryURI: String
  let relativePath: String
  let mimeType: String
  let size: Int64
}

final class MediaCatalog {
  private let access: DirectoryAccess
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var files: [String: SharedMedia] = [:]
  init(access: DirectoryAccess) { self.access = access }

  @discardableResult func clear() -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    generation &+= 1
    files.removeAll()
    return generation
  }

  func assertGeneration(_ expected: UInt64) throws {
    lock.lock(); defer { lock.unlock() }
    guard expected == generation else {
      throw PlatformFailure(code: "SCAN_CANCELLED", message: "共享目录已改变，请重新扫描")
    }
  }

  func validate(_ uri: String, existing: [String]) throws {
    try access.withDirectory(uri) { candidate in
      for previous in existing {
        try access.withDirectory(previous) { root in
          if StoragePaths.overlap(candidate, root) {
            throw PlatformFailure(code: "DIR_OVERLAP", message: "共享目录不能重复或互相包含")
          }
        }
      }
    }
  }

  /// A failed scan never leaves a partly updated or previously authorized catalog.
  func scan(_ directories: [SharedDirectory], expected: UInt64) throws -> [[String: Any]] {
    try assertGeneration(expected)
    guard Set(directories.map { $0.id }).count == directories.count else {
      throw PlatformFailure.invalid("共享目录标识重复")
    }
    for (index, directory) in directories.enumerated() {
      try StoragePaths.segment(directory.id)
      try StoragePaths.segment(directory.name)
      try validate(directory.uri, existing: directories.prefix(index).map { $0.uri })
    }
    var metadata: [[String: Any]] = []
    var next: [String: SharedMedia] = [:]
    for directory in directories {
      try access.withDirectory(directory.uri) { root in
        let rootHandle = try SafeFile.directory(root)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
          includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
            enumerationError = error
            return false
          }) else { throw PlatformFailure(code: "FILE_NOT_FOUND", message: "无法读取共享目录") }
        for case let url as URL in enumerator {
          try assertGeneration(expected)
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          // Foundation does not descend through symlinks. Calling skipDescendants
          // on a non-directory link would incorrectly skip its sibling entries.
          if values.isSymbolicLink == true { continue }
          guard values.isRegularFile == true, let type = UTType(filenameExtension: url.pathExtension),
                type.conforms(to: .image) || type.conforms(to: .movie),
                let mime = type.preferredMIMEType else { continue }
          let parts = try StoragePaths.relative(url, root: root)
          let path = parts.joined(separator: "/")
          _ = try StoragePaths.components(path)
          let info = try rootHandle.file(parts).info()
          let id = SHA256.hash(data: Data("\(directory.id)\u{0}\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
          next[id] = SharedMedia(directoryURI: directory.uri, relativePath: path, mimeType: mime, size: info.st_size)
          metadata.append(["id": id, "name": parts.last!, "mimeType": mime, "size": info.st_size,
            "modifiedMs": Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000,
            "sharedFolderId": directory.id, "sharedFolderName": directory.name, "relativePath": path])
        }
        if let error = enumerationError { throw error }
      }
    }
    lock.lock(); defer { lock.unlock() }
    guard expected == generation else {
      throw PlatformFailure(code: "SCAN_CANCELLED", message: "共享目录已改变，请重新扫描")
    }
    files = next
    return metadata
  }

  func withMedia<T>(_ id: String, _ operation: (SharedMedia, SafeFile) throws -> T) throws -> T {
    lock.lock()
    let expected = generation
    let entry = files[id]
    lock.unlock()
    guard let entry else { throw PlatformFailure(code: "FILE_NOT_FOUND", message: "文件未被共享，请刷新相册") }
    return try access.withDirectory(entry.directoryURI) { root in
      try assertGeneration(expected)
      let file = try SafeFile.directory(root).file(StoragePaths.components(entry.relativePath))
      guard try file.info().st_size == entry.size else {
        throw PlatformFailure(code: "FILE_CHANGED", message: "文件大小已改变，请刷新相册")
      }
      let value = try operation(entry, file)
      try assertGeneration(expected)
      return value
    }
  }

  func read(_ id: String, offset: Int64, length: Int) throws -> Data {
    try withMedia(id) { entry, file in
      try file.read(offset: offset, length: length, expectedSize: entry.size)
    }
  }
}

/// Save via pinned parent descriptors and O_EXCL, preserving peer folder layout
/// without overwriting any existing file, including when saves run concurrently.
enum DownloadWriter {
  static func save(source: URL, allowedRoots: [URL], destination: URL,
                   directories: [String], name: String) throws -> URL {
    try StoragePaths.segment(name)
    try directories.forEach(StoragePaths.segment)
    let source = source.standardizedFileURL
    guard let sourceRoot = allowedRoots.first(where: { StoragePaths.contains($0, source) && $0 != source }) else {
      throw PlatformFailure.invalid("下载源文件必须在应用私有目录中")
    }
    let input = try SafeFile.directory(sourceRoot).file(StoragePaths.relative(source, root: sourceRoot))
    let parent = try SafeFile.directory(destination).directory(directories, create: true)
    var finalName = name
    var descriptor: Int32 = -1
    for attempt in 0...10000 {
      finalName = StoragePaths.availableName(name, attempt: attempt)
      try StoragePaths.segment(finalName)
      descriptor = openat(parent.fd, finalName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
      if descriptor >= 0 { break }
      guard errno == EEXIST else { throw PlatformFailure.io("无法创建接收文件") }
    }
    let output = try SafeFile(fd: descriptor)
    do {
      var buffer = [UInt8](repeating: 0, count: 256 * 1024)
      while true {
        let count = Darwin.read(input.fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw PlatformFailure.io("无法读取下载暂存文件") }
        if count == 0 { break }
        try buffer.withUnsafeBytes { bytes in
          var written = 0
          while written < count {
            let amount = Darwin.write(output.fd, bytes.baseAddress!.advanced(by: written), count - written)
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw PlatformFailure.io("无法保存下载文件，可能磁盘空间不足") }
            written += amount
          }
        }
      }
      guard fsync(output.fd) == 0 else { throw PlatformFailure.io("无法完成文件保存") }
    } catch {
      unlinkat(parent.fd, finalName, 0)
      throw error
    }
    return (directories + [finalName]).reduce(destination) { $0.appendingPathComponent($1) }
  }
}
