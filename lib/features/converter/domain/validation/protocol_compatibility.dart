import 'dart:convert';

/// Validation for the selected extended core, rather than the latest Xray or
/// Hysteria feature set. Messages name fields only and never expose credentials.
void validateVlessCoreCompatibility({
  required String encryption,
  required String security,
  required String transport,
  required String flow,
  required String xhttpMode,
  required String spiderX,
  List<String> alpn = const [],
}) {
  if (!const {'none', 'tls', 'reality'}.contains(security)) {
    throw UnsupportedError('VLESS security is unsupported by this app.');
  }
  if (!const {
    'tcp',
    'ws',
    'h2',
    'http',
    'grpc',
    'httpupgrade',
    'xhttp',
  }.contains(transport)) {
    throw UnsupportedError('VLESS transport is unsupported by this app.');
  }
  if (flow != '' && flow != 'xtls-rprx-vision') {
    throw UnsupportedError('VLESS flow is unsupported by this core.');
  }
  if (transport == 'xhttp' &&
      (security == 'tls' || security == 'reality') &&
      alpn.isNotEmpty &&
      alpn.first == 'http/1.1') {
    throw UnsupportedError(
      'VLESS xHTTP over TLS/Reality with HTTP/1.1 ALPN is unsupported by this core.',
    );
  }
  if (transport == 'xhttp' &&
      security == 'reality' &&
      alpn.isNotEmpty &&
      alpn.first == 'h3') {
    throw UnsupportedError(
      'VLESS xHTTP with Reality and HTTP/3 ALPN is unsupported by this core.',
    );
  }
  if (security == 'reality' && spiderX.isNotEmpty && spiderX != '/') {
    throw UnsupportedError(
      'VLESS Reality spiderX is unsupported by this core.',
    );
  }
  _validateEncryption(encryption);
  final encrypted = encryption.isNotEmpty && encryption != 'none';
  if (flow.isNotEmpty &&
      !encrypted &&
      (security == 'none' || transport != 'tcp')) {
    throw UnsupportedError(
      'VLESS Vision requires TCP with TLS/Reality or VLESS Encryption.',
    );
  }
  if (transport == 'xhttp' &&
      !const {
        '',
        'auto',
        'packet-up',
        'stream-up',
        'stream-one',
      }.contains(xhttpMode)) {
    throw UnsupportedError('VLESS xHTTP mode is unsupported by this app.');
  }
}

void _validateEncryption(String value) {
  if (value.isEmpty || value == 'none') return;
  Never invalid() => throw UnsupportedError(
    'VLESS encryption is invalid or unsupported by this core.',
  );
  final parts = value.split('.');
  if (parts.length < 4 ||
      parts[0] != 'mlkem768x25519plus' ||
      !const {'native', 'xorpub', 'random'}.contains(parts[1]) ||
      !const {'0rtt', '1rtt'}.contains(parts[2])) {
    invalid();
  }
  var keys = 0;
  var paddingIndex = 0;
  var paddingLength = 0;
  for (final segment in parts.skip(3)) {
    // The pinned fork attempts raw-base64 decoding before parsing padding.
    // In particular, some valid Xray padding strings are ambiguous in it.
    List<int>? bytes;
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(segment) &&
        segment.length % 4 != 1) {
      try {
        bytes = base64Url.decode(base64Url.normalize(segment));
      } on FormatException {
        invalid();
      }
    }
    if (bytes != null) {
      if (bytes.length != 32 && bytes.length != 1184) invalid();
      keys++;
      continue;
    }
    if (keys > 0) invalid();
    final padding = segment.split('-');
    if (padding.length != 3) invalid();
    final values = padding.map(int.tryParse).toList();
    if (values.any((v) => v == null || v < 0)) invalid();
    final probability = values[0]!;
    final minimum = values[1]!;
    final maximum = values[2]!;
    if (probability > 100 ||
        maximum < minimum ||
        (paddingIndex == 0 && (probability != 100 || minimum < 35))) {
      invalid();
    }
    if (paddingIndex.isEven) paddingLength += maximum;
    paddingIndex++;
  }
  if (keys == 0 || paddingLength > 65553) invalid();
}

/// Hysteria URIs use comma-separated ports and hyphen-separated ranges;
/// sing-quic's selected ParsePorts requires colon ranges even for one port.
List<String> hysteria2ServerPorts(String? value) {
  if (value == null || value.isEmpty) return const [];
  final result = <String>[];
  for (final item in value.split(',')) {
    final match = RegExp(r'^(\d+)(?:[-:](\d+))?$').firstMatch(item);
    final start = match == null ? null : int.tryParse(match.group(1)!);
    final end = match == null
        ? null
        : int.tryParse(match.group(2) ?? match.group(1)!);
    if (start == null ||
        end == null ||
        start < 1 ||
        end > 65535 ||
        end < start) {
      throw UnsupportedError(
        'Hysteria2 ports must be valid ports or ascending ranges (1–65535).',
      );
    }
    result.add('$start:$end');
  }
  return result;
}

void validateHysteria2CoreCompatibility({
  required String pinSha256,
  required String obfs,
  required String obfsPassword,
  required String hopInterval,
}) {
  if (pinSha256.isNotEmpty) {
    // Official pinSHA256 hashes the complete certificate, whereas the core's
    // certificate_public_key_sha256 hashes SPKI. These are not interchangeable.
    throw UnsupportedError(
      'Hysteria2 pinSHA256 (certificate fingerprint) is unsupported by this core.',
    );
  }
  if (obfs.isNotEmpty && obfs != 'salamander') {
    throw UnsupportedError('Hysteria2 obfs is unsupported by this core.');
  }
  if (obfs.isNotEmpty && obfsPassword.isEmpty) {
    throw UnsupportedError('Hysteria2 obfs-password is required.');
  }
  if (hopInterval.isNotEmpty) {
    // Fixed intervals in seconds are portable across the two builders. Random
    // hopping intervals were introduced after the pinned core.
    final match = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(hopInterval);
    final seconds = match == null ? null : double.tryParse(match.group(1)!);
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      throw UnsupportedError(
        'Hysteria2 hopInterval must be a positive duration in seconds.',
      );
    }
  }
}
