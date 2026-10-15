import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Publishes the packaged routing data without a startup network dependency.
/// Content-addressed paths keep a previous VPN session's asset generation valid.
class GeoDataManager {
  GeoDataManager._();

  static const _assets = [
    'ru-blocked.srs',
    'ru-blocked-community.srs',
    're-filter.srs',
    'ru.srs',
  ];

  static final _random = Random.secure();
  static Map<String, String>? _paths;
  static Future<void> _maintenance = Future<void>.value();

  /// Verifies every published file, including calls within the same session.
  /// Concurrent connections cannot publish or repair the cache simultaneously.
  static Future<Map<String, String>> ensureReady() {
    final result = _maintenance.then((_) => _prepare());
    _maintenance = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static Future<Map<String, String>> _prepare() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/geo');
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Bundled routing cache is not a directory',
        directory.path,
      );
    }
    await directory.create(recursive: true);

    final result = <String, String>{};
    for (final name in _assets) {
      final data = await rootBundle.load('assets/geo/$name');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final digest = sha256.convert(bytes).toString();
      final destination = File('${directory.path}/$digest-$name');
      final cachedType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (cachedType != FileSystemEntityType.notFound &&
          cachedType != FileSystemEntityType.file) {
        throw FileSystemException(
          'Bundled routing cache is not a regular file',
          destination.path,
        );
      }
      final valid =
          cachedType == FileSystemEntityType.file &&
          await destination.length() == bytes.length &&
          sha256.convert(await destination.readAsBytes()).toString() == digest;
      if (!valid) {
        final nonce = List.generate(
          4,
          (_) => _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
        ).join();
        final temporary = File('${destination.path}.part-$nonce');
        try {
          await temporary.create(exclusive: true);
          await temporary.writeAsBytes(bytes, flush: true);
          final currentType = await FileSystemEntity.type(
            destination.path,
            followLinks: false,
          );
          if (currentType != FileSystemEntityType.notFound &&
              currentType != FileSystemEntityType.file) {
            throw FileSystemException(
              'Bundled routing cache changed during publication',
              destination.path,
            );
          }
          // Same-directory rename publishes complete bytes. Never truncate a
          // published path, and never overwrite another asset generation.
          await temporary.rename(destination.path);
        } finally {
          if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
              FileSystemEntityType.file) {
            await temporary.delete();
          }
        }
      }
      result[name] = destination.path;
    }
    _paths = Map<String, String>.unmodifiable(result);
    return _paths!;
  }

  // Existing callers may invalidate their last published map. Verification is
  // unconditional; old generation files remain available to native readers.
  static void invalidate() => _paths = null;
}
