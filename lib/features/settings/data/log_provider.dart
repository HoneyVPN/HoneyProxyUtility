import '../../diagnostics/data/diagnostic_journal.dart';
import '../../diagnostics/data/diagnostic_redactor.dart';
import 'package:flutter_riverpod/legacy.dart';

class LogEntry {
  final DateTime time;
  final String message;
  final bool isError;
  const LogEntry({
    required this.time,
    required this.message,
    this.isError = false,
  });
}

class LogNotifier extends StateNotifier<List<LogEntry>> {
  LogNotifier() : super([]);

  static const _maxEntries = 300;

  void add(String message, {bool isError = false}) {
    // UI messages may contain a human profile name. Persistent diagnostics
    // record the event type; error causes come from structured native/Logger events.
    DiagnosticJournal.shared.add(
      'app',
      isError ? 'connection error' : 'connection event',
      error: isError,
    );
    final entry = LogEntry(
      time: DateTime.now(),
      message: const DiagnosticRedactor().text(message),
      isError: isError,
    );
    final next = state.length >= _maxEntries
        ? [...state.sublist(1), entry]
        : [...state, entry];
    state = next;
  }

  void clear() {
    state = [];
    DiagnosticJournal.shared.clear();
  }
}

final logProvider = StateNotifierProvider<LogNotifier, List<LogEntry>>(
  (_) => LogNotifier(),
);
