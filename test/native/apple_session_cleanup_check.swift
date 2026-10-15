import Foundation

@main
struct SessionCleanupCheck {
  static func main() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("honey-session-check-\(UUID().uuidString)")
    let directory = base.appendingPathComponent("VPN", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = OwnedSessionConfiguration(directory: directory)
    func require(_ value: Bool) { precondition(value) }
    let sessionId = UUID()
    let payload = Data(repeating: 0x71, count: 262144)
    let published = try store.publish(payload, sessionId: sessionId)
    require(try Data(contentsOf: published) == payload)
    let permissions = try FileManager.default.attributesOfItem(atPath: published.path)[.posixPermissions] as? NSNumber
    precondition(permissions?.intValue == 0o600)
    do {
      _ = try store.publish(Data("must not replace".utf8), sessionId: sessionId)
      preconditionFailure("An existing session was overwritten")
    } catch {}
    require(try Data(contentsOf: published) == payload)
    require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [published.lastPathComponent])
    precondition(store.remove(published))
    let linkedSession = UUID()
    let linkedDestination = directory.appendingPathComponent("session-\(linkedSession.uuidString).json")
    let external = base.appendingPathComponent("external.json")
    try Data("outside remains unchanged".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: external)
    do {
      _ = try store.publish(payload, sessionId: linkedSession)
      preconditionFailure("A symlink destination was followed")
    } catch {}
    require(try Data(contentsOf: external) == Data("outside remains unchanged".utf8))
    require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [linkedDestination.lastPathComponent])
    try FileManager.default.removeItem(at: linkedDestination)
    func create(_ directory: URL, name: String = "session-\(UUID().uuidString).json", old: Bool = false) throws -> URL {
      let file = directory.appendingPathComponent(name)
      try Data("test-only".utf8).write(to: file)
      if old { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: file.path) }
      return file
    }
    let stoppedSession = try create(directory)
    let validated = try store.file(named: stoppedSession.lastPathComponent)
    precondition(validated == stoppedSession.resolvingSymlinksInPath())
    precondition(store.remove(stoppedSession))
    precondition(!FileManager.default.fileExists(atPath: stoppedSession.path))
    let outside = try create(base, old: true)
    precondition(!store.remove(outside))
    let stale = try create(directory, old: true)
    let fresh = try create(directory)
    let active = try create(directory, old: true)
    let geo = try create(directory, name: "ru.srs", old: true)
    let unrelated = try create(directory, name: "notes.json", old: true)
    let symlink = directory.appendingPathComponent("session-\(UUID().uuidString).json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    do { _ = try store.file(named: symlink.lastPathComponent); preconditionFailure("Symlink accepted") } catch {}
    do { _ = try store.file(named: "../" + outside.lastPathComponent); preconditionFailure("Traversal accepted") } catch {}
    precondition(store.purge(whenDisconnected: false) == 0)
    precondition(FileManager.default.fileExists(atPath: stale.path))
    precondition(store.purge(whenDisconnected: true, protecting: [active.lastPathComponent]) == 1)
    precondition(!FileManager.default.fileExists(atPath: stale.path))
    for file in [outside, fresh, active, geo, unrelated, symlink] { precondition(FileManager.default.fileExists(atPath: file.path)) }
    print("Owned session checks passed: complete exclusive publication, private permissions, collision/symlink protection, temporary cleanup, stopped session deletion, active/fresh protection, disconnected-only stale purge and unrelated-file preservation.")
  }
}
