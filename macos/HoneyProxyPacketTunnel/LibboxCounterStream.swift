import Foundation

#if HONEYPROXY_LIBBOX_VALIDATED && !canImport(Libbox)
#error("The pinned Libbox framework is required for this build configuration")
#endif
#if canImport(Libbox)
import Libbox

/// Only the private authenticated CommandStatus stream is subscribed. Raw core
/// logs and connection destinations never enter the status reply.
final class LibboxCounterStream: NSObject, LibboxCommandClientHandlerProtocol {
  private let epoch = UUID()
  private let counters: AppleTrafficCounters
  private let isCurrent: () -> Bool
  private var client: LibboxCommandClient?

  init(counters: AppleTrafficCounters, isCurrent: @escaping () -> Bool) {
    self.counters = counters; self.isCurrent = isCurrent
  }

  func start() throws {
    counters.begin(epoch)
    let options = LibboxCommandClientOptions()
    options.statusInterval = 1_000_000_000 // Pinned API uses nanoseconds.
    options.addCommand(LibboxCommandStatus)
    guard let client = LibboxNewCommandClient(self, options) else {
      counters.end(epoch)
      throw NSError(domain: "HoneyProxyAppleVPN", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "VPN traffic statistics are unavailable"])
    }
    self.client = client
    do { try client.connect() }
    catch { stop(); throw error }
  }

  func stop() {
    counters.end(epoch)
    let previous = client; client = nil
    try? previous?.disconnect()
  }

  func connected() { if isCurrent() { counters.connected(epoch) } }
  func disconnected(_ message: String?) { counters.disconnected(epoch) }
  func writeStatus(_ message: LibboxStatusMessage?) {
    guard isCurrent(), let message else { counters.disconnected(epoch); return }
    // Pinned Uplink/Downlink are interval deltas, not normalized B/s. Derive
    // rates from actual cumulative totals and this monotonic arrival time.
    counters.accept(epoch, available: message.trafficAvailable,
      uplinkTotal: message.uplinkTotal, downlinkTotal: message.downlinkTotal,
      now: DispatchTime.now().uptimeNanoseconds)
  }
  func setDefaultLogLevel(_ level: Int32) {}
  func clearLogs() {}
  func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
  func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}
  func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
  func updateClashMode(_ newMode: String?) {}
  func write(_ events: LibboxConnectionEvents?) {}
}
#endif
