import Foundation

@main
struct ProviderStatusCheck {
  static func main() throws {
    try checkIdentity()
    try checkRuntimeConfiguration()
    checkTrafficCounters()
    print("Provider status checks passed: session identity, immutable private tracker, measured rates, unavailable/reset/stale samples and cancelled-session isolation. No core or OS routes started.")
  }

  private static func checkIdentity() throws {
    let id = UUID()
    func options(_ profile: NSObject = NSNumber(value: Int64.max), session: String? = nil, file: String? = nil) -> [String: NSObject] {
      ["sessionId": (session ?? id.uuidString) as NSString,
       "configurationFile": (file ?? "session-\(id.uuidString).json") as NSString,
       "profileId": profile]
    }
    let identity = try AppleProviderSessionIdentity(options: options())
    precondition(identity.sessionId == id && identity.profileId == Int64.max)
    precondition(identity.fields(startedAtUptime: 1_000_000_000, now: 3_999_999_999)["duration"] as? Int64 == 2)
    precondition(identity.fields(startedAtUptime: 4_000_000_000, now: 1_000_000_000)["duration"] as? Int64 == 0)
    let invalid: [[String: NSObject]?] = [
      nil, options(NSNumber(value: true)), options(NSNumber(value: 0)),
      options(NSNumber(value: -1)), options(NSNumber(value: 1.5)),
      options(NSNumber(value: UInt64.max)), options("7" as NSString),
      options(session: "invalid"), options(file: "session-\(UUID().uuidString).json"),
      options(file: "../session-\(id.uuidString).json"), options(file: "session-\(id.uuidString).json.bak")
    ]
    for candidate in invalid {
      do { _ = try AppleProviderSessionIdentity(options: candidate); preconditionFailure("Invalid session identity accepted") }
      catch {}
    }
  }

  private static func checkRuntimeConfiguration() throws {
    let original = #"{"inbounds":[{"type":"tun"}],"outbounds":[{"type":"direct"}],"experimental":{"cache_file":{"enabled":true},"clash_api":{"external_controller":"127.0.0.1:9090","secret":"keep-existing-value"}}}"#
    let runtime = try AppleRuntimeConfiguration.withTrafficTracker(original)
    let config = try JSONSerialization.jsonObject(with: Data(runtime.utf8)) as! [String: Any]
    let experiment = config["experimental"] as! [String: Any]
    let clash = experiment["clash_api"] as! [String: Any]
    precondition(clash["external_controller"] as? String == "")
    precondition(clash["secret"] as? String == "keep-existing-value")
    precondition((experiment["cache_file"] as? [String: Any])?["enabled"] as? Bool == true)
    precondition((config["outbounds"] as? [[String: Any]])?.first?["type"] as? String == "direct")
    let saved = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]
    precondition(((saved["experimental"] as? [String: Any])?["clash_api"] as? [String: Any])?["external_controller"] as? String == "127.0.0.1:9090")
    for invalid in ["[]", "invalid"] {
      do { _ = try AppleRuntimeConfiguration.withTrafficTracker(invalid); preconditionFailure("Invalid runtime configuration accepted") }
      catch {}
    }
    let empty = try AppleRuntimeConfiguration.withTrafficTracker("{}")
    precondition(!empty.contains("127.0.0.1") && empty.contains("external_controller"))
  }

  private static func checkTrafficCounters() {
    let store = AppleTrafficCounters()
    let first = UUID()
    func unavailable(_ value: [String: Any]) {
      precondition(value["trafficAvailable"] as? Bool == false && value["ratesAvailable"] as? Bool == false)
      precondition(value["uplink"] == nil && value["downlink"] == nil && value["uplinkTotal"] == nil && value["downlinkTotal"] == nil)
    }
    unavailable(store.fields(running: true, now: 1_000_000_000))
    store.begin(first)
    // Samples delivered before the command stream handshake cannot become data.
    store.accept(first, available: true, uplinkTotal: 999, downlinkTotal: 999, now: 1_000_000_000)
    unavailable(store.fields(running: true, now: 1_000_000_000))
    store.connected(first)
    store.accept(first, available: true, uplinkTotal: 100, downlinkTotal: 200, now: 1_000_000_000)
    let initial = store.fields(running: true, now: 1_000_000_000)
    precondition(initial["trafficAvailable"] as? Bool == true && initial["ratesAvailable"] as? Bool == false)
    precondition(initial["uplinkTotal"] as? Int64 == 100 && initial["downlinkTotal"] as? Int64 == 200 && initial["uplink"] == nil)
    store.accept(first, available: true, uplinkTotal: 1_100, downlinkTotal: 2_200, now: 3_000_000_000)
    let measured = store.fields(running: true, now: 3_000_000_000)
    precondition(measured["ratesAvailable"] as? Bool == true)
    precondition(measured["uplink"] as? Int64 == 500 && measured["downlink"] as? Int64 == 1_000)
    // A duplicate or earlier timestamp must not replace a valid fresh sample.
    store.accept(first, available: true, uplinkTotal: 9_999, downlinkTotal: 9_999, now: 3_000_000_000)
    store.accept(first, available: true, uplinkTotal: 9_999, downlinkTotal: 9_999, now: 2_000_000_000)
    precondition(store.fields(running: true, now: 3_000_000_000)["uplinkTotal"] as? Int64 == 1_100)
    unavailable(store.fields(running: true, now: 6_000_000_001))
    unavailable(store.fields(running: false, now: 3_000_000_000))
    // Reset/decreasing totals are real totals but cannot imply a negative rate.
    store.accept(first, available: true, uplinkTotal: 10, downlinkTotal: 20, now: 4_000_000_000)
    let reset = store.fields(running: true, now: 4_000_000_000)
    precondition(reset["trafficAvailable"] as? Bool == true && reset["ratesAvailable"] as? Bool == false && reset["uplink"] == nil)
    store.accept(first, available: false, uplinkTotal: 10, downlinkTotal: 20, now: 5_000_000_000)
    unavailable(store.fields(running: true, now: 5_000_000_000))
    store.accept(first, available: true, uplinkTotal: -1, downlinkTotal: 20, now: 6_000_000_000)
    unavailable(store.fields(running: true, now: 6_000_000_000))
    store.accept(first, available: true, uplinkTotal: 10, downlinkTotal: 20, now: 7_000_000_000)
    store.accept(first, available: true, uplinkTotal: 20, downlinkTotal: 30, now: 11_000_000_000)
    precondition(store.fields(running: true, now: 11_000_000_000)["ratesAvailable"] as? Bool == false)
    store.accept(first, available: true, uplinkTotal: Int64.max, downlinkTotal: Int64.max, now: 11_000_000_001)
    let overflow = store.fields(running: true, now: 11_000_000_001)
    precondition(overflow["trafficAvailable"] as? Bool == true && overflow["ratesAvailable"] as? Bool == false && overflow["uplink"] == nil)
    store.end(first)
    unavailable(store.fields(running: true, now: 12_000_000_000))
    let next = UUID()
    store.begin(next); store.connected(next)
    store.accept(next, available: true, uplinkTotal: 7, downlinkTotal: 8, now: 12_000_000_000)
    store.connected(first); store.accept(first, available: true, uplinkTotal: 999, downlinkTotal: 999, now: 13_000_000_000)
    store.disconnected(first); store.end(first)
    precondition(store.fields(running: true, now: 13_000_000_000)["uplinkTotal"] as? Int64 == 7)
    store.disconnected(next)
    unavailable(store.fields(running: true, now: 13_000_000_000))
    store.clear()
  }
}
