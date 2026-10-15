import Foundation
import NetworkExtension

@main
struct MapperCheck {
  static func main() throws {
    func input(dns: String = "172.19.0.2", mtu: Int = 1500, prefix: Int = 30, autoRoute: Bool = true,
      ipv4Routes: [PinnedRoutePrefix] = [], ipv4Excludes: [PinnedRoutePrefix] = []) -> PinnedTunnelOptionsSnapshot {
      PinnedTunnelOptionsSnapshot(ipv4Addresses: [.init(address: "172.19.0.1", prefix: prefix)],
        ipv6Addresses: [.init(address: "fdfe:dcba:9876::1", prefix: 126)],
        ipv4Routes: ipv4Routes, ipv6Routes: [], ipv4ExcludedRoutes: ipv4Excludes,
        ipv6ExcludedRoutes: [], dnsAddress: dns, mtu: mtu, autoRoute: autoRoute)
    }
    let all = try TunnelNetworkSettingsMapper.make(input())
    precondition(all.ipv4Settings?.subnetMasks == ["255.255.255.252"])
    precondition(all.ipv4Settings?.includedRoutes?.first?.destinationAddress == "0.0.0.0")
    precondition(all.ipv6Settings?.includedRoutes?.first?.destinationAddress == "::")
    precondition(all.ipv6Settings?.networkPrefixLengths == [126])
    precondition(all.dnsSettings?.servers == ["172.19.0.2"] && all.dnsSettings?.matchDomains == [""])
    precondition(all.mtu?.intValue == 1500)

    let selective = try TunnelNetworkSettingsMapper.make(input(ipv4Routes: [.init(address: "10.0.0.0", prefix: 8)],
      ipv4Excludes: [.init(address: "10.1.0.0", prefix: 16)]))
    precondition(selective.ipv4Settings?.includedRoutes?.count == 1)
    precondition(selective.ipv4Settings?.includedRoutes?.first?.destinationSubnetMask == "255.0.0.0")
    precondition(selective.ipv4Settings?.excludedRoutes?.first?.destinationAddress == "10.1.0.0")

    for invalid in [input(dns: "bad DNS"), input(mtu: 1000), input(prefix: 33), input(autoRoute: false)] {
      do { _ = try TunnelNetworkSettingsMapper.make(invalid); preconditionFailure("Invalid input accepted") }
      catch is TunnelSettingsMappingError {}
    }
    print("Mapper checks passed: dual-stack defaults, DNS, MTU, selective routes and invalid inputs. No routes installed.")
  }
}
