import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

late final SharedPreferences sharedPrefs;

Future<void> bootstrap() async {
  _setupLogging();
  sharedPrefs = await SharedPreferences.getInstance();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
}

void _setupLogging() {
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    if (record.level >= Level.WARNING) {
      print('[${record.level.name}] ${record.loggerName}: ${record.message}');
    }
  });
}
