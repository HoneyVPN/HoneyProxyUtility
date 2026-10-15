import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../lib/features/connection/data/singbox/provider_geo_bundle.dart';
import '../../../lib/features/connection/data/singbox/provider_geo_runtime.dart';
import '../../../lib/features/converter/data/parsers/provider_routing_parser.dart';
import '../../../lib/features/settings/data/models/app_settings.dart';
import '../../../lib/features/subscriptions/data/models/subscription_model.dart';
import '../../../lib/features/subscriptions/domain/entities/provider_geo_state.dart';
import '../../../lib/features/subscriptions/domain/entities/provider_routing_metadata.dart';

const _geoUrl = 'https://geo.example.invalid/geosite.dat';
const _subscriptionUrl = 'https://subscription.example.invalid/feed';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _OpenResponse {
  _OpenResponse(int status, {Map<String, List<String>> headers = const {}}) {
    controller = StreamController<Uint8List>(
      onCancel: () {
        cancellations++;
      },
    );
    body = ResponseBody(controller.stream, status, headers: headers);
  }
  late final StreamController<Uint8List> controller;
  late final ResponseBody body;
  int cancellations = 0;
}

class _Fixture {
  _Fixture(this.directory, this.adapter) {
    dio = Dio()..httpClientAdapter = adapter;
    runtime = ProviderGeoRuntime(
      dio: dio,
      directory: () async => directory,
      now: () => now,
      retention: () async => ProviderGeoRetention(
        bundleDigests: retainedBundles,
        rawIndexDigests: retainedIndices,
      ),
    );
  }
  final Directory directory;
  final _Adapter adapter;
  late final Dio dio;
  late final ProviderGeoRuntime runtime;
  DateTime now = DateTime.utc(2026, 10, 13);
  final retainedBundles = <String>{}, retainedIndices = <String>{};
  File bundle(String digest) => File('${directory.path}/bundles/$digest.json');
  File raw(String digest) => File('${directory.path}/raw/$digest.dat');
  File index(String url) => File(
    '${directory.path}/raw/${providerGeoHash(utf8.encode(url))}.index.json',
  );
  void retain(ProviderGeoPrepared prepared, {String? geoUrl}) {
    retainedBundles.add(prepared.reference.bundleDigest);
    if (geoUrl != null)
      retainedIndices.add(providerGeoHash(utf8.encode(geoUrl)));
  }
}

ProviderRoutingMetadata _metadata({
  int id = 1,
  String? geoUrl = _geoUrl,
  String domain = 'node.example.invalid',
  int? revision,
}) {
  final profile = <String, Object?>{
    if (geoUrl != null) 'Geositeurl': geoUrl,
    if (revision != null) 'LastUpdated': revision.toString(),
    'ProxySites': [geoUrl == null ? 'full:$domain' : 'geosite:test'],
  };
  final link =
      'happ://routing/onadd/${base64.encode(utf8.encode(jsonEncode(profile)))}';
  return const ProviderRoutingParser()
      .parse(
        subscriptionId: id,
        body: '',
        headers: {
          'routing': [link],
        },
      )
      .metadata;
}

List<int> _message(int tag, List<int> bytes) {
  final length = <int>[];
  var n = bytes.length;
  while (n >= 128) {
    length.add((n & 127) | 128);
    n >>= 7;
  }
  length.add(n);
  return [tag, ...length, ...bytes];
}

Uint8List _site(String domain) => Uint8List.fromList(
  _message(10, [
    ..._message(10, utf8.encode('test')),
    ..._message(18, [8, 3, ..._message(18, utf8.encode(domain))]),
  ]),
);

Matcher _issue(ProviderGeoIssue issue) => isA<ProviderGeoException>().having(
  (error) => error.issue,
  'stable issue',
  issue,
);

Future<_Fixture> _fixture(
  Future<ResponseBody> Function(RequestOptions) response,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'honey-provider-geo-',
  );
  final fixture = _Fixture(directory, _Adapter(response));
  addTearDown(() async {
    fixture.dio.close(force: true);
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return fixture;
}

Future<void> _seedIndex(_Fixture fixture, String url, String digest) async {
  await fixture.index(url).parent.create(recursive: true);
  await fixture
      .index(url)
      .writeAsString(
        jsonEncode({
          'hash': digest,
          'etag': '"synthetic"',
          'fetchedAt': fixture.now.toUtc().toIso8601String(),
        }),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verified ETag 304 closes its response and reuses the complete bundle',
    () async {
      final notModified = _OpenResponse(304);
      var calls = 0;
      final fixture = await _fixture(
        (_) async => ++calls == 1
            ? ResponseBody.fromBytes(
                _site('first.example.invalid'),
                200,
                headers: {
                  'etag': ['"synthetic"'],
                },
              )
            : notModified.body,
      );
      final metadata = _metadata();
      final first = await fixture.runtime.prepare(
        metadata,
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(first, geoUrl: _geoUrl);
      await first.release();
      final second = await fixture.runtime.prepare(
        metadata,
        subscriptionUrl: _subscriptionUrl,
        previous: first.reference,
        forceRefresh: true,
      );
      expect(
        fixture.adapter.requests.last.headers['If-None-Match'],
        '"synthetic"',
      );
      expect(second.reference.bundleDigest, first.reference.bundleDigest);
      expect(notModified.cancellations, 1);
      await second.release();
      fixture.now = fixture.now.add(const Duration(days: 1));
      final cached = await fixture.runtime.prepare(
        metadata,
        subscriptionUrl: _subscriptionUrl,
      );
      expect(fixture.adapter.requests, hasLength(2));
      await cached.release();
    },
  );

  test('tampered old DAT is never sent as an ETag candidate', () async {
    var calls = 0;
    final fixture = await _fixture(
      (_) async => ResponseBody.fromBytes(
        _site(
          ++calls == 1 ? 'first.example.invalid' : 'second.example.invalid',
        ),
        200,
        headers: {
          'etag': ['"synthetic"'],
        },
      ),
    );
    final metadata = _metadata();
    final first = await fixture.runtime.prepare(
      metadata,
      subscriptionUrl: _subscriptionUrl,
    );
    fixture.retain(first, geoUrl: _geoUrl);
    await first.release();
    final index =
        jsonDecode(await fixture.index(_geoUrl).readAsString()) as Map;
    await fixture.raw(index['hash'] as String).writeAsBytes([1, 2, 3]);
    final second = await fixture.runtime.prepare(
      metadata,
      subscriptionUrl: _subscriptionUrl,
      forceRefresh: true,
    );
    expect(
      fixture.adapter.requests.last.headers.containsKey('If-None-Match'),
      isFalse,
    );
    expect(second.reference.bundleDigest, isNot(first.reference.bundleDigest));
    expect(await fixture.bundle(first.reference.bundleDigest).exists(), isTrue);
    await second.release();
  });

  test(
    'unchanged provider bytes repair a tampered content-addressed DAT',
    () async {
      final data = _site('unchanged.example.invalid');
      final fixture = await _fixture(
        (_) async => ResponseBody.fromBytes(
          data,
          200,
          headers: {
            'etag': ['"synthetic"'],
          },
        ),
      );
      final metadata = _metadata();
      final first = await fixture.runtime.prepare(
        metadata,
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(first, geoUrl: _geoUrl);
      await first.release();
      final raw = fixture.raw(providerGeoHash(data));
      await raw.writeAsBytes([1, 2, 3]);
      final repaired = await fixture.runtime.prepare(
        metadata,
        subscriptionUrl: _subscriptionUrl,
        forceRefresh: true,
      );
      expect(
        fixture.adapter.requests.last.headers.containsKey('If-None-Match'),
        isFalse,
      );
      expect(await raw.readAsBytes(), data);
      expect(repaired.reference.bundleDigest, first.reference.bundleDigest);
      await repaired.release();
    },
  );

  test(
    'redirect cancels an endless body without cancelling the next HTTPS hop',
    () async {
      final redirect = _OpenResponse(
        302,
        headers: {
          'location': ['/final.dat'],
        },
      );
      var calls = 0;
      final fixture = await _fixture(
        (_) async => ++calls == 1
            ? redirect.body
            : ResponseBody.fromBytes(_site('node.example.invalid'), 200),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(redirect.cancellations, 1);
      expect(fixture.adapter.requests.last.uri.path, '/final.dat');
      expect(fixture.adapter.requests.last.cancelToken!.isCancelled, isFalse);
      await prepared.release();
    },
  );

  test('HTTPS downgrade rejection also closes the redirect body', () async {
    final redirect = _OpenResponse(
      307,
      headers: {
        'location': ['http://geo.example.invalid/unsafe.dat'],
      },
    );
    final fixture = await _fixture((_) async => redirect.body);
    await expectLater(
      fixture.runtime.prepare(_metadata(), subscriptionUrl: _subscriptionUrl),
      throwsA(_issue(ProviderGeoIssue.invalid)),
    );
    expect(redirect.cancellations, 1);
    expect(fixture.adapter.requests, hasLength(1));
  });

  test('HTTP rejection closes the unconsumed response body', () async {
    final rejected = _OpenResponse(503);
    final fixture = await _fixture((_) async => rejected.body);
    await expectLater(
      fixture.runtime.prepare(_metadata(), subscriptionUrl: _subscriptionUrl),
      throwsA(_issue(ProviderGeoIssue.download)),
    );
    expect(rejected.cancellations, 1);
  });

  test(
    'declared and streamed file size limits reject before cache publication',
    () async {
      final oversized = _OpenResponse(
        200,
        headers: {
          'content-length': ['${ProviderGeoRuntime.maximumFileBytes + 1}'],
        },
      );
      final fixture = await _fixture((_) async => oversized.body);
      await expectLater(
        fixture.runtime.prepare(_metadata(), subscriptionUrl: _subscriptionUrl),
        throwsA(_issue(ProviderGeoIssue.tooLarge)),
      );
      expect(oversized.cancellations, 1);
      final streamed = await _fixture(
        (_) async => ResponseBody.fromBytes(
          Uint8List(ProviderGeoRuntime.maximumFileBytes + 1),
          200,
        ),
      );
      await expectLater(
        streamed.runtime.prepare(
          _metadata(),
          subscriptionUrl: _subscriptionUrl,
        ),
        throwsA(_issue(ProviderGeoIssue.tooLarge)),
      );
      expect(
        await Directory('${fixture.directory.path}/raw').list().toList(),
        isEmpty,
      );
      expect(
        await Directory('${streamed.directory.path}/raw').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'cancelling a streamed download retires its adapter and publishes nothing',
    () async {
      final response = _OpenResponse(200);
      final requested = Completer<void>();
      final fixture = await _fixture((_) async {
        requested.complete();
        return response.body;
      });
      final token = CancelToken();
      final pending = fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
        cancelToken: token,
      );
      final expectation = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (error) => CancelToken.isCancel(error),
            'cancellation',
            isTrue,
          ),
        ),
      );
      await requested.future;
      await Future<void>.delayed(Duration.zero);
      token.cancel('Synthetic user cancellation');
      await expectation;
      expect(response.cancellations, 1);
      expect(
        await Directory('${fixture.directory.path}/raw').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'weekly cache, manual refresh, and higher provider revision remain distinct',
    () async {
      final fixture = await _fixture(
        (_) async => ResponseBody.fromBytes(_site('node.example.invalid'), 200),
      );
      final first = await fixture.runtime.prepare(
        _metadata(revision: 100),
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(first, geoUrl: _geoUrl);
      await first.release();
      final unchanged = await fixture.runtime.prepare(
        _metadata(revision: 100),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(fixture.adapter.requests, hasLength(1));
      await unchanged.release();
      final higher = await fixture.runtime.prepare(
        _metadata(revision: 101),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(fixture.adapter.requests, hasLength(2));
      await higher.release();
      fixture.now = fixture.now.add(const Duration(days: 8));
      final expired = await fixture.runtime.prepare(
        _metadata(revision: 101),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(fixture.adapter.requests, hasLength(3));
      await expired.release();
      final manual = await fixture.runtime.prepare(
        _metadata(revision: 101),
        subscriptionUrl: _subscriptionUrl,
        forceRefresh: true,
      );
      expect(fixture.adapter.requests, hasLength(4));
      await manual.release();
    },
  );

  test(
    'prepared leases protect concurrent CAS and rejected publication until release',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final stored = await fixture.runtime.prepare(
        _metadata(geoUrl: null, domain: 'stored.example.invalid'),
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(stored);
      await stored.release();
      final first = await fixture.runtime.prepare(
        _metadata(id: 2, geoUrl: null, domain: 'first.example.invalid'),
        subscriptionUrl: 'https://subscription.example.invalid/second',
      );
      final second = await fixture.runtime.prepare(
        _metadata(id: 3, geoUrl: null, domain: 'second.example.invalid'),
        subscriptionUrl: 'https://subscription.example.invalid/third',
      );
      fixture.retainedBundles.remove(
        stored.reference.bundleDigest,
      ); // Durable delete.
      await fixture.runtime.collectGarbage();
      expect(
        await fixture.bundle(stored.reference.bundleDigest).exists(),
        isFalse,
      );
      expect(
        await fixture.bundle(first.reference.bundleDigest).exists(),
        isTrue,
      );
      expect(
        await fixture.bundle(second.reference.bundleDigest).exists(),
        isTrue,
      );
      fixture.retain(
        first,
      ); // Publication finished before its lease is released.
      await Future.wait([first.release(), first.release()]);
      await second.release(); // Retired generation rejected its CAS.
      await fixture.runtime.collectGarbage();
      expect(
        await fixture.bundle(first.reference.bundleDigest).exists(),
        isTrue,
      );
      expect(
        await fixture.bundle(second.reference.bundleDigest).exists(),
        isFalse,
      );
      expect(
        (await fixture.runtime.readBundle(
          first.reference,
          expectedScope: first.reference.scope,
        )).digest,
        first.reference.bundleDigest,
      );
    },
  );

  test(
    'changed provider URL retires its raw index and DAT but preserves last-good bundle',
    () async {
      final fixture = await _fixture(
        (request) async => ResponseBody.fromBytes(
          _site(
            request.uri.path.contains('second')
                ? 'second.example.invalid'
                : 'first.example.invalid',
          ),
          200,
        ),
      );
      final first = await fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(first, geoUrl: _geoUrl);
      await first.release();
      final oldIndex =
          jsonDecode(await fixture.index(_geoUrl).readAsString()) as Map;
      const nextUrl = 'https://geo.example.invalid/second.dat';
      fixture.retainedIndices
        ..clear()
        ..add(providerGeoHash(utf8.encode(nextUrl)));
      final second = await fixture.runtime.prepare(
        _metadata(geoUrl: nextUrl),
        subscriptionUrl: _subscriptionUrl,
        previous: first.reference,
      );
      expect(await fixture.index(_geoUrl).exists(), isFalse);
      expect(await fixture.raw(oldIndex['hash'] as String).exists(), isFalse);
      expect(
        await fixture.bundle(first.reference.bundleDigest).exists(),
        isTrue,
      );
      expect(await fixture.index(nextUrl).exists(), isTrue);
      await second.release();
    },
  );

  test(
    'URL and raw leases survive deletion while a new response is in flight',
    () async {
      final stalled = _OpenResponse(200);
      final arrived = Completer<void>();
      var calls = 0;
      final fixture = await _fixture((_) async {
        if (++calls == 1)
          return ResponseBody.fromBytes(
            _site('old.example.invalid'),
            200,
            headers: {
              'etag': ['"synthetic"'],
            },
          );
        arrived.complete();
        return stalled.body;
      });
      final first = await fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(first, geoUrl: _geoUrl);
      await first.release();
      final index =
          jsonDecode(await fixture.index(_geoUrl).readAsString()) as Map;
      final pending = fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
        previous: first.reference,
        forceRefresh: true,
      );
      await arrived.future;
      fixture.retainedBundles.clear();
      fixture.retainedIndices.clear();
      await fixture.runtime.collectGarbage();
      expect(await fixture.index(_geoUrl).exists(), isTrue);
      expect(await fixture.raw(index['hash'] as String).exists(), isTrue);
      expect(
        await fixture.bundle(first.reference.bundleDigest).exists(),
        isTrue,
      );
      stalled.controller.add(_site('new.example.invalid'));
      await stalled.controller.close();
      final prepared = await pending;
      await prepared.release();
      await fixture.runtime.collectGarbage();
      expect(await fixture.index(_geoUrl).exists(), isFalse);
      expect(await fixture.raw(index['hash'] as String).exists(), isFalse);
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isFalse,
      );
    },
  );

  test(
    'failed or invalid reference enumeration preserves every cache object',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      );
      await prepared.release();
      for (final loader in <Future<ProviderGeoRetention> Function()>[
        () async => throw StateError('Synthetic storage failure'),
        () async => ProviderGeoRetention(
          bundleDigests: {'not-a-digest'},
          rawIndexDigests: {},
        ),
      ]) {
        final runtime = ProviderGeoRuntime(
          dio: fixture.dio,
          directory: () async => fixture.directory,
          retention: loader,
        );
        await expectLater(
          runtime.collectGarbage(),
          throwsA(_issue(ProviderGeoIssue.cache)),
        );
        expect(
          await fixture.bundle(prepared.reference.bundleDigest).exists(),
          isTrue,
        );
      }
    },
  );

  test(
    'malformed retained raw index aborts sweep before deleting any otherwise obsolete bundle',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      );
      await prepared.release();
      await fixture.index(_geoUrl).writeAsString('{"hash":"not-a-digest"}');
      fixture.retainedIndices.add(providerGeoHash(utf8.encode(_geoUrl)));
      await expectLater(
        fixture.runtime.collectGarbage(),
        throwsA(_issue(ProviderGeoIssue.cache)),
      );
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isTrue,
      );
      expect(await fixture.index(_geoUrl).exists(), isTrue);
    },
  );

  test(
    'corrupt obsolete index cannot permanently block valid provider updates',
    () async {
      final fixture = await _fixture(
        (_) async => ResponseBody.fromBytes(_site('node.example.invalid'), 200),
      );
      const oldUrl = 'https://geo.example.invalid/obsolete.dat';
      await fixture.index(oldUrl).parent.create();
      await fixture.index(oldUrl).writeAsString('{"hash":"not-a-digest"}');
      final prepared = await fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(await fixture.index(oldUrl).exists(), isFalse);
      expect(await fixture.index(_geoUrl).exists(), isTrue);
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isTrue,
      );
      await prepared.release();
    },
  );

  test(
    'sweep never removes unknown files, links, or nested directories',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      await Directory('${fixture.directory.path}/raw').create();
      await Directory('${fixture.directory.path}/bundles').create();
      final outside = File('${fixture.directory.path}/outside.txt');
      await outside.writeAsString('Preserve');
      final unknown = File('${fixture.directory.path}/raw/notes.txt');
      await unknown.writeAsString('Preserve');
      final nested = Directory('${fixture.directory.path}/raw/${'a' * 64}.dat');
      await nested.create();
      final child = File('${nested.path}/${'b' * 64}.dat');
      await child.writeAsString('Preserve');
      final link = Link('${fixture.directory.path}/raw/${'c' * 64}.dat');
      await link.create(outside.path);
      final obsolete = fixture.raw('d' * 64);
      await obsolete.writeAsString('Obsolete');
      await fixture.runtime.collectGarbage();
      expect(await obsolete.exists(), isFalse);
      expect(await outside.readAsString(), 'Preserve');
      expect(await unknown.exists(), isTrue);
      expect(await child.exists(), isTrue);
      expect(await link.exists(), isTrue);
    },
  );

  test(
    'a linked cache directory is refused without touching its target',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final outside = await Directory.systemTemp.createTemp(
        'honey-geo-outside-',
      );
      addTearDown(() async => outside.delete(recursive: true));
      final sentinel = File('${outside.path}/keep.txt');
      await sentinel.writeAsString('Preserve');
      await Link('${fixture.directory.path}/raw').create(outside.path);
      await expectLater(
        fixture.runtime.collectGarbage(),
        throwsA(_issue(ProviderGeoIssue.cache)),
      );
      expect(await sentinel.readAsString(), 'Preserve');
    },
  );

  test(
    'obsolete history is reclaimed before the fixed cache quota refuses a write',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final obsolete = fixture.raw('a' * 64);
      await obsolete.parent.create();
      final handle = await obsolete.open(mode: FileMode.write);
      await handle.truncate(ProviderGeoRuntime.maximumCacheBytes);
      await handle.close();
      final prepared = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      );
      expect(await obsolete.exists(), isFalse);
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isTrue,
      );
      await prepared.release();
    },
  );

  test('the quota does not evict live raw data to make room', () async {
    final fixture = await _fixture(
      (_) async => throw StateError('No network expected'),
    );
    final digest = 'a' * 64;
    final live = fixture.raw(digest);
    await live.parent.create();
    final handle = await live.open(mode: FileMode.write);
    await handle.truncate(ProviderGeoRuntime.maximumCacheBytes);
    await handle.close();
    await _seedIndex(fixture, _geoUrl, digest);
    fixture.retainedIndices.add(providerGeoHash(utf8.encode(_geoUrl)));
    await expectLater(
      fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      ),
      throwsA(_issue(ProviderGeoIssue.tooLarge)),
    );
    expect(await live.length(), ProviderGeoRuntime.maximumCacheBytes);
    expect(await fixture.index(_geoUrl).exists(), isTrue);
  });

  test('raw-index growth cannot exceed the fixed cache quota', () async {
    final data = _site('node.example.invalid');
    final fixture = await _fixture(
      (_) async => ResponseBody.fromBytes(data, 200),
    );
    final preserved = File('${fixture.directory.path}/unknown-preserved-file');
    final handle = await preserved.open(mode: FileMode.write);
    await handle.truncate(ProviderGeoRuntime.maximumCacheBytes - data.length);
    await handle.close();
    await expectLater(
      fixture.runtime.prepare(_metadata(), subscriptionUrl: _subscriptionUrl),
      throwsA(_issue(ProviderGeoIssue.tooLarge)),
    );
    expect(await fixture.index(_geoUrl).exists(), isFalse);
    expect(await fixture.raw(providerGeoHash(data)).length(), data.length);
    expect(
      await preserved.length(),
      ProviderGeoRuntime.maximumCacheBytes - data.length,
    );
  });

  test(
    'unavailable declared geo preserves its stored issue in provider and combined modes',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      for (final declarations in [null, _metadata()]) {
        final subscription = SubscriptionModel(
          id: 1,
          url: _subscriptionUrl,
          name: 'Synthetic',
          providerRouting: declarations,
          providerGeoStatus: ProviderGeoStatus.unavailable,
          providerGeoIssue: ProviderGeoIssue.tooLarge,
        );
        for (final mode in [GeoRoutingMode.provider, GeoRoutingMode.combined]) {
          await expectLater(
            fixture.runtime.resolveForSubscription(
              subscription,
              AppSettings(geoRoutingMode: mode),
            ),
            throwsA(_issue(ProviderGeoIssue.tooLarge)),
          );
        }
      }
      expect(fixture.adapter.requests, isEmpty);
    },
  );

  test(
    'missing persisted subscriptions cannot be interpreted as no references',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      );
      await prepared.release();
      final runtime = ProviderGeoRuntime(
        dio: fixture.dio,
        directory: () async => fixture.directory,
      );
      await expectLater(
        runtime.collectGarbage(),
        throwsA(_issue(ProviderGeoIssue.cache)),
      );
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isTrue,
      );
    },
  );

  test(
    'default loader reloads persisted references and retains an off last-good bundle',
    () async {
      SharedPreferences.setMockInitialValues({'nexproxy_subscriptions': '[]'});
      final fixture = await _fixture(
        (_) async => ResponseBody.fromBytes(_site('node.example.invalid'), 200),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(),
        subscriptionUrl: _subscriptionUrl,
      );
      await prepared.release();
      final subscription = SubscriptionModel(
        id: 1,
        url: _subscriptionUrl,
        name: 'Synthetic',
        providerGeo: prepared.reference,
        providerGeoStatus: ProviderGeoStatus.off,
        providerRouting: ProviderRoutingMetadata(
          subscriptionId: 1,
          commands: const [
            ProviderRoutingCommand(operation: ProviderRoutingOperation.off),
          ],
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'nexproxy_subscriptions',
        SubscriptionModel.listToJson([subscription]),
      );
      final runtime = ProviderGeoRuntime(
        dio: fixture.dio,
        directory: () async => fixture.directory,
      );
      await runtime.collectGarbage();
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isTrue,
      );
      expect(await fixture.index(_geoUrl).exists(), isFalse);
      await prefs.setString('nexproxy_subscriptions', '[]');
      await runtime.collectGarbage();
      expect(
        await fixture.bundle(prepared.reference.bundleDigest).exists(),
        isFalse,
      );
    },
  );

  test('malformed persisted references preserve last-good content', () async {
    SharedPreferences.setMockInitialValues({
      'nexproxy_subscriptions': jsonEncode([
        {
          'id': 1,
          'url': _subscriptionUrl,
          'providerGeo': {'schema': 1, 'bundleDigest': '../other'},
        },
      ]),
    });
    final fixture = await _fixture(
      (_) async => throw StateError('No network expected'),
    );
    final prepared = await fixture.runtime.prepare(
      _metadata(geoUrl: null),
      subscriptionUrl: _subscriptionUrl,
    );
    await prepared.release();
    final runtime = ProviderGeoRuntime(
      dio: fixture.dio,
      directory: () async => fixture.directory,
    );
    await expectLater(
      runtime.collectGarbage(),
      throwsA(_issue(ProviderGeoIssue.cache)),
    );
    expect(
      await fixture.bundle(prepared.reference.bundleDigest).exists(),
      isTrue,
    );
  });

  test(
    'corrupt bundle fails on connection while explicit preparation can repair it',
    () async {
      final fixture = await _fixture(
        (_) async => throw StateError('No network expected'),
      );
      final prepared = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
      );
      fixture.retain(prepared);
      await prepared.release();
      await fixture.bundle(prepared.reference.bundleDigest).writeAsString('{}');
      final subscription = SubscriptionModel(
        id: 1,
        url: _subscriptionUrl,
        name: 'Synthetic',
        providerRouting: _metadata(geoUrl: null),
        providerGeo: prepared.reference,
        providerGeoStatus: ProviderGeoStatus.ready,
      );
      await expectLater(
        fixture.runtime.resolveForSubscription(
          subscription,
          const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
        ),
        throwsA(_issue(ProviderGeoIssue.cache)),
      );
      expect(fixture.adapter.requests, isEmpty);
      final repaired = await fixture.runtime.prepare(
        _metadata(geoUrl: null),
        subscriptionUrl: _subscriptionUrl,
        previous: prepared.reference,
      );
      expect(repaired.reference.bundleDigest, prepared.reference.bundleDigest);
      expect(
        (await fixture.runtime.readBundle(
          repaired.reference,
          expectedScope: repaired.reference.scope,
        )).digest,
        repaired.reference.bundleDigest,
      );
      expect(fixture.adapter.requests, isEmpty);
      await repaired.release();
    },
  );
}
