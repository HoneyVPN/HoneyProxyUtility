import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostic_journal.dart';
import 'diagnostic_redactor.dart';

typedef CoreDiagnosticStream = Future<Stream<List<int>>> Function(String nonce);

/// Existing owned loopback Clash API, never an arbitrary file/endpoint reader.
/// Diagnostics do not establish readiness or change VPN lifecycle state.
class WindowsCoreDiagnostics {
  WindowsCoreDiagnostics({
    DiagnosticJournal? journal,
    CoreDiagnosticStream? stream,
    this.cancelTimeout = const Duration(seconds: 2),
  }) : journal = journal ?? DiagnosticJournal.shared,
       _stream = stream;
  final DiagnosticJournal journal;
  final CoreDiagnosticStream? _stream;
  final Duration cancelTimeout;
  HttpClient? _client;
  StreamSubscription<List<int>>? _subscription;
  int _generation = 0;
  Future<void> attach(
    String nonce, {
    required bool Function() isCurrent,
  }) async {
    final generation = ++_generation;
    bool current() => generation == _generation && isCurrent();
    try {
      if (!current()) return;
      final stream = await (_stream?.call(nonce) ?? _open(nonce, current));
      if (!current()) return;
      final parser = CoreDiagnosticLineParser(journal: journal);
      _subscription = stream.listen(
        (chunk) {
          if (current()) parser.add(chunk);
        },
        onError: (Object _) {
          if (current())
            journal.add(
              'windows-core',
              'core diagnostics stream unavailable',
              warning: true,
            );
        },
        onDone: () {
          if (current())
            journal.add('windows-core', 'core diagnostics stream ended');
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (current())
        journal.add(
          'windows-core',
          'core diagnostics stream unavailable',
          warning: true,
        );
    }
  }

  Future<Stream<List<int>>> _open(String nonce, bool Function() current) async {
    // Captured validated WindowsSession nonce; never goes in a URL or report.
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce))
      throw const FormatException();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    _client = client;
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:9090/logs?level=warn'))
        .timeout(const Duration(seconds: 3));
    if (!current()) {
      client.close(force: true);
      throw const FormatException();
    }
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $nonce');
    // The pinned core flushes HTTP headers with its first log entry. An idle
    // stream therefore waits without a readiness timeout until stop closes it.
    final response = await request.close();
    if (!current() || response.statusCode != 200) {
      client.close(force: true);
      throw const FormatException();
    }
    return response;
  }

  Future<void> stop() async {
    _generation++;
    final client = _client;
    _client = null;
    final subscription = _subscription;
    _subscription = null;
    client?.close(force: true);
    try {
      await subscription?.cancel().timeout(cancelTimeout);
    } catch (_) {
      /* Diagnostics never block a VPN stop. */
    }
  }
}

/// Parse bounded UTF-8 JSON lines before any raw string reaches the journal.
class CoreDiagnosticLineParser {
  CoreDiagnosticLineParser({required this.journal});
  final DiagnosticJournal journal;
  static const maximumLineBytes = 8192;
  final _line = <int>[];
  bool _oversized = false;
  void add(List<int> chunk) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (_oversized)
          journal.add(
            'windows-core',
            'core output exceeded line limit',
            warning: true,
          );
        else
          _publish();
        _line.clear();
        _oversized = false;
      } else if (!_oversized && _line.length < maximumLineBytes)
        _line.add(byte);
      else {
        _line.clear();
        _oversized = true;
      }
    }
  }

  void _publish() {
    if (_line.isEmpty) return;
    try {
      final value = jsonDecode(utf8.decode(_line));
      if (value is! Map ||
          value.length != 2 ||
          value['payload'] is! String ||
          value['type'] is! String ||
          !const {
            'trace',
            'debug',
            'info',
            'notice',
            'warn',
            'error',
            'fatal',
            'panic',
          }.contains(value['type']))
        return;
      final type = value['type'];
      journal.add(
        'windows-core',
        DiagnosticRedactor.coreSummary(value['payload'] as String),
        error: const {'error', 'fatal', 'panic'}.contains(type),
        warning: type == 'warn',
      );
    } catch (_) {
      /* Invalid data cannot affect the VPN or expose raw output. */
    }
  }
}
