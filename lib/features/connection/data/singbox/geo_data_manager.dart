import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Copies bundled .srs geo rule-set files from assets to the app support
/// directory so sing-box can reference them by absolute path.
class GeoDataManager {
  GeoDataManager._();

  static const _assets = [
    'ru-blocked.srs',
    'ru-blocked-community.srs',
    're-filter.srs',
    'ru.srs',
    'geosite-category-ads-all.srs',
  ];

  static Map<String, String>? _paths;

  /// Returns a map of filename → absolute path.
  /// Copies files from assets on first call; returns cached paths thereafter.
  static Future<Map<String, String>> ensureReady() async {
    if (_paths != null) return _paths!;

    final dir = await getApplicationSupportDirectory();
    final geoDir = Directory('${dir.path}/geo');
    await geoDir.create(recursive: true);

    final result = <String, String>{};
    for (final name in _assets) {
      final dest = File('${geoDir.path}/$name');
      if (!dest.existsSync()) {
        final data = await rootBundle.load('assets/geo/$name');
        await dest.writeAsBytes(data.buffer.asUint8List());
      }
      result[name] = dest.path;
    }

    _paths = result;
    return result;
  }

  static void invalidate() => _paths = null;
}
