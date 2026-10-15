import CoreFoundation
import Foundation

struct AppleProviderSessionIdentity {
  let sessionId: UUID
  let profileId: Int64

  init(options: [String: NSObject]?) throws {
    guard let text = options?["sessionId"] as? String, let sessionId = UUID(uuidString: text),
      let name = options?["configurationFile"] as? String,
      name.hasPrefix("session-"), name.hasSuffix(".json"),
      UUID(uuidString: String(name.dropFirst(8).dropLast(5))) == sessionId,
      let number = options?["profileId"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.stringValue.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
      let profileId = Int64(number.stringValue), profileId > 0 else {
      throw NSError(domain: "HoneyProxyAppleVPN", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Invalid VPN session identity"])
    }
    self.sessionId = sessionId
    self.profileId = profileId
  }

  func fields(startedAtUptime: UInt64, now: UInt64) -> [String: Any] {
    ["sessionId": sessionId.uuidString, "profileId": profileId,
      "duration": Int64((now >= startedAtUptime ? now - startedAtUptime : 0) / 1_000_000_000)]
  }
}

enum AppleRuntimeConfiguration {
  static func withTrafficTracker(_ original: String) throws -> String {
    guard let data = original.data(using: .utf8),
      var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "HoneyProxyAppleVPN", code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Invalid VPN runtime configuration"])
    }
    var experimental = config["experimental"] as? [String: Any] ?? [:]
    var clash = experimental["clash_api"] as? [String: Any] ?? [:]
    // In the exact pin, Clash's traffic tracker exists with an empty controller;
    // net.Listen and UI downloads occur only when externalController != "".
    clash["external_controller"] = ""
    experimental["clash_api"] = clash
    config["experimental"] = experimental
    return String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
  }
}

/// Stores measured core counters only. First/reset samples have totals but no
/// rates; disconnected or stale samples are explicitly unavailable.
final class AppleTrafficCounters {
  private struct Sample {
    let uptime: UInt64
    let uplinkTotal: Int64
    let downlinkTotal: Int64
    let uplink: Int64?
    let downlink: Int64?
  }
  private let lock = NSLock()
  private var epoch: UUID?
  private var connected = false
  private var sample: Sample?
  private let maximumAge: UInt64 = 3_000_000_000

  func begin(_ epoch: UUID) { lock.lock(); defer { lock.unlock() }; self.epoch = epoch; connected = false; sample = nil }
  func connected(_ epoch: UUID) { lock.lock(); defer { lock.unlock() }; if self.epoch == epoch { connected = true } }
  func disconnected(_ epoch: UUID) { lock.lock(); defer { lock.unlock() }; if self.epoch == epoch { connected = false; sample = nil } }
  func end(_ epoch: UUID) { lock.lock(); defer { lock.unlock() }; if self.epoch == epoch { self.epoch = nil; connected = false; sample = nil } }
  func clear() { lock.lock(); defer { lock.unlock() }; epoch = nil; connected = false; sample = nil }

  func accept(_ epoch: UUID, available: Bool, uplinkTotal: Int64, downlinkTotal: Int64, now: UInt64) {
    lock.lock(); defer { lock.unlock() }
    guard self.epoch == epoch, connected else { return }
    guard available, uplinkTotal >= 0, downlinkTotal >= 0 else { sample = nil; return }
    if let previous = sample, now <= previous.uptime { return }
    var uplink: Int64?
    var downlink: Int64?
    if let previous = sample, now - previous.uptime <= maximumAge,
      uplinkTotal >= previous.uplinkTotal, downlinkTotal >= previous.downlinkTotal {
      let elapsed = now - previous.uptime
      uplink = Self.rate(bytes: uplinkTotal - previous.uplinkTotal, elapsed: elapsed)
      downlink = Self.rate(bytes: downlinkTotal - previous.downlinkTotal, elapsed: elapsed)
    }
    sample = Sample(uptime: now, uplinkTotal: uplinkTotal, downlinkTotal: downlinkTotal, uplink: uplink, downlink: downlink)
  }

  func fields(running: Bool, now: UInt64) -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    guard running, epoch != nil, connected, let sample,
      now >= sample.uptime, now - sample.uptime <= maximumAge else {
      return ["trafficAvailable": false, "ratesAvailable": false]
    }
    var fields: [String: Any] = ["trafficAvailable": true, "ratesAvailable": false,
      "uplinkTotal": sample.uplinkTotal, "downlinkTotal": sample.downlinkTotal]
    if let uplink = sample.uplink, let downlink = sample.downlink {
      fields["ratesAvailable"] = true; fields["uplink"] = uplink; fields["downlink"] = downlink
    }
    return fields
  }

  private static func rate(bytes: Int64, elapsed: UInt64) -> Int64? {
    guard elapsed > 0 else { return nil }
    let value = Double(bytes) * 1_000_000_000 / Double(elapsed)
    guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
    return Int64(value)
  }
}
