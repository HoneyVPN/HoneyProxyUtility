import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_journal.dart';
import 'diagnostic_redactor.dart';
import 'diagnostic_report.dart';
import 'diagnostic_upload.dart';

class DiagnosticAutoConsent {
  const DiagnosticAutoConsent({this.enabled = false, this.asked = false});

  final bool enabled;
  final bool asked;
}

enum DiagnosticAutoSendResult {
  disabled,
  ignored,
  background,
  busy,
  cooldown,
  duplicate,
  dailyLimit,
  unavailable,
  sent,
  failed,
}

/// Optional foreground diagnostics. Neither consent nor budgets use the VPN
/// disclosure key. Only hashes/timestamps and one receipt are stored here.
/// No historical errors are replayed and no background or retry timer is used.
class DiagnosticAutoSendController {
  DiagnosticAutoSendController({
    required Future<DiagnosticReport> Function() buildReport,
    required DiagnosticUploader uploader,
    required bool Function() isForeground,
    DiagnosticJournal? journal,
    SharedPreferences? preferences,
    DateTime Function()? now,
  }) : _buildReport = buildReport,
       _uploader = uploader,
       _isForeground = isForeground,
       _journal = journal ?? DiagnosticJournal.shared,
       _prefs = preferences,
       _now = now ?? DateTime.now;

  static const consentKey = 'honey_auto_diagnostics_consent_v1';
  static const attemptsKey = 'honey_auto_diagnostics_attempts_v1';
  static const lastReceiptKey = 'honey_auto_diagnostics_last_receipt_v1';
  static const minimumInterval = Duration(minutes: 15);
  static const attemptWindow = Duration(hours: 24);
  static const maximumAttempts = 3;
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static final _receipt = RegExp(r'^[a-f0-9]{32}$');

  final Future<DiagnosticReport> Function() _buildReport;
  final DiagnosticUploader _uploader;
  final bool Function() _isForeground;
  final DiagnosticJournal _journal;
  final DateTime Function() _now;
  SharedPreferences? _prefs;
  DiagnosticAutoConsent _consent = const DiagnosticAutoConsent();
  final _attempts = <_Attempt>[];
  Future<void>? _initialization;
  Future<void> _consentWrites = Future.value();
  void Function()? _unsubscribe;
  bool _storageAvailable = true;
  bool _inFlight = false;
  bool _disposed = false;
  int _consentRevision = 0;
  String? _lastAcceptedReportId;
  final _consentChanges = StreamController<DiagnosticAutoConsent>.broadcast();

  DiagnosticAutoConsent get consent => _consent;
  Stream<DiagnosticAutoConsent> get consentChanges => _consentChanges.stream;
  String? get lastAcceptedReportId => _lastAcceptedReportId;

  Future<DiagnosticAutoConsent> initialize() async {
    await (_initialization ??= _load());
    return _consent;
  }

  Future<void> _load() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      final rawConsent = prefs.getString(consentKey);
      if (rawConsent != null) {
        final value = jsonDecode(rawConsent);
        if (value is! Map ||
            value.length != 2 ||
            value['enabled'] is! bool ||
            value['asked'] is! bool) {
          throw const FormatException('auto diagnostics consent');
        }
        if (_consentRevision == 0) {
          _consent = DiagnosticAutoConsent(
            enabled: value['enabled'] == true && value['asked'] == true,
            asked: value['asked'] as bool,
          );
        }
      }
      final rawAttempts = prefs.getString(attemptsKey);
      if (rawAttempts != null) {
        if (rawAttempts.length > 4096) {
          throw const FormatException('auto diagnostics budget');
        }
        final rows = jsonDecode(rawAttempts);
        if (rows is! List || rows.length > maximumAttempts) {
          throw const FormatException('auto diagnostics budget');
        }
        for (final row in rows) {
          if (row is! Map ||
              row.length != 3 ||
              row['time'] is! String ||
              row['fingerprint'] is! String ||
              !_hash.hasMatch(row['fingerprint'] as String) ||
              row['sent'] is! bool) {
            throw const FormatException('auto diagnostics budget');
          }
          final time = DateTime.tryParse(row['time'] as String);
          if (time == null) {
            throw const FormatException('auto diagnostics time');
          }
          _attempts.add(
            _Attempt(
              time.toUtc(),
              row['fingerprint'] as String,
              row['sent'] as bool,
            ),
          );
        }
      }
      _prune(_now().toUtc());
      final receipt = prefs.getString(lastReceiptKey);
      if (receipt != null && _receipt.hasMatch(receipt)) {
        _lastAcceptedReportId = receipt;
      }
    } catch (_) {
      // A broken budget must not turn into unlimited uploads or opt users in.
      _storageAvailable = false;
      _consent = const DiagnosticAutoConsent();
    }
    if (!_disposed) {
      _unsubscribe = _journal.addErrorListener((event) {
        unawaited(handleError(event));
      });
      _emitConsent();
    }
  }

  Future<DiagnosticAutoConsent> setEnabled(bool enabled) async {
    final revision = ++_consentRevision;
    final next = DiagnosticAutoConsent(enabled: enabled, asked: true);
    // Disabling takes effect before the persistence operation completes, so an
    // already-building report cannot start an upload after consent is revoked.
    if (!enabled) {
      _consent = next;
      _emitConsent();
    }
    await initialize();
    await _persistConsent(next, revision);
    return _consent;
  }

  Future<DiagnosticAutoConsent> markAsked() async {
    await initialize();
    final revision = ++_consentRevision;
    await _persistConsent(
      DiagnosticAutoConsent(enabled: _consent.enabled, asked: true),
      revision,
    );
    return _consent;
  }

  Future<void> _persistConsent(DiagnosticAutoConsent next, int revision) {
    final operation = _consentWrites.then((_) async {
      if (_disposed || !_storageAvailable || _prefs == null) {
        throw StateError('Automatic diagnostics preferences are unavailable');
      }
      final previous = _prefs!.getString(consentKey);
      try {
        if (!await _prefs!.setString(
          consentKey,
          jsonEncode({'enabled': next.enabled, 'asked': next.asked}),
        )) {
          throw StateError('Automatic diagnostics consent was not saved');
        }
      } catch (_) {
        if (next.enabled) {
          // Legacy preference setters update their cache before a failed disk
          // write. Do not let a rejected opt-in reappear on controller rebuild.
          try {
            if (previous == null) {
              await _prefs!.remove(consentKey);
            } else {
              await _prefs!.setString(consentKey, previous);
            }
          } catch (_) {}
        }
        rethrow;
      }
      if (!_disposed && revision == _consentRevision) {
        _consent = next;
        _emitConsent();
      }
    });
    _consentWrites = operation.catchError((Object _) {});
    return operation;
  }

  Future<DiagnosticAutoSendResult> handleError(DiagnosticEvent event) async {
    if (_disposed || !_consent.enabled)
      return DiagnosticAutoSendResult.disabled;
    if (event.level != 'error') return DiagnosticAutoSendResult.ignored;
    if (!_foreground()) return DiagnosticAutoSendResult.background;
    if (_inFlight) return DiagnosticAutoSendResult.busy;
    if (!_storageAvailable || _prefs == null) {
      return DiagnosticAutoSendResult.unavailable;
    }
    _inFlight = true;
    final revision = _consentRevision;
    try {
      final instant = _now().toUtc();
      _prune(instant);
      final fingerprint = sha256
          .convert(
            utf8.encode(
              '${event.source}\n${const DiagnosticRedactor().text(event.message)}',
            ),
          )
          .toString();
      if (_attempts.any((a) => a.sent && a.fingerprint == fingerprint)) {
        return DiagnosticAutoSendResult.duplicate;
      }
      if (_attempts.length >= maximumAttempts) {
        return DiagnosticAutoSendResult.dailyLimit;
      }
      if (_attempts.any((a) => instant.difference(a.time) < minimumInterval)) {
        return DiagnosticAutoSendResult.cooldown;
      }
      // Count the attempt before preparing or sending. Restarts, failed builds,
      // timeouts and rejected receipts cannot bypass the persistent budget.
      final attempt = _Attempt(instant, fingerprint, false);
      _attempts.add(attempt);
      await _saveAttempts();
      if (!_canSend(revision)) return DiagnosticAutoSendResult.disabled;
      final report = await _buildReport().timeout(const Duration(seconds: 8));
      if (!_canSend(revision)) return DiagnosticAutoSendResult.disabled;
      // Existing uploader enforces HTTPS, no redirects and its total deadline.
      final id = await _uploader.send(report);
      if (!_receipt.hasMatch(id) || id != report.data['requestId']) {
        return DiagnosticAutoSendResult.failed;
      }
      attempt.sent = true;
      _lastAcceptedReportId = id;
      await _saveAttempts();
      if (!await _prefs!.setString(lastReceiptKey, id)) {
        _storageAvailable = false;
      }
      _emitConsent();
      return DiagnosticAutoSendResult.sent;
    } catch (_) {
      // Never log a diagnostic-upload failure or generate a new error event.
      // A later real error may retry only after the same persisted limits.
      return DiagnosticAutoSendResult.failed;
    } finally {
      _inFlight = false;
    }
  }

  bool _canSend(int revision) =>
      !_disposed &&
      _consent.enabled &&
      _consentRevision == revision &&
      _foreground();

  bool _foreground() {
    try {
      return _isForeground();
    } catch (_) {
      return false;
    }
  }

  void _prune(DateTime instant) {
    _attempts.removeWhere((a) => instant.difference(a.time) >= attemptWindow);
  }

  Future<void> _saveAttempts() async {
    try {
      if (!await _prefs!.setString(
        attemptsKey,
        jsonEncode(_attempts.map((a) => a.toJson()).toList()),
      )) {
        throw StateError('Automatic diagnostics budget was not saved');
      }
    } catch (_) {
      _storageAvailable = false;
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _consentRevision++;
    _unsubscribe?.call();
    _unsubscribe = null;
    unawaited(_consentChanges.close());
  }

  void _emitConsent() {
    if (!_disposed) {
      // A new snapshot also refreshes the latest-report row when the consent
      // flags stay unchanged after a successful upload.
      _consentChanges.add(
        DiagnosticAutoConsent(enabled: _consent.enabled, asked: _consent.asked),
      );
    }
  }
}

class _Attempt {
  _Attempt(this.time, this.fingerprint, this.sent);

  final DateTime time;
  final String fingerprint;
  bool sent;

  Map<String, Object> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'fingerprint': fingerprint,
    'sent': sent,
  };
}
