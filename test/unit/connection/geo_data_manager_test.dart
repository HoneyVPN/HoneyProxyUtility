import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/geo_data_manager.dart';

const _names = [
  'ru-blocked.srs',
  'ru-blocked-community.srs',
  're-filter.srs',
  'ru.srs',
];

class _SupportPath extends PathProviderPlatform {
  _SupportPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalProvider = PathProviderPlatform.instance;
  late Directory support;
  late Map<String, List<int>> bundled;
  int loading = 0, maximumConcurrentLoads = 0;
  bool failLoading = false;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('honey-geodata-audit-');
    PathProviderPlatform.instance = _SupportPath(support.path);
    GeoDataManager.invalidate();
    bundled = {
      for (var i = 0; i < _names.length; i++) _names[i]: [83, 82, 83, 1, i, 7],
    };
    loading = maximumConcurrentLoads = 0;
    failLoading = false;
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      if (!key.startsWith('assets/geo/')) return null;
      loading++;
      if (loading > maximumConcurrentLoads) maximumConcurrentLoads = loading;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (failLoading) return null;
        final value = bundled[key.substring('assets/geo/'.length)]!;
        // Assets may be ByteData views: only the declared slice belongs to it.
        final padded = Uint8List.fromList([99, ...value, 100]);
        return ByteData.view(padded.buffer, 1, value.length);
      } finally {
        loading--;
      }
    });
  });

  tearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    PathProviderPlatform.instance = originalProvider;
    GeoDataManager.invalidate();
    await support.delete(recursive: true);
  });

  test('legacy version1 cache cannot hide changed bundled bytes', () async {
    final geo = await Directory('${support.path}/geo').create();
    await File('${geo.path}/.version').writeAsString('1');
    for (final name in _names) {
      await File('${geo.path}/$name').writeAsBytes([0]);
    }
    final paths = await GeoDataManager.ensureReady();
    for (final name in _names) {
      expect(await File(paths[name]!).readAsBytes(), bundled[name]);
      // Preserve old paths rather than truncating an existing native reader.
      expect(await File('${geo.path}/$name').readAsBytes(), [0]);
    }
  });

  for (final missing in [false, true]) {
    test(
      'same session repairs ${missing ? 'deleted' : 'corrupt'} cache',
      () async {
        final first = await GeoDataManager.ensureReady();
        final file = File(first[_names.first]!);
        if (missing) {
          await file.delete();
        } else {
          await file.writeAsBytes(
            List<int>.filled(bundled[_names.first]!.length, 0),
          );
        }
        final repaired = await GeoDataManager.ensureReady();
        expect(
          await File(repaired[_names.first]!).readAsBytes(),
          bundled[_names.first],
        );
      },
    );
  }

  test(
    'changed asset publishes a new path and preserves a retained reader',
    () async {
      final first = await GeoDataManager.ensureReady();
      final oldFile = File(first[_names.first]!);
      final oldBytes = await oldFile.readAsBytes();
      final reader = await oldFile.open();
      try {
        bundled[_names.first] = [...bundled[_names.first]!, 8];
        final next = await GeoDataManager.ensureReady();
        expect(next[_names.first], isNot(first[_names.first]));
        expect(
          await File(next[_names.first]!).readAsBytes(),
          bundled[_names.first],
        );
        expect(await oldFile.readAsBytes(), oldBytes);
        expect(await reader.read(oldBytes.length), oldBytes);
      } finally {
        await reader.close();
      }
    },
  );

  test('concurrent first connections serialize cache publication', () async {
    final results = await Future.wait(
      List.generate(8, (_) => GeoDataManager.ensureReady()),
    );
    expect(maximumConcurrentLoads, 1);
    for (final result in results) {
      expect(result, results.first);
      for (final name in _names) {
        expect(await File(result[name]!).readAsBytes(), bundled[name]);
      }
    }
    final names = await Directory(
      '${support.path}/geo',
    ).list().map((f) => f.path).toList();
    expect(names.where((name) => name.contains('.part-')), isEmpty);
  });

  test(
    'failed asset load leaves the previous generation and allows retry',
    () async {
      final first = await GeoDataManager.ensureReady();
      final oldBytes = await File(first[_names.first]!).readAsBytes();
      failLoading = true;
      await expectLater(
        GeoDataManager.ensureReady(),
        throwsA(isA<FlutterError>()),
      );
      expect(await File(first[_names.first]!).readAsBytes(), oldBytes);
      failLoading = false;
      final next = await GeoDataManager.ensureReady();
      expect(
        await File(next[_names.first]!).readAsBytes(),
        bundled[_names.first],
      );
    },
  );
}
