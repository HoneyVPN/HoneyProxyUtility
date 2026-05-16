import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

class LogEntry {
  final DateTime time;
  final String message;
  final bool isError;
  const LogEntry({required this.time, required this.message, this.isError = false});
}

class LogNotifier extends StateNotifier<List<LogEntry>> {
  LogNotifier() : super([]);

  static const _maxEntries = 300;

  void add(String message, {bool isError = false}) {
    final entry = LogEntry(time: DateTime.now(), message: message, isError: isError);
    final next = state.length >= _maxEntries
        ? [...state.sublist(1), entry]
        : [...state, entry];
    state = next;
  }

  void clear() => state = [];
}

final logProvider = StateNotifierProvider<LogNotifier, List<LogEntry>>(
  (_) => LogNotifier(),
);
