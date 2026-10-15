import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'diagnostic_journal.dart';
import 'diagnostic_redactor.dart';

final _seenAndroidEvents = <String>{};
Future<Map<String, Object?>> readAndroidDiagnostics() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
    return {
      'availability': 'not-supported',
      'state': 'unknown',
      'apiLevel': 0,
      'droppedEvents': 0,
      'events': <Object>[],
    };
  try {
    final raw = await const MethodChannel('ru.honeyvpn.proxy/vpn')
        .invokeMapMethod<String, dynamic>('getDiagnostics')
        .timeout(const Duration(seconds: 3));
    if (raw == null ||
        raw['events'] is! List ||
        (raw['events'] as List).length > 128)
      throw const FormatException();
    final freshEvents = <Map<String, Object>>[];
    for (final row in raw['events'] as List) {
      if (row is! Map ||
          row['message'] is! String ||
          row['time'] is! int ||
          row['error'] is! bool)
        continue;
      final stamp = row['time'] as int;
      if (stamp < 0 || stamp > 4102444800000) continue;
      final message = DiagnosticRedactor.coreSummary(row['message'] as String);
      final key = '$stamp:$message:${row['error']}';
      if (_seenAndroidEvents.add(key)) {
        freshEvents.add({
          'time': DateTime.fromMillisecondsSinceEpoch(
            stamp,
          ).toUtc().toIso8601String(),
          'source': 'android-core',
          'level': row['error'] == true ? 'error' : 'info',
          'message': message,
        });
        DiagnosticJournal.shared.add(
          'android-core',
          message,
          error: row['error'] == true,
          time: DateTime.fromMillisecondsSinceEpoch(stamp),
        );
      }
      if (_seenAndroidEvents.length > 512)
        _seenAndroidEvents.remove(_seenAndroidEvents.first);
    }
    return {
      'availability': 'available',
      'droppedEvents': raw['droppedEvents'] is int
          ? (raw['droppedEvents'] as int).clamp(0, 2147483647)
          : 0,
      'state':
          const {
            'CONNECTED',
            'CONNECTING',
            'DISCONNECTING',
            'DISCONNECTED',
          }.contains(raw['state'])
          ? raw['state']
          : 'unknown',
      'apiLevel': raw['apiLevel'] is int
          ? (raw['apiLevel'] as int).clamp(0, 100)
          : 0,
      'events': freshEvents,
    };
  } catch (_) {
    return {
      'availability': 'unavailable',
      'state': 'unknown',
      'apiLevel': 0,
      'droppedEvents': 0,
      'events': <Object>[],
    };
  }
}
