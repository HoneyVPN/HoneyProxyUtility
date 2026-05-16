import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'bootstrap.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await bootstrap();
  runApp(const ProviderScope(child: HoneyProxyApp()));
}
