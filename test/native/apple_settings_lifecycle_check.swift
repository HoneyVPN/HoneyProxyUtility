import Foundation
import NetworkExtension

private final class SettingsProviderProbe: TunnelSettingsHost {
  var autoCompleteNil = true
  private let lock = NSLock()
  private var callbacks: [((Error?) -> Void)?] = []
  private var values: [NEPacketTunnelNetworkSettings?] = []
  private var cancellations = 0
  var requestCount: Int { lock.lock(); defer { lock.unlock() }; return values.count }
  var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
  var lastWasNil: Bool { lock.lock(); defer { lock.unlock() }; return values.last.map { $0 == nil } ?? false }

  func applyTunnelSettings(_ tunnelNetworkSettings: NEPacketTunnelNetworkSettings?, completion: @escaping (Error?) -> Void) {
    lock.lock(); values.append(tunnelNetworkSettings); callbacks.append(completion); lock.unlock()
    if tunnelNetworkSettings == nil && autoCompleteNil { completion(nil) }
  }
  func cancelSettingsTunnel(_ error: Error) { lock.lock(); cancellations += 1; lock.unlock() }
  func complete(_ index: Int) { lock.lock(); let callback = callbacks[index]; lock.unlock(); callback?(nil) }
}

@main
struct SettingsLifecycleCheck {
  static func main() {
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let provider = SettingsProviderProbe()
      let coordinator = TunnelSettingsCoordinator(provider: provider, timeout: 0.05)
      do { try coordinator.apply(NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1"), isCurrent: { true }); preconditionFailure("Missing callback accepted") }
      catch {}
      precondition(provider.cancelCount == 1 && provider.requestCount == 1)
      do { try coordinator.apply(NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1"), isCurrent: { true }); preconditionFailure("Poisoned provider accepted a new session") }
      catch {}
      precondition(provider.requestCount == 1)
      provider.complete(0)
      precondition(provider.lastWasNil && provider.requestCount == 2)

      let boundaryProvider = SettingsProviderProbe()
      let boundary = TunnelSettingsCoordinator(provider: boundaryProvider, waitForResponse: { _, _ in
        // Reproduce callback completion after the wait's timeout decision but
        // before the coordinator atomically records that timeout.
        boundaryProvider.complete(0)
        return .timedOut
      })
      do { try boundary.apply(NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1"), isCurrent: { true }); preconditionFailure("Boundary timeout accepted") }
      catch {}
      precondition(boundaryProvider.cancelCount == 1 && boundaryProvider.requestCount == 2 && boundaryProvider.lastWasNil)

      let cancelledProvider = SettingsProviderProbe()
      let cancelled = TunnelSettingsCoordinator(provider: cancelledProvider, timeout: 0.05)
      do { try cancelled.apply(nil, isCurrent: { false }); preconditionFailure("Cancelled generation accepted") }
      catch {}
      precondition(cancelledProvider.requestCount == 0)

      let serialProvider = SettingsProviderProbe()
      let serial = TunnelSettingsCoordinator(provider: serialProvider, timeout: 1)
      let group = DispatchGroup()
      group.enter()
      DispatchQueue.global().async {
        try! serial.apply(NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1"), isCurrent: { true })
        group.leave()
      }
      while serialProvider.requestCount == 0 { Thread.sleep(forTimeInterval: 0.001) }
      group.enter()
      DispatchQueue.global().async { try! serial.apply(nil, isCurrent: { true }); group.leave() }
      Thread.sleep(forTimeInterval: 0.02)
      precondition(serialProvider.requestCount == 1)
      serialProvider.complete(0)
      precondition(group.wait(timeout: .now() + 2) == .success)
      precondition(serialProvider.requestCount == 2 && serialProvider.lastWasNil)

      let teardownProvider = SettingsProviderProbe()
      teardownProvider.autoCompleteNil = false
      let teardownSettings = TunnelSettingsCoordinator(provider: teardownProvider, timeout: 1)
      let gate = TunnelTeardownGate()
      precondition(gate.allowsStart)
      let firstStop = DispatchSemaphore(value: 0)
      gate.begin(1)
      DispatchQueue.global().async {
        try! teardownSettings.apply(nil, isCurrent: { true })
        gate.finish(1, confirmed: true)
        firstStop.signal()
      }
      while teardownProvider.requestCount == 0 { Thread.sleep(forTimeInterval: 0.001) }
      precondition(!gate.allowsStart)
      // Duplicate/system rapid stop now owns teardown; the old callback must
      // not allow a start while this newer stop still awaits NE confirmation.
      gate.begin(2)
      teardownProvider.complete(0)
      precondition(firstStop.wait(timeout: .now() + 2) == .success)
      precondition(!gate.allowsStart)
      let secondStop = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        try! teardownSettings.apply(nil, isCurrent: { true })
        gate.finish(2, confirmed: true)
        secondStop.signal()
      }
      while teardownProvider.requestCount < 2 { Thread.sleep(forTimeInterval: 0.001) }
      precondition(!gate.allowsStart)
      teardownProvider.complete(1)
      precondition(secondStop.wait(timeout: .now() + 2) == .success && gate.allowsStart)

      let failedProvider = SettingsProviderProbe()
      failedProvider.autoCompleteNil = false
      let failedSettings = TunnelSettingsCoordinator(provider: failedProvider, timeout: 0.05)
      let failedGate = TunnelTeardownGate()
      failedGate.begin(1)
      do { try failedSettings.apply(nil, isCurrent: { true }); preconditionFailure("Unconfirmed teardown accepted") }
      catch { failedGate.finish(1, confirmed: false) }
      failedProvider.complete(0)
      precondition(failedProvider.requestCount == 2 && !failedGate.allowsStart)
      failedGate.begin(2); failedGate.finish(2, confirmed: true)
      precondition(!failedGate.allowsStart)
      print("Native settings lifecycle checks passed: timeout boundary, late cleanup, cancellation, serialized stop, rapid-stop ownership and failed teardown rejecting provider reuse. No OS routes installed.")
      finished.signal()
    }
    precondition(finished.wait(timeout: .now() + 5) == .success)
  }
}
