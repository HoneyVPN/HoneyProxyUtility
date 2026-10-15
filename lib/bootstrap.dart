import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'features/diagnostics/data/diagnostic_journal.dart';
import 'features/diagnostics/data/diagnostic_redactor.dart';
import 'features/diagnostics/data/diagnostic_application_error.dart';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

late final SharedPreferences sharedPrefs;

Future<void> bootstrap() async {
  _setupLogging();
  await DiagnosticJournal.shared.initialize();
  _setupUncaughtDiagnostics();
  sharedPrefs = await SharedPreferences.getInstance();
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
}

void _setupLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final detail = diagnosticApplicationError(
      record.message,
      source: record.loggerName,
      error: record.error,
      stack: record.stackTrace,
    );
    DiagnosticJournal.shared.add(
      'dart',
      detail,
      error: record.level >= Level.SEVERE,
      warning: record.level >= Level.WARNING,
    );
    // ignore: avoid_print
    if (record.level >= Level.WARNING) {
      print(
        '[${record.level.name}] ${const DiagnosticRedactor().text(record.message)}',
      );
    }
  });
}

void _setupUncaughtDiagnostics() {
  final flutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    DiagnosticJournal.shared.add(
      'dart',
      diagnosticApplicationError(
        'FlutterError',
        error: details.exception,
        stack: details.stack,
      ),
      error: true,
    );
    if (flutterHandler != null) {
      flutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final platformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    DiagnosticJournal.shared.add(
      'dart',
      diagnosticApplicationError('Unhandled', error: error, stack: stack),
      error: true,
    );
    // Logging does not turn an unhandled failure into a successful operation.
    return platformHandler?.call(error, stack) ?? false;
  };
}
