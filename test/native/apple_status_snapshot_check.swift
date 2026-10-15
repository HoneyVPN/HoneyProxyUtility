import Foundation

@main
struct SnapshotCheck {
  static func main() throws {
    let session = UUID().uuidString
    var value: [String: Any] = ["version": 1, "running": true, "coreReady": true,
      "sessionId": session, "profileId": Int64(19), "duration": 12,
      "trafficAvailable": true, "ratesAvailable": true,
      "uplinkTotal": Int64(4096), "downlinkTotal": Int64(8192), "uplink": 0, "downlink": 512,
      "configuration": "must-not-cross-channel"]
    func decode(_ v: [String: Any]) throws -> [String: Any]? {
      AppleVpnStatusSnapshot.decode(try JSONSerialization.data(withJSONObject: v))
    }
    let good = try decode(value)!
    precondition(good["running"] as? Bool == true, "Dart requires the sanitized connected packet to preserve running")
    precondition(good["profileId"] as? Int64 == 19)
    precondition(good["sessionId"] as? String == session)
    precondition(good["uplink"] as? Int64 == 0, "Measured zero is a valid rate")
    precondition(good["configuration"] == nil)
    for bad in [true as Any, 19.5 as Any, -1 as Any, 0 as Any, "19" as Any, NSNumber(value: UInt64.max)] {
      var v = value; v["profileId"] = bad
      let rejected = try decode(v)
      precondition(rejected == nil)
    }
    for key in ["version", "sessionId", "profileId", "duration", "running", "coreReady"] {
      var v = value; v.removeValue(forKey: key)
      let rejected = try decode(v)
      precondition(rejected == nil)
    }
    for (key, bad) in [("version", 2 as Any), ("sessionId", "invalid" as Any),
      ("running", 1 as Any), ("coreReady", false as Any), ("duration", -1 as Any)] {
      var v = value; v[key] = bad
      let rejected = try decode(v)
      precondition(rejected == nil)
    }
    value["downlink"] = -1
    let noRates = try decode(value)!
    precondition(noRates["trafficAvailable"] as? Bool == true)
    precondition(noRates["ratesAvailable"] as? Bool == false)
    precondition(noRates["uplink"] == nil && noRates["downlink"] == nil)
    value["uplinkTotal"] = true
    let noTraffic = try decode(value)!
    precondition(noTraffic["trafficAvailable"] as? Bool == false)
    precondition(noTraffic["uplinkTotal"] == nil)
    precondition(AppleVpnStatusSnapshot.decode(Data(repeating: 32, count: 16385)) == nil)
    precondition(AppleVpnStatusSnapshot.decode(nil) == nil)
    let count = LockedCount()
    let reply = AppleVpnSnapshotReply { _ in count.increment() }
    DispatchQueue.concurrentPerform(iterations: 250) { _ in reply.finish([:]) }
    precondition(count.value == 1, "Reply/deadline races must complete exactly once")
    print("Apple status snapshot checks passed: identity, bounds, real zero, unavailable counters, concurrent completion")
  }
}

private final class LockedCount {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); count += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
