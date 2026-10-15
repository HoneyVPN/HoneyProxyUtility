import Foundation
import CoreFoundation

/// Accept only the bounded, versioned telemetry produced by our extension.
/// Configuration, filenames and error strings never cross this channel.
enum AppleVpnStatusSnapshot {
  static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
      number.compare(NSNumber(value: Int64(0))) != .orderedAscending,
      number.compare(NSNumber(value: Int64.max)) != .orderedDescending
    else { return nil }
    return number.int64Value
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  static func decode(_ data: Data?) -> [String: Any]? {
    guard let data, !data.isEmpty, data.count <= 16384,
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      integer(value["version"]) == 1,
      boolean(value["running"]) == true,
      boolean(value["coreReady"]) == true,
      let session = value["sessionId"] as? String, let uuid = UUID(uuidString: session),
      let profile = integer(value["profileId"]), profile > 0,
      let duration = integer(value["duration"])
    else { return nil }
    var result: [String: Any] = ["version": 1, "coreReady": true, "running": true,
      "sessionId": uuid.uuidString, "profileId": profile, "duration": duration,
      "trafficAvailable": false, "ratesAvailable": false]
    if boolean(value["trafficAvailable"]) == true,
      let upload = integer(value["uplinkTotal"]), let download = integer(value["downlinkTotal"]) {
      result["trafficAvailable"] = true
      result["uplinkTotal"] = upload
      result["downlinkTotal"] = download
      if boolean(value["ratesAvailable"]) == true,
        let upRate = integer(value["uplink"]), let downRate = integer(value["downlink"]) {
        result["ratesAvailable"] = true
        result["uplink"] = upRate
        result["downlink"] = downRate
      }
    }
    return result
  }
}

/// Provider replies can race their deadline. Exactly one result reaches Flutter.
final class AppleVpnSnapshotReply {
  private let lock = NSLock()
  private var completion: (([String: Any]) -> Void)?
  init(_ completion: @escaping ([String: Any]) -> Void) { self.completion = completion }
  func finish(_ value: [String: Any]) {
    lock.lock()
    let callback = completion
    completion = nil
    lock.unlock()
    callback?(value)
  }
}
