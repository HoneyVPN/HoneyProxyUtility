import Foundation
import Security

/// Local routing QA is explicitly enabled only in signed development builds.
/// A release or ad-hoc preview retains the normal unavailable readiness marker.
enum DevelopmentVpnGate {
  static func allows(_ bundle: Bundle) -> Bool {
    #if DEBUG && HONEYPROXY_DEVELOPMENT_VPN
    return hasDevelopmentSignature(bundle)
    #else
    return false
    #endif
  }

  static func hasDevelopmentSignature(_ bundle: Bundle) -> Bool {
    guard let executable = bundle.executableURL else { return false }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
      let code else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    else { return false }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
      let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certificates.first,
      let name = SecCertificateCopySubjectSummary(leaf) as String?,
      ["Apple Development:", "Mac Developer:", "iPhone Developer:"].contains(where: { name.hasPrefix($0) }),
      let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let groups = entitlements["com.apple.security.application-groups"] as? [String],
      groups.contains("group.ru.honeyvpn.proxy"),
      let extensions = entitlements["com.apple.developer.networking.networkextension"] as? [String],
      extensions.contains("packet-tunnel-provider")
    else { return false }
    return true
  }
}
