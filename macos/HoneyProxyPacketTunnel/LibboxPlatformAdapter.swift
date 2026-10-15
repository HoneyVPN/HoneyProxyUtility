import Darwin
import Foundation
import Network
import NetworkExtension

#if HONEYPROXY_LIBBOX_VALIDATED && !canImport(Libbox)
#error("The pinned Libbox framework is required for this build configuration")
#endif

#if canImport(Libbox)
import Libbox

/// Matches libbox 1.13.12-extended-2.1.2's generated Objective-C protocols.
final class LibboxPlatformAdapter: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
  private weak var provider: NEPacketTunnelProvider?
  private let settingsCoordinator: TunnelSettingsCoordinator
  private let isCurrent: () -> Bool
  private let requestStop: () -> Void
  private let requestReload: () throws -> Void
  private let lock = NSLock()
  private var monitor: NWPathMonitor?
  private var path: Network.NWPath?
  private var networkSettings: NEPacketTunnelNetworkSettings?
  private let monitorQueue = DispatchQueue(label: "ru.honeyvpn.proxy.default-interface")

  init(provider: NEPacketTunnelProvider, settingsCoordinator: TunnelSettingsCoordinator, isCurrent: @escaping () -> Bool,
    requestStop: @escaping () -> Void, requestReload: @escaping () throws -> Void) {
    self.provider = provider
    self.settingsCoordinator = settingsCoordinator
    self.isCurrent = isCurrent
    self.requestStop = requestStop
    self.requestReload = requestReload
  }

  func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
  func usePlatformAutoDetectControl() -> Bool { false }
  func autoDetectControl(_ fd: Int32) throws { throw Self.error("Socket protection is supplied by the physical-interface monitor") }
  func useProcFS() -> Bool { false }
  func underNetworkExtension() -> Bool { true }
  func includeAllNetworks() -> Bool { provider?.protocolConfiguration.includeAllNetworks ?? false }
  func readWIFIState() -> LibboxWIFIState? { nil }
  // Pinned certificate/store.go falls back to x509.SystemCertPool if this is nil.
  func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

  func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
    destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
    throw Self.error("Process-based routing is unavailable in the sandboxed packet provider")
  }

  func send(_ notification: LibboxNotification?) throws {
    throw Self.error("Native VPN notifications are unavailable in this build")
  }

  func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    guard let options, let ret0_, isCurrent() else { throw Self.error("Packet tunnel startup was cancelled") }
    let dns = try options.getDNSServerAddress()
    let snapshot = PinnedTunnelOptionsSnapshot(
      ipv4Addresses: try Self.prefixes(options.getInet4Address()),
      ipv6Addresses: try Self.prefixes(options.getInet6Address()),
      ipv4Routes: try Self.prefixes(options.getInet4RouteAddress()),
      ipv6Routes: try Self.prefixes(options.getInet6RouteAddress()),
      ipv4ExcludedRoutes: try Self.prefixes(options.getInet4RouteExcludeAddress()),
      ipv6ExcludedRoutes: try Self.prefixes(options.getInet6RouteExcludeAddress()),
      dnsAddress: dns.value, mtu: Int(options.getMTU()), autoRoute: options.getAutoRoute())
    guard !options.isHTTPProxyEnabled() else { throw Self.error("System proxy mode is unavailable in the packet provider") }
    let settings = try TunnelNetworkSettingsMapper.make(snapshot)
    try applyNetworkSettings(settings)
    guard isCurrent() else { throw Self.error("Packet tunnel startup was cancelled") }
    let fd = LibboxGetTunnelFileDescriptor()
    guard fd >= 0 else { throw Self.error("NetworkExtension did not provide a tunnel descriptor") }
    lock.lock(); networkSettings = settings; lock.unlock()
    // The Go wrapper duplicates fd and owns the duplicate. NE owns the original.
    ret0_.pointee = fd
  }

  func clearDNSCache() {
    guard isCurrent(), let provider else { return }
    lock.lock(); let settings = networkSettings; lock.unlock()
    guard let settings else { return }
    provider.reasserting = true
    defer { provider.reasserting = false }
    do {
      try applyNetworkSettings(nil)
      if isCurrent() { try applyNetworkSettings(settings) }
    } catch { provider.cancelTunnelWithError(error) }
  }

  func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    guard let listener, isCurrent() else { throw Self.error("Missing default-interface listener") }
    let value = NWPathMonitor()
    let firstUpdate = DispatchSemaphore(value: 0)
    lock.lock(); monitor?.cancel(); monitor = value; path = nil; lock.unlock()
    value.pathUpdateHandler = { [weak self, weak value] currentPath in
      guard let self, let value, self.isCurrent() else { firstUpdate.signal(); return }
      self.lock.lock()
      let valid = self.monitor === value
      if valid { self.path = currentPath }
      self.lock.unlock()
      guard valid else { firstUpdate.signal(); return }
      let physical = currentPath.availableInterfaces.first {
        !$0.name.hasPrefix("utun") && currentPath.usesInterfaceType($0.type)
      }
      if currentPath.status == .satisfied, let physical {
        listener.updateDefaultInterface(physical.name, interfaceIndex: Int32(physical.index),
          isExpensive: currentPath.isExpensive, isConstrained: currentPath.isConstrained)
      } else {
        listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
      }
      firstUpdate.signal()
    }
    value.start(queue: monitorQueue)
    guard firstUpdate.wait(timeout: .now() + 10) == .success, isCurrent() else {
      reset()
      throw Self.error("The physical-network monitor did not initialize")
    }
  }

  func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { reset() }

  func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
    lock.lock(); let snapshot = path; lock.unlock()
    guard let snapshot else { throw Self.error("The physical-network monitor is not running") }
    let details = try Self.interfaceDetails()
    let interfaces = snapshot.availableInterfaces.filter { !$0.name.hasPrefix("utun") }.map { item in
      let result = LibboxNetworkInterface()
      result.name = item.name
      result.index = Int32(item.index)
      result.flags = details[item.name]?.flags ?? 0
      result.mtu = details[item.name]?.mtu ?? 0
      result.addresses = LibboxStringArray(details[item.name]?.addresses ?? [])
      result.dnsServer = LibboxStringArray([])
      result.metered = snapshot.isExpensive
      switch item.type {
      case .wifi: result.type = LibboxInterfaceTypeWIFI
      case .cellular: result.type = LibboxInterfaceTypeCellular
      case .wiredEthernet: result.type = LibboxInterfaceTypeEthernet
      default: result.type = LibboxInterfaceTypeOther
      }
      return result
    }
    return LibboxInterfaceArray(interfaces)
  }

  func serviceStop() throws { requestStop() }
  func serviceReload() throws { try requestReload() }
  func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
    let status = LibboxSystemProxyStatus(); status.available = false; status.enabled = false
    return status
  }
  func setSystemProxyEnabled(_ enabled: Bool) throws {
    if enabled { throw Self.error("System proxy mode is unavailable in this build") }
  }
  func writeDebugMessage(_ message: String?) {
    // Raw core logs may contain credentials or connection URLs. Keep them private.
  }

  func reset() {
    lock.lock(); let old = monitor; monitor = nil; path = nil; networkSettings = nil; lock.unlock()
    old?.cancel()
  }

  private func applyNetworkSettings(_ settings: NEPacketTunnelNetworkSettings?) throws {
    try settingsCoordinator.apply(settings, isCurrent: isCurrent)
  }

  private static func prefixes(_ iterator: LibboxRoutePrefixIteratorProtocol?) throws -> [PinnedRoutePrefix] {
    var values: [PinnedRoutePrefix] = []
    while iterator?.hasNext() == true {
      guard values.count < 65536, let item = iterator?.next() else { throw error("Invalid tunnel route iterator") }
      values.append(PinnedRoutePrefix(address: item.address(), prefix: Int(item.prefix())))
    }
    return values
  }

  private struct InterfaceDetails { var flags: Int32; var mtu: Int32; var addresses: [String] }

  private static func interfaceDetails() throws -> [String: InterfaceDetails] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { throw error("Could not enumerate physical network interfaces") }
    defer { freeifaddrs(first) }
    var details: [String: InterfaceDetails] = [:]
    var current = first
    while let value = current {
      defer { current = value.pointee.ifa_next }
      let entry = value.pointee
      guard let namePointer = entry.ifa_name else { continue }
      let name = String(cString: namePointer)
      var record = details[name] ?? InterfaceDetails(flags: Int32(entry.ifa_flags), mtu: 0, addresses: [])
      guard let address = entry.ifa_addr else { details[name] = record; continue }
      let family = Int32(address.pointee.sa_family)
      if family == AF_LINK, let data = entry.ifa_data {
        record.mtu = Int32(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
      } else if family == AF_INET || family == AF_INET6 {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
          let mask = entry.ifa_netmask {
          let prefix: Int
          if family == AF_INET {
            prefix = Int(UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.nonzeroBitCount)
          } else {
            var ipv6 = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            prefix = withUnsafeBytes(of: &ipv6) { bytes in bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
          }
          let unscoped = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
          if !unscoped.isEmpty { record.addresses.append("\(unscoped)/\(prefix)") }
        }
      }
      details[name] = record
    }
    return details
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: "HoneyProxyAppleVPN", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

final class LibboxStringArray: NSObject, LibboxStringIteratorProtocol {
  private let values: [String]
  private var index = 0
  init(_ values: [String]) { self.values = values }
  func len() -> Int32 { Int32(values.count - index) }
  func hasNext() -> Bool { index < values.count }
  func next() -> String { guard hasNext() else { return "" }; defer { index += 1 }; return values[index] }
}

private final class LibboxInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
  private let values: [LibboxNetworkInterface]
  private var index = 0
  init(_ values: [LibboxNetworkInterface]) { self.values = values }
  func hasNext() -> Bool { index < values.count }
  func next() -> LibboxNetworkInterface? { guard hasNext() else { return nil }; defer { index += 1 }; return values[index] }
}
#endif
