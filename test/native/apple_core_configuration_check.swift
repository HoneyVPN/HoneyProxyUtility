import Foundation
import Libbox

/// Fresh standalone process with a hardcoded direct-only fixture. CheckConfig
/// constructs and closes a Box; it never calls Start/PreStart. Arbitrary configs
/// are intentionally excluded: pinned Box.New can start an experimental debug
/// listener during construction when debug.listen is configured.
@main
struct CoreConfigurationCheck {
  static func main() throws {
    precondition(CommandLine.arguments.count == 1, "This check accepts no configuration input")
    precondition(LibboxVersion() == "1.13.12-extended-2.1.2", "Unexpected Libbox version")
    let original = #"{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}"#
    let savedOriginal = Data(original.utf8)
    let runtime = try AppleRuntimeConfiguration.withTrafficTracker(original)
    try validateSafeFixture(runtime)
    precondition(Data(original.utf8) == savedOriginal, "Runtime transformation changed the original configuration")
    let source = try JSONSerialization.jsonObject(with: savedOriginal) as! [String: Any]
    precondition(source["experimental"] == nil, "Persisted fixture unexpectedly contains a tracker")

    var error: NSError?
    guard LibboxCheckConfig(runtime, &error) else {
      throw error ?? NSError(domain: "HoneyProxyNativeCheck", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Pinned core rejected its private tracker configuration"])
    }
    precondition(error == nil)

    // A literal incomplete JSON document must fail parsing before any Box is
    // constructed. No user/imported data or optional service config is tested.
    error = nil
    precondition(!LibboxCheckConfig("{", &error) && error != nil, "Malformed config was accepted")
    print("Pinned Libbox version and private Clash tracker schema verified; malformed JSON rejected. Original unchanged. No service, sockets, tunnel, routes or profiles started.")
  }

  private static func validateSafeFixture(_ content: String) throws {
    let config = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
    // An exact allowlist also excludes DNS, endpoints, certificates, rule sets,
    // cache paths and log paths before the real native constructor is called.
    precondition(Set(config.keys) == ["log", "outbounds", "route", "experimental"])
    let log = config["log"] as! [String: Any]
    precondition(Set(log.keys) == ["disabled"] && log["disabled"] as? Bool == true)
    let outbounds = config["outbounds"] as! [[String: Any]]
    precondition(outbounds.count == 1 && Set(outbounds[0].keys) == ["type", "tag"])
    precondition(outbounds[0]["type"] as? String == "direct" && outbounds[0]["tag"] as? String == "direct")
    let route = config["route"] as! [String: Any]
    precondition(Set(route.keys) == ["final"] && route["final"] as? String == "direct")
    let experimental = config["experimental"] as! [String: Any]
    precondition(Set(experimental.keys) == ["clash_api"])
    let clash = experimental["clash_api"] as! [String: Any]
    precondition(Set(clash.keys) == ["external_controller"] && clash["external_controller"] as? String == "")
  }
}
