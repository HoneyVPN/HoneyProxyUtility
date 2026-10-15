import 'base_parser.dart';

/// wg-quick exports often start with a friendly-name comment or UTF-8 BOM.
bool isWgQuickConfig(String value) {
  for (final rawLine in value.replaceFirst('\uFEFF', '').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    return line == '[Interface]';
  }
  return false;
}

(String, int) parseWgQuickEndpoint(String endpoint) {
  final uri = Uri.tryParse('wg-endpoint://${endpoint.trim()}');
  if (endpoint.trim().isEmpty ||
      uri == null ||
      uri.host.isEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const ParseException('WireGuard: missing or invalid Endpoint');
  }
  // Uri.host retains IPv6 brackets. The engine needs the address itself.
  return (uri.host.replaceAll('[', '').replaceAll(']', ''), uri.port);
}

void validateWgQuickKeys(Map<String, String> iface, Map<String, String> peer) {
  if ((iface['privatekey'] ?? '').isEmpty ||
      (peer['publickey'] ?? '').isEmpty) {
    throw const ParseException(
      'WireGuard: PrivateKey and PublicKey are required',
    );
  }
}
