/// Diagnostic text is a public support boundary, never a configuration export.
/// Structured report fields deliberately exclude profile and provider names.
class DiagnosticRedactor {
  const DiagnosticRedactor({this.secrets = const []});
  final Iterable<String> secrets;
  static const maxText = 2048;
  static final _uri = RegExp(
    r'\b[a-z][a-z0-9+.-]*://[^\s<>"\x27]+',
    caseSensitive: false,
  );
  static final _field = RegExp(
    r'\b(?:password|passwd|pwd|token|secret|uuid|private[ _-]?key|public[ _-]?key|preshared[ _-]?key|authorization|cookie|subscription[ _-]?(?:url|id)|server|address|host|sni|username|user|sid|nonce|short[ _-]?id)\b["\x27]?\s*[=:]\s*(?:"[^"\r\n]*"|\x27[^\x27\r\n]*\x27|[^\s,;}]+)',
    caseSensitive: false,
  );
  static final _uuid = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final _ip = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b');
  static final _ipv6 = RegExp(
    r'(?<![a-zA-Z0-9])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.%]*(?![a-zA-Z0-9])',
    caseSensitive: false,
  );
  static final _mac = RegExp(
    r'\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b',
    caseSensitive: false,
  );
  static final _email = RegExp(r'[^\s<>]+@[^\s<>]+');
  static final _domain = RegExp(
    r'\b(?:[a-z0-9_\-]+\.)+[a-z][a-z0-9\-]{1,62}\b',
    caseSensitive: false,
  );
  static final _windowsPath = RegExp(
    r'\b[a-z]:[\\/][^\r\n,;<>"\x27]*',
    caseSensitive: false,
  );
  static final _unixPath = RegExp(
    r'(?<![a-z0-9])/(?:[^\s/<>"\x27]+/)*[^\s<>"\x27]+',
    caseSensitive: false,
  );
  static final _opaque = RegExp(r'\b[a-zA-Z0-9_+\-/=]{24,}\b');
  static final _control = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
  );

  String text(String value, {int limit = maxText}) {
    // Bound work before regular expressions; an oversized secret cannot leave
    // its prefix behind. Drop an oversized input rather than truncate raw data.
    if (value.length > 16384) return '[oversized diagnostic omitted]';
    var result = _validUnicode(
      value,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(_control, '');
    final ordered =
        secrets.where((s) => s.isNotEmpty && s.length <= 16384).toSet().toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in ordered) {
      result = result.replaceAll(secret, '[private]');
    }
    // Configuration blocks and PEM/WireGuard text have no useful safe display.
    if (RegExp(
      r'BEGIN .*KEY|\[Interface\]|\[Peer\]|"(?:outbounds|inbounds|private_key|users)"\s*:|(?:^|\n)\s*proxies\s*:',
      caseSensitive: false,
    ).hasMatch(result)) {
      return '[configuration omitted]';
    }
    result = result
        .replaceAll(
          RegExp(
            r'\b(?:authorization|cookie|set-cookie)\s*[:=][^\r\n]*',
            caseSensitive: false,
          ),
          '[private header]',
        )
        .replaceAll(_uri, '[link]')
        .replaceAll(_field, '[private field]')
        .replaceAll(_windowsPath, '[path]')
        .replaceAll(_unixPath, '[path]')
        .replaceAll(_email, '[address]')
        .replaceAll(_uuid, '[identifier]')
        .replaceAll(_mac, '[address]')
        .replaceAll(_ip, '[address]')
        .replaceAll(_ipv6, '[address]')
        .replaceAll(_domain, '[host]')
        .replaceAll(_opaque, '[identifier]');
    if (result.length <= limit) return result;
    var cut = limit - 12;
    if (cut > 0 &&
        cut < result.length &&
        result.codeUnitAt(cut - 1) >= 0xD800 &&
        result.codeUnitAt(cut - 1) <= 0xDBFF &&
        result.codeUnitAt(cut) >= 0xDC00 &&
        result.codeUnitAt(cut) <= 0xDFFF)
      cut--;
    return '${result.substring(0, cut)} [truncated]';
  }

  static String _validUnicode(String value) {
    final result = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code >= 0xD800 && code <= 0xDBFF) {
        if (i + 1 < value.length &&
            value.codeUnitAt(i + 1) >= 0xDC00 &&
            value.codeUnitAt(i + 1) <= 0xDFFF) {
          result.writeCharCode(code);
          result.writeCharCode(value.codeUnitAt(++i));
        } else {
          result.writeCharCode(0xFFFD);
        }
      } else if (code >= 0xDC00 && code <= 0xDFFF) {
        result.writeCharCode(0xFFFD);
      } else {
        result.writeCharCode(code);
      }
    }
    return result.toString();
  }

  /// Core output is unconstrained and may echo arbitrary short credentials.
  /// Export only recognized technical tokens, never unknown words or values.
  static String coreSummary(String raw) {
    if (RegExp(
      r'^VPN child role=(sing-box|forwarder) kind=(RUNNING|EXITED|SIGNALED|UNKNOWN|OWNER_LOST) exit=[0-9]{1,3} signal=[0-9]{1,3} errno=[0-9]{1,4}$',
    ).hasMatch(raw))
      return raw;
    const vocabulary = {
      'error',
      'warn',
      'warning',
      'fatal',
      'panic',
      'debug',
      'info',
      'trace',
      'failed',
      'failure',
      'timeout',
      'deadline',
      'refused',
      'reset',
      'closed',
      'unexpected',
      'eof',
      'invalid',
      'unsupported',
      'unavailable',
      'denied',
      'permission',
      'certificate',
      'handshake',
      'tls',
      'reality',
      'vless',
      'hysteria',
      'hysteria2',
      'quic',
      'wireguard',
      'amnezia',
      'xhttp',
      'grpc',
      'websocket',
      'tcp',
      'udp',
      'dns',
      'tun',
      'socket',
      'route',
      'connect',
      'connection',
      'dial',
      'read',
      'write',
      'listen',
      'bind',
      'resolve',
      'start',
      'startup',
      'stop',
      'stopped',
      'exit',
      'exited',
      'signal',
      'core',
      'forwarder',
      'sing-box',
      'tun2socks',
      'occupied',
      'running',
      'ready',
      'cleanup',
      'confirmed',
      'unconfirmed',
      'configuration',
      'exceeded',
      'line',
      'limit',
      'output',
      'omitted',
    };
    if (raw.length > 4096) return 'core output exceeded line limit';
    final clean = const DiagnosticRedactor().text(raw);
    final tokens = RegExp(r'[a-zA-Z][a-zA-Z0-9-]*')
        .allMatches(clean)
        .map((m) => m[0]!.toLowerCase())
        .where(vocabulary.contains)
        .take(40)
        .toList();
    return tokens.isEmpty ? 'core output omitted' : tokens.join(' ');
  }
}
