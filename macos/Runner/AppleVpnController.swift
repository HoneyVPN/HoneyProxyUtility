import Foundation
import NetworkExtension

/// Owns only HoneyProxy's Network Extension profile; initialization is read-only.
final class AppleVpnController {
  static let providerIdentifier = "ru.honeyvpn.proxy.macos.PacketTunnel"
  static let appGroupIdentifier = "group.ru.honeyvpn.proxy"
  var onEvent: (([String: Any]) -> Void)?
  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var activeConfiguration: URL?
  private var submittedSession: (id: UUID, profileId: Int64)?
  private var connectedAtUptime: UInt64?
  private var attempt = 0
  private var starting = false
  private var stopping = false
  private var pendingStop: ((Error?) -> Void)?
  private var stopTimeout: DispatchWorkItem?
  private var listening = false
  private var statsTimer: Timer?
  private var polling = false
  private var queryGeneration = 0

  // The executable and signed bundle are fixed for this process lifetime.
  // Signature verification belongs to startup, never the one-second stats loop.
  private lazy var validatedReadiness: Bool = {
    guard let plugins = Bundle.main.builtInPlugInsURL,
          let provider = Bundle(url: plugins.appendingPathComponent("HoneyProxyPacketTunnel.appex")),
          provider.bundleIdentifier == Self.providerIdentifier,
          provider.object(forInfoDictionaryKey: "HoneyProxyCoreRevision") as? String == "a47bdbe2aefc4da0aa8dd2280fb54c429dd0bfe0",
          (provider.object(forInfoDictionaryKey: "HoneyProxyCoreReady") as? Bool == true
            || (DevelopmentVpnGate.allows(Bundle.main) && DevelopmentVpnGate.allows(provider)))
    else { return false }
    // gomobile's framework is linked statically into the extension executable.
    guard let binary = provider.executableURL else { return false }
    return FileManager.default.fileExists(atPath: binary.path)
  }()

  var coreReady: Bool { validatedReadiness }

  func requestPermission(completion: @escaping (Bool, Error?) -> Void) {
    guard coreReady else { completion(false, nil); return }
    loadManager { error in
      guard error == nil else { completion(false, error); return }
      let manager = self.manager ?? NETunnelProviderManager()
      let configuration = NETunnelProviderProtocol()
      configuration.providerBundleIdentifier = Self.providerIdentifier
      configuration.serverAddress = "HoneyProxyUtility"
      configuration.providerConfiguration = ["appGroup": Self.appGroupIdentifier]
      manager.protocolConfiguration = configuration
      manager.localizedDescription = "HoneyProxyUtility"
      manager.isEnabled = true
      manager.isOnDemandEnabled = false
      manager.saveToPreferences { error in
        guard error == nil else { completion(false, error); return }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if error == nil { self.attach(manager) }
            completion(error == nil, error)
          }
        }
      }
    }
  }

  func start(config: String, profileId: Int64, sessionId: UUID, completion: @escaping (Error?) -> Void) {
    guard profileId > 0 else { completion(Self.error(3, "Invalid server identity")); return }
    guard coreReady else { completion(Self.error(1, "Apple VPN core is unavailable")); return }
    loadManager { error in
      guard error == nil else { completion(error); return }
      guard let manager = self.manager, manager.isEnabled else {
        completion(Self.error(2, "VPN permission has not been granted")); return
      }
      guard self.pendingStop == nil, !self.starting, !self.stopping,
            manager.connection.status == .disconnected || manager.connection.status == .invalid else {
        completion(Self.error(5, "Disconnect the current VPN before starting another session")); return
      }
      do {
        let file = try self.stageConfiguration(config, sessionId: sessionId)
        self.activeConfiguration = file
        self.submittedSession = (sessionId, profileId)
        self.connectedAtUptime = nil
        self.attempt += 1
        self.starting = true
        self.stopping = false
        self.queryGeneration += 1
        // The OS reports connected only after the packet provider completes startup.
        try manager.connection.startVPNTunnel(options: ["configurationFile": file.lastPathComponent as NSString,
          "sessionId": sessionId.uuidString as NSString, "profileId": NSNumber(value: profileId)])
        completion(nil)
      } catch {
        self.starting = false
        self.removeActiveConfiguration()
        completion(error)
      }
    }
  }

  func stop(completion: @escaping (Error?) -> Void) {
    loadManager { error in
      guard error == nil else { completion(error); return }
      self.attempt += 1
      self.starting = false
      self.stopping = true
      self.queryGeneration += 1
      self.stopPolling()
      if let previous = self.pendingStop {
        self.pendingStop = { error in previous(error); completion(error) }
        return
      }
      guard let manager = self.manager else {
        self.removeActiveConfiguration()
        completion(nil); return
      }
      self.pendingStop = completion
      manager.connection.stopVPNTunnel()
      if manager.connection.status == .disconnected || manager.connection.status == .invalid {
        self.finishStop(nil)
        return
      }
      let timeout = DispatchWorkItem { [weak self] in
        self?.finishStop(Self.error(6, "Apple VPN did not confirm disconnection within 10 seconds"))
      }
      self.stopTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
  }

  func checkStatus(completion: @escaping (Bool, Error?) -> Void) {
    loadManager { error in
      completion(self.manager?.connection.status == .connected, error)
    }
  }

  func getStatus(completion: @escaping ([String: Any]?, Error?) -> Void) {
    loadManager { error in
      guard error == nil else { completion(nil, error); return }
      self.readSnapshot { completion($0, nil) }
    }
  }

  func setListening(_ value: Bool) {
    if listening != value { queryGeneration += 1 }
    listening = value
    if value { emitCurrentStatus() } else { stopPolling() }
  }

  private func basicSnapshot() -> [String: Any] {
    let event: String
    switch manager?.connection.status {
    case .connected: event = "started"
    case .connecting, .reasserting: event = "connecting"
    case .disconnecting: event = "disconnecting"
    default: event = "stopped"
    }
    var snapshot: [String: Any] = ["version": 1, "event": event, "running": event == "started", "coreReady": coreReady,
      "trafficAvailable": false, "ratesAvailable": false]
    // During a locally submitted start the caller already owns this exact UUID.
    // Echo it only after OS-connected, never infer an identity from preferences.
    if event == "started", let submittedSession {
      let now = DispatchTime.now().uptimeNanoseconds
      if connectedAtUptime == nil { connectedAtUptime = now }
      snapshot["sessionId"] = submittedSession.id.uuidString
      snapshot["profileId"] = submittedSession.profileId
      snapshot["duration"] = Int64((now - (connectedAtUptime ?? now)) / 1_000_000_000)
    }
    return snapshot
  }

  private func readSnapshot(completion: @escaping ([String: Any]) -> Void) {
    let fallback = basicSnapshot()
    guard manager?.connection.status == .connected,
      let session = manager?.connection as? NETunnelProviderSession,
      let message = try? JSONSerialization.data(withJSONObject: ["command": "status", "version": 1])
    else { completion(fallback); return }
    let generation = queryGeneration
    let reply = AppleVpnSnapshotReply(completion)
    let timeout = DispatchWorkItem { [weak self] in
      reply.finish(self?.basicSnapshot() ?? fallback)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    do {
      try session.sendProviderMessage(message) { [weak self] data in
        DispatchQueue.main.async {
          timeout.cancel()
          guard let self, self.queryGeneration == generation,
            self.manager?.connection === session, session.status == .connected,
            let value = AppleVpnStatusSnapshot.decode(data), self.matchesSubmittedSession(value)
          else { reply.finish(self?.basicSnapshot() ?? fallback); return }
          var snapshot = value
          snapshot["event"] = "started"
          reply.finish(snapshot)
        }
      }
    } catch {
      timeout.cancel()
      reply.finish(basicSnapshot())
    }
  }

  private func matchesSubmittedSession(_ value: [String: Any]) -> Bool {
    guard let submittedSession else { return true } // A read-only UI reopen has no local guess.
    return value["sessionId"] as? String == submittedSession.id.uuidString
      && AppleVpnStatusSnapshot.integer(value["profileId"]) == submittedSession.profileId
  }

  private func startPolling() {
    guard listening, statsTimer == nil, !stopping else { return }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, self.listening, !self.polling,
        self.manager?.connection.status == .connected, !self.stopping else { return }
      self.polling = true
      let generation = self.queryGeneration
      self.readSnapshot { [weak self] snapshot in
        guard let self else { return }
        self.polling = false
        guard self.listening, self.queryGeneration == generation,
          self.manager?.connection.status == .connected, !self.stopping else { return }
        var event = snapshot
        event["event"] = "stats"
        self.onEvent?(event)
      }
    }
  }

  private func stopPolling() {
    statsTimer?.invalidate()
    statsTimer = nil
    polling = false
  }

  private func loadManager(completion: @escaping (Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
      if let error { completion(error); return }
      let owned = (managers ?? []).filter {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerIdentifier
      }
      if let selected = owned.first(where: { $0.connection.status != .disconnected && $0.connection.status != .invalid }) ?? owned.first {
        self.attach(selected)
        let allStopped = owned.allSatisfy { $0.connection.status == .disconnected || $0.connection.status == .invalid }
        if allStopped && !self.starting && self.pendingStop == nil,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
          let protected = Set(self.activeConfiguration.map { [$0.lastPathComponent] } ?? [])
          OwnedSessionConfiguration(directory: container.appendingPathComponent("VPN", isDirectory: true))
            .purge(whenDisconnected: true, protecting: protected)
        }
      } else {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
        self.manager = nil
      }
      completion(nil)
      }
    }
  }

  private func attach(_ manager: NETunnelProviderManager) {
    if self.manager?.connection !== manager.connection { queryGeneration += 1 }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    self.manager = manager
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
    ) { [weak self] _ in self?.emitCurrentStatus(isTransition: true) }
  }

  func emitCurrentStatus(isTransition: Bool = false) {
    switch manager?.connection.status {
    case .connected:
      starting = false
      let generation = queryGeneration
      readSnapshot { [weak self] snapshot in
        guard let self, self.queryGeneration == generation,
          self.manager?.connection.status == .connected, !self.stopping else { return }
        self.onEvent?(snapshot)
        self.startPolling()
      }
    case .connecting, .reasserting:
      stopPolling()
      queryGeneration += 1
      onEvent?(basicSnapshot())
    case .disconnecting:
      stopPolling()
      queryGeneration += 1
      onEvent?(basicSnapshot())
    default:
      stopPolling()
      queryGeneration += 1
      if isTransition && starting && !stopping, let manager {
        starting = false
        let failedAttempt = attempt
        manager.connection.fetchLastDisconnectError { [weak self] error in
          DispatchQueue.main.async {
            guard let self, self.attempt == failedAttempt, !self.stopping else { return }
            self.removeActiveConfiguration()
            self.onEvent?(["event": "error", "message": error?.localizedDescription ?? "Apple VPN could not connect."])
            self.onEvent?(["event": "stopped"])
          }
        }
        return
      }
      if isTransition && stopping { finishStop(nil) }
      if isTransition && !starting && !stopping { removeActiveConfiguration() }
      onEvent?(basicSnapshot())
    }
  }

  private func finishStop(_ error: Error?) {
    stopTimeout?.cancel()
    stopTimeout = nil
    if error == nil { removeActiveConfiguration() }
    let completion = pendingStop
    pendingStop = nil
    stopping = false
    completion?(error)
  }

  private func removeActiveConfiguration() {
    if let file = activeConfiguration {
      OwnedSessionConfiguration(directory: file.deletingLastPathComponent()).remove(file)
    }
    activeConfiguration = nil
    submittedSession = nil
    connectedAtUptime = nil
  }

  private func stageConfiguration(_ value: String, sessionId: UUID) throws -> URL {
    guard let data = value.data(using: .utf8),
          var configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let inbounds = configuration["inbounds"] as? [[String: Any]],
          inbounds.contains(where: { $0["type"] as? String == "tun" })
    else { throw Self.error(3, "Invalid packet tunnel configuration") }
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    else { throw Self.error(4, "The signed app group is unavailable") }
    let directory = container.appendingPathComponent("VPN", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    // Local geo assets must live in the shared group, not the host app's sandbox.
    if var route = configuration["route"] as? [String: Any],
       var rules = route["rule_set"] as? [[String: Any]] {
      let allowed = Set(["ru-blocked.srs", "ru-blocked-community.srs", "re-filter.srs", "ru.srs", "geosite-category-ads-all.srs"])
      for index in rules.indices where rules[index]["type"] as? String == "local" {
        guard let path = rules[index]["path"] as? String else { throw Self.error(3, "Missing rule-set path") }
        let source = URL(fileURLWithPath: path)
        guard allowed.contains(source.lastPathComponent) else { throw Self.error(3, "Unsupported local rule-set file") }
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let content = try Data(contentsOf: source)
        try content.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        rules[index]["path"] = destination.path
      }
      route["rule_set"] = rules
      configuration["route"] = route
    }
    return try OwnedSessionConfiguration(directory: directory)
      .publish(JSONSerialization.data(withJSONObject: configuration), sessionId: sessionId)
  }

  private static func error(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "HoneyProxyAppleVPN", code: code, userInfo: [NSLocalizedDescriptionKey: message])
  }

  deinit {
    statsTimer?.invalidate()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    // Closing the UI does not terminate an OS-managed packet tunnel.
  }
}
