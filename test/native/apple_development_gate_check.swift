import Foundation

@main
struct DevelopmentGateCheck {
  static func main() {
    precondition(!DevelopmentVpnGate.allows(Bundle.main), "An unsigned or ad-hoc executable must remain unavailable")
    precondition(!DevelopmentVpnGate.hasDevelopmentSignature(Bundle.main))
    print("Apple development gate passed: unsigned executable cannot enable VPN")
  }
}
