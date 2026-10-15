import Foundation
import NetworkExtension

protocol TunnelSettingsHost: AnyObject {
  func applyTunnelSettings(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping (Error?) -> Void)
  func cancelSettingsTunnel(_ error: Error)
}

/// A new tunnel cannot begin while the previous generation still owns teardown.
/// Failed settings cleanup permanently rejects reuse of this provider instance;
/// a late success or duplicate stop cannot erase that uncertainty.
final class TunnelTeardownGate {
  private let lock = NSLock()
  private var generation: UInt64?
  private var poisoned = false

  var allowsStart: Bool {
    lock.lock(); defer { lock.unlock() }
    return generation == nil && !poisoned
  }

  func begin(_ generation: UInt64) {
    lock.lock(); defer { lock.unlock() }
    self.generation = generation
  }

  func finish(_ generation: UInt64, confirmed: Bool) {
    lock.lock(); defer { lock.unlock() }
    if !confirmed { poisoned = true; return }
    if self.generation == generation && !poisoned { self.generation = nil }
  }
}

extension NEPacketTunnelProvider: TunnelSettingsHost {
  func applyTunnelSettings(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping (Error?) -> Void) {
    setTunnelNetworkSettings(settings, completionHandler: completion)
  }
  func cancelSettingsTunnel(_ error: Error) { cancelTunnelWithError(error) }
}

/// Serializes NE settings requests from Go callbacks and provider teardown.
/// A timed-out request poisons this provider instance so late callbacks cannot
/// race a new non-nil configuration into an apparently successful session.
final class TunnelSettingsCoordinator {
  private weak var provider: TunnelSettingsHost?
  private let serial = NSLock()
  private var poisoned = false
  private let timeout: TimeInterval
  private let waitForResponse: (DispatchSemaphore, TimeInterval) -> DispatchTimeoutResult

  init(provider: TunnelSettingsHost, timeout: TimeInterval = 5,
    waitForResponse: @escaping (DispatchSemaphore, TimeInterval) -> DispatchTimeoutResult = { semaphore, timeout in semaphore.wait(timeout: .now() + timeout) }) {
    self.provider = provider; self.timeout = timeout; self.waitForResponse = waitForResponse
  }

  func apply(_ settings: NEPacketTunnelNetworkSettings?, isCurrent: () -> Bool) throws {
    guard !Thread.isMainThread else { throw Self.error("Tunnel settings must run on the core worker queue") }
    serial.lock(); defer { serial.unlock() }
    guard let provider, isCurrent(), !poisoned || settings == nil else {
      throw Self.error("Packet tunnel operation was cancelled")
    }
    let done = DispatchSemaphore(value: 0)
    let response = TunnelSettingsResponse()
    provider.applyTunnelSettings(settings) { [weak provider] error in
      let timedOut = response.complete(error)
      done.signal()
      // This instance rejects further non-nil settings once poisoned. Clearing
      // a late request cannot overwrite a newly accepted session's routes.
      if timedOut { provider?.applyTunnelSettings(nil) { _ in } }
    }
    guard waitForResponse(done, timeout) == .success else {
      poisoned = true
      // A callback may finish between wait timing out and this atomic mark.
      // Either that callback or this branch must clear the late settings.
      if response.markTimedOut() { provider.applyTunnelSettings(nil) { _ in } }
      let error = Self.error("NetworkExtension did not confirm tunnel settings")
      provider.cancelSettingsTunnel(error)
      throw error
    }
    if let error = response.error { throw error }
    guard isCurrent() else { throw Self.error("Packet tunnel operation was cancelled") }
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "HoneyProxyAppleVPN", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private final class TunnelSettingsResponse {
  private let lock = NSLock()
  private var value: Error?
  private var timedOut = false
  private var completed = false
  var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
  func complete(_ error: Error?) -> Bool { lock.lock(); defer { lock.unlock() }; value = error; completed = true; return timedOut }
  func markTimedOut() -> Bool { lock.lock(); defer { lock.unlock() }; timedOut = true; return completed }
}
