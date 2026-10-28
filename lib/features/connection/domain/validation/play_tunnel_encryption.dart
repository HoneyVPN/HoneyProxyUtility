import '../../../../app/flavor.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';

/// A Play-distributed VPN must encrypt traffic up to its tunnel endpoint.
/// Obfuscation, a port number, and encryption of individual websites do not
/// establish that property for the selected proxy transport.
class PlayTunnelEncryptionException extends UnsupportedError {
  PlayTunnelEncryptionException()
    : super('Google Play requires an encrypted VPN tunnel.');
}

void validatePlayTunnelEncryption(
  ParsedProxy proxy, {
  bool playFlavor = kFlavor == 'play',
}) {
  if (!playFlavor) return;
  if (!_hasTunnelEncryption(proxy)) {
    throw PlayTunnelEncryptionException();
  }
}

bool _hasTunnelEncryption(ParsedProxy proxy) => switch (proxy) {
  VlessConfig c => _encryptedVless(c),
  VmessConfig c =>
    c.tls == 'tls' ||
        const {'auto', 'aes-128-gcm', 'chacha20-poly1305'}.contains(c.security),
  TrojanConfig c => const {'tls', 'xtls'}.contains(c.security),
  ShadowsocksConfig c => _encryptedShadowsocksMethods.contains(c.method),
  // QUIC/TLS and WireGuard/AWG always encrypt their protocol payloads. The
  // existing core-compatibility validators still reject unsupported options.
  Hysteria2Config _ ||
  TuicConfig _ ||
  WireGuardConfig _ ||
  AmneziaWGConfig _ => true,
  NaiveConfig c => const {'https', 'quic'}.contains(c.scheme),
  // ShadowTLS is camouflage for an encrypted inner protocol, not proof that
  // arbitrary inner traffic is encrypted. The builder requires SS inside it.
  ShadowTlsConfig c =>
    c.innerProxy is ShadowsocksConfig && _hasTunnelEncryption(c.innerProxy),
};

bool _encryptedVless(VlessConfig proxy) {
  // A nonempty unrecognized string must not serve as an encryption claim.
  proxy.validateCoreCompatibility();
  return const {'tls', 'reality'}.contains(proxy.security) ||
      (proxy.encryption.isNotEmpty && proxy.encryption != 'none');
}

// Positive list: new/unknown ciphers need review instead of silently granting
// a plaintext method (including "none"/"dummy") the Play encryption guarantee.
const _encryptedShadowsocksMethods = {
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
};
