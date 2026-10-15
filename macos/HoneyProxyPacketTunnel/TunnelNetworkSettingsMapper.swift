// Maps a validated snapshot of pinned libbox TUN options into NetworkExtension settings.
import Darwin
import Foundation
import NetworkExtension

struct PinnedRoutePrefix {
  let address: String
  let prefix: Int
}

struct PinnedTunnelOptionsSnapshot {
  let ipv4Addresses: [PinnedRoutePrefix]
  let ipv6Addresses: [PinnedRoutePrefix]
  let ipv4Routes: [PinnedRoutePrefix]
  let ipv6Routes: [PinnedRoutePrefix]
  let ipv4ExcludedRoutes: [PinnedRoutePrefix]
  let ipv6ExcludedRoutes: [PinnedRoutePrefix]
  let dnsAddress: String
  let mtu: Int
  let autoRoute: Bool
}

enum TunnelSettingsMappingError: Error {
  case invalidAddress(String)
  case invalidPrefix(Int)
  case invalidMTU(Int)
  case unsupportedRouteMode
  case missingAddressFamily
}

enum TunnelNetworkSettingsMapper {
  static func make(_ input: PinnedTunnelOptionsSnapshot) throws -> NEPacketTunnelNetworkSettings {
    guard input.autoRoute else { throw TunnelSettingsMappingError.unsupportedRouteMode }
    guard !input.ipv4Addresses.isEmpty && !input.ipv6Addresses.isEmpty else {
      throw TunnelSettingsMappingError.missingAddressFamily
    }
    guard (1280...65535).contains(input.mtu) else {
      throw TunnelSettingsMappingError.invalidMTU(input.mtu)
    }
    guard isAddress(input.dnsAddress, family: AF_INET) || isAddress(input.dnsAddress, family: AF_INET6) else {
      throw TunnelSettingsMappingError.invalidAddress(input.dnsAddress)
    }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = NSNumber(value: input.mtu)
    let v4 = NEIPv4Settings(addresses: try input.ipv4Addresses.map { try checkedAddress($0, family: AF_INET) },
      subnetMasks: try input.ipv4Addresses.map { try ipv4Mask($0.prefix) })
    v4.includedRoutes = input.ipv4Routes.isEmpty ? [.default()] : try input.ipv4Routes.map(ipv4Route)
    v4.excludedRoutes = try input.ipv4ExcludedRoutes.map(ipv4Route)
    settings.ipv4Settings = v4

    let v6 = NEIPv6Settings(addresses: try input.ipv6Addresses.map { try checkedAddress($0, family: AF_INET6) },
      networkPrefixLengths: try input.ipv6Addresses.map { NSNumber(value: try checkedPrefix($0.prefix, maximum: 128)) })
    v6.includedRoutes = input.ipv6Routes.isEmpty ? [.default()] : try input.ipv6Routes.map(ipv6Route)
    v6.excludedRoutes = try input.ipv6ExcludedRoutes.map(ipv6Route)
    settings.ipv6Settings = v6

    let dns = NEDNSSettings(servers: [input.dnsAddress])
    dns.matchDomains = [""]
    dns.matchDomainsNoSearch = true
    settings.dnsSettings = dns
    return settings
  }

  private static func ipv4Route(_ route: PinnedRoutePrefix) throws -> NEIPv4Route {
    NEIPv4Route(destinationAddress: try checkedAddress(route, family: AF_INET), subnetMask: try ipv4Mask(route.prefix))
  }

  private static func ipv6Route(_ route: PinnedRoutePrefix) throws -> NEIPv6Route {
    NEIPv6Route(destinationAddress: try checkedAddress(route, family: AF_INET6),
      networkPrefixLength: NSNumber(value: try checkedPrefix(route.prefix, maximum: 128)))
  }

  private static func checkedAddress(_ route: PinnedRoutePrefix, family: Int32) throws -> String {
    guard isAddress(route.address, family: family) else {
      throw TunnelSettingsMappingError.invalidAddress(route.address)
    }
    return route.address
  }

  private static func isAddress(_ address: String, family: Int32) -> Bool {
    var storage = in6_addr()
    return inet_pton(family, address, &storage) == 1
  }

  private static func checkedPrefix(_ prefix: Int, maximum: Int) throws -> Int {
    guard (0...maximum).contains(prefix) else { throw TunnelSettingsMappingError.invalidPrefix(prefix) }
    return prefix
  }

  private static func ipv4Mask(_ prefix: Int) throws -> String {
    let bits = try checkedPrefix(prefix, maximum: 32)
    let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
    return [24, 16, 8, 0].map { String((mask >> $0) & 255) }.joined(separator: ".")
  }
}
