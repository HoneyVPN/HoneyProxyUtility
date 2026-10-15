import Foundation
import NetworkExtension

#if HONEYPROXY_LIBBOX_VALIDATED && !canImport(Libbox)
#error("The pinned Libbox framework is required for this build configuration")
#endif
#if canImport(Libbox)
import Libbox
#endif

/// OS-owned packet tunnel. Readiness remains gated until signed routing tests pass.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private static let appGroup = "group.ru.honeyvpn.proxy"
  private let worker = DispatchQueue(label: "ru.honeyvpn.proxy.libbox", qos: .userInitiated)
  private let stateLock = NSLock()
  private let coreLock = NSRecursiveLock()
  private let teardownGate = TunnelTeardownGate()
  private lazy var settingsCoordinator = TunnelSettingsCoordinator(provider: self)
  private var generation: UInt64 = 0
  private var starting = false
  private var running = false
  private var configContent: String?
  private var configurationFile: URL?
  private var sessionIdentity: AppleProviderSessionIdentity?
  private var startedAtUptime: UInt64?
  private let trafficCounters = AppleTrafficCounters()
  #if canImport(Libbox)
  private var server: LibboxCommandServer?
  private var platform: LibboxPlatformAdapter?
  private var counterStream: LibboxCounterStream?
  #endif

  // This process has one immutable signed executable; do not rehash its bundle
  // for every telemetry message after the startup validation.
  private let coreReady: Bool = {
    #if canImport(Libbox)
    return LibboxVersion() == "1.13.12-extended-2.1.2"
      && (Bundle.main.object(forInfoDictionaryKey: "HoneyProxyCoreReady") as? Bool == true
        || DevelopmentVpnGate.allows(Bundle.main))
    #else
    return false
    #endif
  }()

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    guard coreReady else { completionHandler(Self.error("Apple VPN core integration is unavailable in this build")); return }
    let identity: AppleProviderSessionIdentity
    do { identity = try AppleProviderSessionIdentity(options: options) }
    catch { completionHandler(error); return }
    stateLock.lock()
    guard teardownGate.allowsStart else { stateLock.unlock(); completionHandler(Self.error("Packet tunnel teardown is not complete")); return }
    guard !starting && !running else { stateLock.unlock(); completionHandler(Self.error("The packet tunnel is already running")); return }
    generation &+= 1
    let attempt = generation
    starting = true
    sessionIdentity = identity
    startedAtUptime = nil
    stateLock.unlock()
    #if canImport(Libbox)
    worker.async {
      self.coreLock.lock(); defer { self.coreLock.unlock() }
      do {
        let configuration = try self.loadConfiguration(options)
        let runtimeContent = try AppleRuntimeConfiguration.withTrafficTracker(configuration.content)
        self.configurationFile = configuration.file
        guard self.isCurrent(attempt) else { throw Self.error("Packet tunnel startup was cancelled") }
        let setup = LibboxSetupOptions()
        setup.basePath = configuration.directory.path
        setup.workingPath = configuration.directory.appendingPathComponent("Working").path
        setup.tempPath = configuration.directory.appendingPathComponent("Temp").path
        setup.commandServerSecret = UUID().uuidString
        setup.commandServerListenPort = 0 // Private app-group Unix socket, never public TCP.
        setup.logMaxLines = 300
        setup.debug = false
        for path in [setup.workingPath, setup.tempPath] {
          try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        var error: NSError?
        guard LibboxSetup(setup, &error) else { throw error ?? Self.error("Could not configure the VPN core") }
        guard LibboxCheckConfig(runtimeContent, &error) else { throw error ?? Self.error("The VPN configuration is invalid") }
        let platform = LibboxPlatformAdapter(provider: self, settingsCoordinator: self.settingsCoordinator,
          isCurrent: { [weak self] in self?.isCurrent(attempt) == true },
          requestStop: { [weak self] in self?.cancelTunnelWithError(nil) },
          requestReload: { [weak self] in try self?.reload(attempt) })
        self.platform = platform
        guard let server = LibboxNewCommandServer(platform, platform, &error) else {
          throw error ?? Self.error("Could not create the VPN service")
        }
        self.server = server
        self.configContent = runtimeContent
        try server.start()
        try server.startOrReloadService(runtimeContent, options: LibboxOverrideOptions())
        self.stateLock.lock()
        let valid = self.generation == attempt && self.starting
        if valid { self.starting = false; self.running = true; self.startedAtUptime = DispatchTime.now().uptimeNanoseconds }
        self.stateLock.unlock()
        guard valid else { throw Self.error("Packet tunnel startup was cancelled") }
        self.startCounters(attempt)
        guard self.isCurrent(attempt) else { throw Self.error("Packet tunnel startup was cancelled") }
        completionHandler(nil)
      } catch {
        self.stateLock.lock()
        if self.generation == attempt {
          self.teardownGate.begin(attempt)
          self.starting = false; self.running = false
        }
        self.stateLock.unlock()
        self.closeCore()
        do {
          try self.settingsCoordinator.apply(nil, isCurrent: { true })
          self.teardownGate.finish(attempt, confirmed: true)
        } catch {
          self.teardownGate.finish(attempt, confirmed: false)
          self.cancelTunnelWithError(error)
        }
        completionHandler(error)
      }
    }
    #else
    completionHandler(Self.error("Apple VPN core integration is unavailable in this build"))
    #endif
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    stateLock.lock()
    generation &+= 1
    let attempt = generation
    teardownGate.begin(attempt)
    starting = false; running = false
    stateLock.unlock()
    trafficCounters.clear()
    worker.async {
      #if canImport(Libbox)
      self.closeCore()
      #endif
      do {
        try self.settingsCoordinator.apply(nil, isCurrent: { true })
        self.teardownGate.finish(attempt, confirmed: true)
      } catch {
        self.teardownGate.finish(attempt, confirmed: false)
        self.cancelTunnelWithError(error)
      }
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard messageData.count <= 4096,
      let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
      message["command"] as? String == "status" else { completionHandler?(nil); return }
    // Identity and counters must describe the same provider generation. A stop
    // or new start cannot publish another session between these reads.
    stateLock.lock()
    let isRunning = running
    let now = DispatchTime.now().uptimeNanoseconds
    var fields: [String: Any] = ["version": 1, "coreReady": coreReady, "running": isRunning]
    if isRunning, let identity = sessionIdentity, let startedAt = startedAtUptime {
      fields.merge(identity.fields(startedAtUptime: startedAt, now: now)) { _, new in new }
    }
    fields.merge(trafficCounters.fields(running: isRunning, now: now)) { _, new in new }
    stateLock.unlock()
    let reply = try? JSONSerialization.data(withJSONObject: fields)
    completionHandler?(reply.flatMap { $0.count <= 4096 ? $0 : nil })
  }

  private func isCurrent(_ attempt: UInt64) -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return generation == attempt && (starting || running)
  }

  #if canImport(Libbox)
  private func reload(_ attempt: UInt64) throws {
    coreLock.lock(); defer { coreLock.unlock() }
    guard isCurrent(attempt), let server, let configContent else { throw Self.error("The VPN service is not running") }
    try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
    startCounters(attempt)
  }

  private func startCounters(_ attempt: UInt64) {
    counterStream?.stop()
    let stream = LibboxCounterStream(counters: trafficCounters, isCurrent: { [weak self] in self?.isCurrent(attempt) == true })
    counterStream = stream
    do { try stream.start() }
    catch { stream.stop(); counterStream = nil }
  }

  private func closeCore() {
    coreLock.lock(); defer { coreLock.unlock() }
    counterStream?.stop(); counterStream = nil
    trafficCounters.clear()
    if let server { try? server.closeService(); server.close() }
    server = nil
    platform?.reset()
    platform = nil
    configContent = nil
    if let file = configurationFile {
      OwnedSessionConfiguration(directory: file.deletingLastPathComponent()).remove(file)
    }
    configurationFile = nil
    stateLock.lock(); sessionIdentity = nil; startedAtUptime = nil; stateLock.unlock()
  }
  #endif

  private func loadConfiguration(_ options: [String: NSObject]?) throws -> (content: String, directory: URL, file: URL) {
    guard let name = options?["configurationFile"] as? String,
      let protocolOptions = protocolConfiguration as? NETunnelProviderProtocol,
      protocolOptions.providerConfiguration?["appGroup"] as? String == Self.appGroup,
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
    else { throw Self.error("The signed VPN configuration is unavailable") }
    let directory = container.resolvingSymlinksInPath().appendingPathComponent("VPN", isDirectory: true)
    let file = try OwnedSessionConfiguration(directory: directory).file(named: name)
    // Retain ownership before parsing so even a malformed owned session is
    // removed by closeCore after failed startup, including after UI relaunch.
    configurationFile = file
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue > 0 && size.intValue <= 2 * 1024 * 1024
    else { throw Self.error("Invalid VPN configuration file") }
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    guard data.count <= 2 * 1024 * 1024, let content = String(data: data, encoding: .utf8),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let inbounds = json["inbounds"] as? [[String: Any]],
      inbounds.contains(where: { $0["type"] as? String == "tun" })
    else { throw Self.error("Invalid packet tunnel configuration") }
    return (content, directory, file)
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "HoneyProxyAppleVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
