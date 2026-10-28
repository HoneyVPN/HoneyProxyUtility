import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'diagnostic_redactor.dart';

class DiagnosticEvent {
  const DiagnosticEvent(this.time, this.source, this.level, this.message);
  final DateTime time;
  final String source, level, message;
  Map<String, Object> toJson([DiagnosticRedactor? redactor]) => {
    'time': time.toUtc().toIso8601String(),
    'source': source,
    'level': level,
    'message': redactor?.text(message) ?? message,
  };
}

/// Only sanitized events enter either memory or preferences. This is not an
/// operating-system log reader; it captures Honey's own bounded diagnostics.
class DiagnosticJournal {
  DiagnosticJournal({this.persist = true, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  static final shared = DiagnosticJournal();
  static const key = 'honey_diagnostics_v1';
  static const maxEntries = 300, maxBytes = 384 * 1024;
  final bool persist;
  final DateTime Function() _now;
  final _events = <DiagnosticEvent>[];
  final _sizes = <int>[];
  int _bytes = 2;
  SharedPreferences? _prefs;
  Timer? _timer;
  bool storageAvailable = true;
  int droppedThisRun = 0;
  Future<void> _write = Future.value();
  Future<void>? _initialization;
  int _clearRevision = 0;
  final _errorListeners = <void Function(DiagnosticEvent)>{};
  List<DiagnosticEvent> get events => List.unmodifiable(_events);

  /// Only newly added, sanitized errors are observed; loading the persisted
  /// journal never replays historical errors. Observers cannot break logging.
  void Function() addErrorListener(void Function(DiagnosticEvent) listener) {
    _errorListeners.add(listener);
    return () => _errorListeners.remove(listener);
  }

  Future<void> initialize() => _initialization ??= _load();
  Future<void> _load() async {
    if (!persist) return;
    final revision = _clearRevision;
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(key);
      if (raw == null) return;
      if (raw.length > maxBytes || utf8.encode(raw).length > maxBytes) {
        await _prefs!.remove(key);
        return;
      }
      final rows = jsonDecode(raw);
      if (rows is! List || rows.length > maxEntries) {
        await _prefs!.remove(key);
        return;
      }
      final loaded = <DiagnosticEvent>[];
      for (final row in rows) {
        if (row is! Map ||
            row.length != 4 ||
            row['time'] is! String ||
            row['message'] is! String ||
            !const {
              'app',
              'dart',
              'android-core',
              'windows-session',
              'windows-core',
            }.contains(row['source']) ||
            !const {'info', 'warning', 'error'}.contains(row['level']))
          continue;
        final time = DateTime.tryParse(row['time'] as String);
        if (time == null) continue;
        loaded.add(
          DiagnosticEvent(
            time,
            row['source'] as String,
            row['level'] as String,
            const DiagnosticRedactor().text(row['message'] as String),
          ),
        );
      }
      if (revision == _clearRevision) _events.insertAll(0, loaded);
      _sizes.clear();
      _bytes = 2;
      for (final event in _events) {
        final size = utf8.encode(jsonEncode(event.toJson())).length + 1;
        _sizes.add(size);
        _bytes += size;
      }
      _bound();
    } catch (_) {
      storageAvailable = false;
    }
  }

  void add(
    String source,
    String message, {
    bool error = false,
    bool warning = false,
    DateTime? time,
  }) {
    if (!const {
      'app',
      'dart',
      'android-core',
      'windows-session',
      'windows-core',
    }.contains(source))
      source = 'app';
    _events.add(
      DiagnosticEvent(
        time ?? _now(),
        source,
        error
            ? 'error'
            : warning
            ? 'warning'
            : 'info',
        const DiagnosticRedactor().text(message),
      ),
    );
    final size = utf8.encode(jsonEncode(_events.last.toJson())).length + 1;
    _sizes.add(size);
    _bytes += size;
    _bound();
    if (error) {
      final event = _events.last;
      for (final listener in _errorListeners.toList()) {
        try {
          listener(event);
        } catch (_) {
          // A support observer must never change application behavior.
        }
      }
    }
    if (persist && _prefs != null) {
      _timer ??= Timer(const Duration(milliseconds: 300), () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  void _bound() {
    while (_events.length > maxEntries || _bytes > maxBytes) {
      _events.removeAt(0);
      _bytes -= _sizes.removeAt(0);
      droppedThisRun++;
    }
  }

  Future<void> flush() {
    final operation = _write.then((_) async {
      await initialize();
      if (_prefs == null) return;
      try {
        if (!await _prefs!.setString(
          key,
          jsonEncode(_events.map((e) => e.toJson()).toList()),
        ))
          storageAvailable = false;
      } catch (_) {
        storageAvailable = false;
      }
    });
    _write = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    _clearRevision++;
    _events.clear();
    _sizes.clear();
    _bytes = 2;
    await initialize();
    await flush();
  }

  void dispose() {
    _errorListeners.clear();
    _timer?.cancel();
    _timer = null;
  }
}
