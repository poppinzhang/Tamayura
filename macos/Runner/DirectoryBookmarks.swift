import Foundation

/// Only directories explicitly chosen in NSOpenPanel are accepted. The persisted
/// key remains stable when a security-scoped bookmark tracks a moved directory.
final class DirectoryLease {
  let url: URL
  private let scoped: Bool
  init(url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
  deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

final class AuthorizedFile {
  let url: URL
  let file: SafeFile
  private let lease: DirectoryLease
  init(url: URL, file: SafeFile, lease: DirectoryLease) {
    self.url = url; self.file = file; self.lease = lease
  }
}

final class DirectoryBookmarks: DirectoryAccess {
  private let defaults: UserDefaults
  private let lock = NSLock()
  private let key = "tamayura.directoryBookmarks"
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func remember(_ url: URL) throws -> String {
    let root = url.resolvingSymlinksInPath().standardizedFileURL
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    _ = try SafeFile.directory(root)
    let bookmark = try root.bookmarkData(options: .withSecurityScope,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    let uri = root.absoluteString
    lock.lock(); defer { lock.unlock() }
    var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    bookmarks[uri] = bookmark
    defaults.set(bookmarks, forKey: key)
    return uri
  }

  func withDirectory<T>(_ uri: String, _ operation: (URL) throws -> T) throws -> T {
    let lease = try directoryLease(uri)
    return try withExtendedLifetime(lease) { try operation(lease.url) }
  }

  private func directoryLease(_ uri: String) throws -> DirectoryLease {
    _ = try StoragePaths.fileURL(uri)
    lock.lock()
    let bookmark = (defaults.dictionary(forKey: key) as? [String: Data])?[uri]
    lock.unlock()
    guard let bookmark else {
      throw PlatformFailure(code: "PERMISSION_LOST", .permissionLost)
    }
    var stale = false
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
    } catch {
      throw PlatformFailure(code: "PERMISSION_LOST", .permissionRestoreFailed)
    }
    let lease = DirectoryLease(url: url.standardizedFileURL)
    if stale {
      let refreshed = try url.bookmarkData(options: .withSecurityScope,
        includingResourceValuesForKeys: nil, relativeTo: nil)
      lock.lock()
      var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
      bookmarks[uri] = refreshed
      defaults.set(bookmarks, forKey: key)
      lock.unlock()
    }
    _ = try SafeFile.directory(lease.url)
    return lease
  }

  func withFile<T>(_ value: String, _ operation: (URL, SafeFile) throws -> T) throws -> T {
    let access = try fileAccess(value)
    return try withExtendedLifetime(access) { try operation(access.url, access.file) }
  }

  func fileAccess(_ value: String) throws -> AuthorizedFile {
    try withFileLocation(value) { lease, parts in
      let handle = try SafeFile.directory(lease.url).file(parts)
      let resolved = parts.reduce(lease.url) { $0.appendingPathComponent($1) }
      return AuthorizedFile(url: resolved, file: handle, lease: lease)
    }
  }

  func deleteFile(_ value: String) throws {
    try withFileLocation(value) { lease, parts in
      try SafeFile.directory(lease.url).deleteFile(parts)
    }
  }

  private func withFileLocation<T>(_ value: String,
                                  _ operation: (DirectoryLease, [String]) throws -> T) throws -> T {
    let url = try StoragePaths.fileURL(value)
    lock.lock()
    let keys = Array((defaults.dictionary(forKey: key) as? [String: Data] ?? [:]).keys)
    lock.unlock()
    var failure: Error?
    for uri in keys.sorted(by: { $0.count > $1.count }) {
      let original = try StoragePaths.fileURL(uri)
      guard StoragePaths.contains(original, url), original != url else { continue }
      do {
        let lease = try directoryLease(uri)
        let parts = try StoragePaths.relative(url, root: original)
        return try withExtendedLifetime(lease) { try operation(lease, parts) }
      } catch { failure = error }
    }
    if let failure { throw failure }
    throw PlatformFailure(code: "PERMISSION_LOST", .fileOutsideGrant)
  }
}
