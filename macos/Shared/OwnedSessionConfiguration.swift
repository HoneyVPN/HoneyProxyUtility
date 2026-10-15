import Foundation
import Darwin

/// Restricts credential cleanup to UUID session files in the app's VPN directory.
struct OwnedSessionConfiguration {
  let directory: URL

  init(directory: URL) { self.directory = directory.resolvingSymlinksInPath().standardizedFileURL }

  /// Publish a complete private file without replacing another session's data.
  func publish(_ data: Data, sessionId: UUID) throws -> URL {
    let destination = directory.appendingPathComponent("session-\(sessionId.uuidString).json")
    var temporaryId = UUID()
    while temporaryId == sessionId { temporaryId = UUID() }
    let temporary = directory.appendingPathComponent("session-\(temporaryId.uuidString).json")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
    }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    // A hard link publishes all bytes at once and fails if the destination exists.
    // Both files are inside the same app-group directory and filesystem.
    try FileManager.default.linkItem(at: temporary, to: destination)
    return destination
  }

  func file(named name: String) throws -> URL {
    guard name.range(of: "^session-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.json$", options: .regularExpression) != nil else {
      throw Self.invalidLocation()
    }
    let file = directory.appendingPathComponent(name).standardizedFileURL
    guard file.resolvingSymlinksInPath() == file,
      try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
      throw Self.invalidLocation()
    }
    return file
  }

  @discardableResult
  func remove(_ fileURL: URL) -> Bool {
    guard fileURL.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == directory,
      let owned = try? file(named: fileURL.lastPathComponent) else { return false }
    do { try FileManager.default.removeItem(at: owned); return true }
    catch { return false }
  }

  /// A fresh staged file may belong to another launch that has not reached an
  /// OS connecting state yet. Purge only old files after all owned profiles stop.
  @discardableResult
  func purge(whenDisconnected: Bool, olderThan cutoff: Date = Date().addingTimeInterval(-86400),
    protecting protectedNames: Set<String> = []) -> Int {
    guard whenDisconnected,
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
    var removed = 0
    for candidate in files where !protectedNames.contains(candidate.lastPathComponent) {
      guard let owned = try? file(named: candidate.lastPathComponent),
        let date = try? owned.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
        date < cutoff else { continue }
      if remove(owned) { removed += 1 }
    }
    return removed
  }

  private static func invalidLocation() -> NSError {
    NSError(domain: "HoneyProxyAppleVPN", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid VPN session configuration location"])
  }
}
