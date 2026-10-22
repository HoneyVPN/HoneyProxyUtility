import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../converter/data/parsers/provider_routing_parser.dart';
import '../../../settings/data/models/app_settings.dart';
import '../../../subscriptions/data/models/subscription_model.dart';
import '../../../subscriptions/domain/entities/provider_geo_state.dart';
import '../../../subscriptions/domain/entities/provider_routing_metadata.dart';
import 'provider_geo_bundle.dart';

final providerGeoRuntimeProvider = Provider<ProviderGeoRuntime>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return ProviderGeoRuntime(dio: dio);
});

class ProviderGeoPrepared {
  ProviderGeoPrepared(
    this.reference,
    this.bundle, {
    Future<void> Function()? release,
  }) : _release = release;
  final ProviderGeoReference reference;
  final ProviderGeoBundle bundle;
  final Future<void> Function()? _release;
  Future<void>? _released;

  /// The caller retains this lease until publication's CAS/save finishes, even
  /// when publication is cancelled or rejected. It never changes a VPN session.
  Future<void> release() =>
      _released ??= _release?.call() ?? Future<void>.value();
}

/// Fresh persisted references, not a global selected-provider pointer. Only
/// content digests cross this boundary; cache maintenance never consumes paths.
class ProviderGeoRetention {
  ProviderGeoRetention({
    required Set<String> bundleDigests,
    required Set<String> rawIndexDigests,
  }) : bundleDigests = Set.unmodifiable(bundleDigests),
       rawIndexDigests = Set.unmodifiable(rawIndexDigests);
  final Set<String> bundleDigests, rawIndexDigests;
}

class _GeoLease {
  final bundles = <String>{}, raw = <String>{}, indices = <String>{};
}

typedef _GeoCompileInput = ({
  ProviderRoutingProfile profile,
  String scope,
  String metadataDigest,
  Uint8List? geoSite,
  Uint8List? geoIp,
});

typedef _CompiledGeo = ({
  ProviderGeoBundle bundle,
  Uint8List bytes,
  String digest,
});

_CompiledGeo _compileGeo(_GeoCompileInput input) {
  final bundle = const ProviderGeoCompiler().compile(
    input.profile,
    scope: input.scope,
    metadataDigest: input.metadataDigest,
    geoSite: input.geoSite,
    geoIp: input.geoIp,
  );
  final bytes = utf8.encode(jsonEncode(bundle.toJson()));
  return (bundle: bundle, bytes: bytes, digest: bundle.digest);
}

// Small index/scope hashes are cheaper than starting another isolate. DAT
// files can be 32 MiB; hashing those synchronously stalls every UI animation.
Future<String> _hashGeoBytes(List<int> bytes) async => bytes.length < 64 * 1024
    ? providerGeoHash(bytes)
    : compute(providerGeoHash, bytes, debugLabel: 'hash-provider-geo');

ProviderGeoBundle _decodeGeoBundle(
  ({Uint8List bytes, ProviderGeoReference reference, String expectedScope})
  input,
) {
  if (providerGeoHash(input.bytes) != input.reference.bundleDigest) {
    throw const ProviderGeoException(ProviderGeoIssue.cache);
  }
  final bundle = ProviderGeoBundle.fromJson(
    jsonDecode(utf8.decode(input.bytes)) as Map<String, dynamic>,
  );
  if (bundle.scope != input.expectedScope ||
      bundle.metadataDigest != input.reference.metadataDigest) {
    throw const ProviderGeoException(ProviderGeoIssue.cache);
  }
  // Warm the immutable bundle's cached hash before it returns to UI consumers.
  bundle.digest;
  return bundle;
}

/// Downloader runs as the app user. The privileged Windows service receives
/// bounded typed inline sets only; it never opens these cache paths or URLs.
class ProviderGeoRuntime {
  ProviderGeoRuntime({
    required Dio dio,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
    Future<ProviderGeoRetention> Function()? retention,
  }) : _dio = dio,
       _directory = directory ?? _defaultDirectory,
       _now = now ?? DateTime.now,
       _retention = retention ?? _persistedRetention;
  static const maximumFileBytes = 32 * 1024 * 1024;
  static const maximumCacheBytes = 256 * 1024 * 1024;
  static const cacheInterval = Duration(days: 7);
  final Dio _dio;
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final Future<ProviderGeoRetention> Function() _retention;
  final _random = Random.secure();
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  final _leases = <_GeoLease>{};
  Future<void> _maintenance = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() operation) {
    final result = _maintenance.then((_) => operation());
    _maintenance = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static Future<ProviderGeoRetention> _persistedRetention() async {
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences caches values in memory. Sweep must see the completed
    // persistent CAS, including saves performed by a different notifier.
    await prefs.reload();
    final text = prefs.getString('nexproxy_subscriptions');
    if (text == null || text.length > 8 * 1024 * 1024) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    return compute(_parseRetention, text, debugLabel: 'retain-provider-geo');
  }

  static ProviderGeoRetention _parseRetention(String text) {
    try {
      if (utf8.encode(text).length > 8 * 1024 * 1024) {
        throw const ProviderGeoException(ProviderGeoIssue.cache);
      }
      final rows = jsonDecode(text);
      if (rows is! List || rows.length > 4096) {
        throw const FormatException('providerGeo:references');
      }
      final bundles = <String>{}, indices = <String>{};
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row['id'] is! int ||
            (row['id'] as int) <= 0 ||
            row['url'] is! String ||
            (row['url'] as String).isEmpty) {
          throw const FormatException('providerGeo:references');
        }
        final reference = row['providerGeo'];
        if (reference != null) {
          final value = ProviderGeoReference.fromJson(
            reference as Map<String, dynamic>,
          );
          // Retention is conservative: even a reference with an outdated scope
          // is kept. Connection-time scope validation still rejects its use;
          // maintenance must not prevent a later refresh from repairing it.
          bundles.add(value.bundleDigest);
        }
        final metadata = row['providerRouting'];
        if (metadata != null) {
          final profile = activeProfile(
            const ProviderRoutingParser().parseStored(
              metadata as Map<String, dynamic>,
              subscriptionId: row['id'] as int,
            ),
          );
          if (profile != null) {
            for (final url in [profile.geoSiteUrl, profile.geoIpUrl]) {
              if (url != null) indices.add(providerGeoHash(utf8.encode(url)));
            }
          }
        }
      }
      return ProviderGeoRetention(
        bundleDigests: bundles,
        rawIndexDigests: indices,
      );
    } catch (_) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(support.path + '/provider_geo');
  }

  static void _throwIfCancelled(CancelToken? token) {
    final error = token?.cancelError;
    if (error != null) throw error;
  }

  static ProviderRoutingProfile? activeProfile(
    ProviderRoutingMetadata metadata,
  ) {
    ProviderRoutingProfile? result;
    for (final command in metadata.commands) {
      if (command.operation == ProviderRoutingOperation.off) {
        result = null;
      } else {
        result = command.profile;
      }
    }
    return result;
  }

  /// No network on connection. A complete last-good bundle can be retained
  /// after download failure; the subscription's persisted stale status makes
  /// that visible separately from proxy-feed success.
  Future<ProviderGeoBundle?> resolveForSubscription(
    SubscriptionModel? subscription,
    AppSettings settings,
  ) async {
    if (settings.routingMode == RoutingMode.global ||
        settings.geoRoutingMode == GeoRoutingMode.builtIn)
      return null;
    if (subscription == null ||
        (subscription.providerRouting == null &&
            subscription.providerGeoStatus == ProviderGeoStatus.absent)) {
      if (settings.geoRoutingMode == GeoRoutingMode.combined) return null;
      throw const ProviderGeoException(ProviderGeoIssue.absent);
    }
    if (subscription.providerRouting == null &&
        subscription.providerGeoStatus == ProviderGeoStatus.unavailable) {
      throw ProviderGeoException(
        subscription.providerGeoIssue ?? ProviderGeoIssue.invalid,
      );
    }
    if (subscription.providerGeoStatus == ProviderGeoStatus.off) {
      if (settings.geoRoutingMode == GeoRoutingMode.combined) return null;
      throw const ProviderGeoException(ProviderGeoIssue.off);
    }
    final reference = subscription.providerGeo;
    if (reference == null) {
      throw ProviderGeoException(
        subscription.providerGeoIssue ?? ProviderGeoIssue.absent,
      );
    }
    return readBundle(
      reference,
      expectedScope: providerGeoScope(subscription.id, subscription.url),
    );
  }

  Future<ProviderGeoPrepared> prepare(
    ProviderRoutingMetadata metadata, {
    required String subscriptionUrl,
    ProviderGeoReference? previous,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final profile = activeProfile(metadata);
    if (profile == null) {
      throw const ProviderGeoException(ProviderGeoIssue.off);
    }
    final scope = providerGeoScope(metadata.subscriptionId, subscriptionUrl);
    final metadataHash = providerMetadataDigest(metadata);
    final force = forceRefresh;
    final lease = _GeoLease();
    for (final url in [profile.geoSiteUrl, profile.geoIpUrl]) {
      if (url != null) lease.indices.add(providerGeoHash(utf8.encode(url)));
    }
    if (previous?.scope == scope && _hash.hasMatch(previous!.bundleDigest)) {
      lease.bundles.add(previous.bundleDigest);
    }
    await _locked(() async {
      _leases.add(lease);
    });
    var transferred = false;
    try {
      final needsSite = [
        ...profile.blockSites,
        ...profile.proxySites,
        ...profile.directSites,
      ].any((rule) => rule.kind == ProviderRuleKind.geoSite);
      final needsIp = [
        ...profile.blockIp,
        ...profile.proxyIp,
        ...profile.directIp,
      ].any((rule) => rule.kind == ProviderRuleKind.geoIp);
      final site = needsSite
          ? await _geoFile(
              profile.geoSiteUrl,
              lease: lease,
              force: force,
              revisionHint: profile.lastUpdatedUnix,
              cancelToken: cancelToken,
            )
          : null;
      final ip = needsIp
          ? await _geoFile(
              profile.geoIpUrl,
              lease: lease,
              force: force,
              revisionHint: profile.lastUpdatedUnix,
              cancelToken: cancelToken,
            )
          : null;
      _throwIfCancelled(cancelToken);
      // DAT decoding, rule validation, sorting, JSON encoding and SHA256 all
      // run away from the rendering isolate. The worker captures no runtime,
      // HTTP client, cancellation token or cache lease.
      final compiled = await compute(_compileGeo, (
        profile: profile,
        scope: scope,
        metadataDigest: metadataHash,
        geoSite: site,
        geoIp: ip,
      ), debugLabel: 'compile-provider-geo');
      _throwIfCancelled(cancelToken);
      await _locked(() async {
        _throwIfCancelled(cancelToken);
        final dir = await _readyDirectory('bundles');
        lease.bundles.add(compiled.digest);
        await _writeImmutable(
          File(dir.path + '/' + compiled.digest + '.json'),
          compiled.bytes,
        );
        await _collectLocked();
      });
      _throwIfCancelled(cancelToken);
      final result = ProviderGeoPrepared(
        ProviderGeoReference(
          scope: scope,
          bundleDigest: compiled.digest,
          metadataDigest: metadataHash,
          updatedAt: _now(),
        ),
        compiled.bundle,
        release: () => _releaseLease(lease),
      );
      transferred = true;
      return result;
    } on ProviderGeoException {
      rethrow;
    } on DioException {
      if (cancelToken?.isCancelled == true) rethrow;
      throw const ProviderGeoException(ProviderGeoIssue.download);
    } on FormatException {
      throw const ProviderGeoException(ProviderGeoIssue.invalid);
    } on FileSystemException {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    } finally {
      if (!transferred) await _releaseLease(lease);
    }
  }

  Future<void> _releaseLease(_GeoLease lease) => _locked(() async {
    _leases.remove(lease);
  });

  Future<ProviderGeoBundle> readBundle(
    ProviderGeoReference reference, {
    required String expectedScope,
  }) async {
    if (reference.scope != expectedScope) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    try {
      if (!_hash.hasMatch(reference.bundleDigest)) {
        throw const ProviderGeoException(ProviderGeoIssue.cache);
      }
      final bytes = await _locked(() async {
        final dir = await _readyDirectory('bundles');
        return _readBounded(
          File(dir.path + '/' + reference.bundleDigest + '.json'),
          ProviderGeoBundle.maximumInlineBytes + 4096,
        );
      });
      return await compute(_decodeGeoBundle, (
        bytes: bytes,
        reference: reference,
        expectedScope: expectedScope,
      ), debugLabel: 'read-provider-geo');
    } on ProviderGeoException {
      rethrow;
    } catch (_) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
  }

  Future<Uint8List> _geoFile(
    String? location, {
    required _GeoLease lease,
    required bool force,
    int? revisionHint,
    CancelToken? cancelToken,
  }) async {
    if (location == null) {
      throw const ProviderGeoException(ProviderGeoIssue.absent);
    }
    final original = _https(location);
    final indexKey = providerGeoHash(utf8.encode(location));
    late File index;
    Map<String, dynamic>? stored;
    Uint8List? old;
    await _locked(() async {
      lease.indices.add(indexKey);
      final raw = await _readyDirectory('raw');
      index = File(raw.path + '/' + indexKey + '.index.json');
      try {
        stored = _parseIndex(await _readBounded(index, 4096));
        final hash = stored!['hash'] as String;
        old = await _readBounded(
          File(raw.path + '/' + hash + '.dat'),
          maximumFileBytes,
        );
        if (await _hashGeoBytes(old!) != hash)
          throw const FormatException('providerGeo:hash');
        lease.raw.add(hash);
      } catch (_) {
        stored = null;
        old = null;
      }
    });
    final fetchedText = stored?['fetchedAt'];
    final fetched = fetchedText is String
        ? DateTime.tryParse(fetchedText)
        : null;
    final oldRevision = stored?['revisionHint'];
    final revisionChanged =
        revisionHint != null &&
        (oldRevision is! int || revisionHint > oldRevision);
    if (!force &&
        !revisionChanged &&
        old != null &&
        fetched != null &&
        !_now().isBefore(fetched) &&
        _now().difference(fetched) < cacheInterval) {
      return old!;
    }
    final ownToken = CancelToken();
    if (cancelToken != null) {
      _throwIfCancelled(cancelToken);
      unawaited(
        cancelToken.whenCancel.then((_) => ownToken.cancel('Geo cancelled')),
      );
    }
    final etag = stored?['etag'];
    final safeEtag =
        etag is String &&
            etag.length <= 512 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(etag)
        ? etag
        : null;
    Future<(Uint8List, String?)> download() async {
      var url = original;
      for (var redirects = 0; redirects <= 5; redirects++) {
        _throwIfCancelled(ownToken);
        final responseToken = CancelToken();
        unawaited(
          ownToken.whenCancel.then(
            (_) => responseToken.cancel('Geo cancelled'),
          ),
        );
        late Response<ResponseBody> response;
        try {
          response = await _dio.get<ResponseBody>(
            url.toString(),
            cancelToken: responseToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (s) =>
                  s != null &&
                  (s == 200 ||
                      s == 304 ||
                      {301, 302, 303, 307, 308}.contains(s)),
              headers: {
                if (old != null && safeEtag != null) 'If-None-Match': safeEtag,
              },
            ),
          );
        } on DioException catch (error) {
          final body = error.response?.data;
          await _discardBody(body is ResponseBody ? body : null, responseToken);
          rethrow;
        }
        if (response.statusCode == 304) {
          await _discardBody(response.data, responseToken);
          if (old == null || safeEtag == null) {
            throw const ProviderGeoException(ProviderGeoIssue.invalid);
          }
          return (old!, safeEtag);
        }
        if (response.statusCode != 200) {
          await _discardBody(response.data, responseToken);
          final redirect = response.headers.value('location');
          if (redirect == null || redirects == 5) {
            throw const ProviderGeoException(ProviderGeoIssue.download);
          }
          url = _https(url.resolve(redirect).toString());
          continue;
        }
        final body = response.data;
        if (body == null)
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        final declared = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (declared != null && declared > maximumFileBytes) {
          ownToken.cancel('Geo size');
          await _discardBody(body, responseToken);
          throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > maximumFileBytes) {
            ownToken.cancel('Geo size');
            throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
          }
          bytes.add(chunk);
        }
        if (bytes.length == 0)
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        final tag = response.headers.value('etag');
        return (
          bytes.takeBytes(),
          tag != null &&
                  tag.length <= 512 &&
                  !RegExp(r'[\x00-\x1f\x7f]').hasMatch(tag)
              ? tag
              : null,
        );
      }
      throw const ProviderGeoException(ProviderGeoIssue.download);
    }

    final result = await download().timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        ownToken.cancel('Geo deadline');
        throw const ProviderGeoException(ProviderGeoIssue.download);
      },
    );
    final digest = await _hashGeoBytes(result.$1);
    await _locked(() async {
      _throwIfCancelled(cancelToken);
      lease.raw.add(digest);
      await _writeImmutable(
        File(index.parent.path + '/' + digest + '.dat'),
        result.$1,
      );
      await _replaceIndex(
        index,
        utf8.encode(
          jsonEncode({
            'hash': digest,
            'etag': result.$2,
            'fetchedAt': _now().toUtc().toIso8601String(),
            if (revisionHint != null) 'revisionHint': revisionHint,
          }),
        ),
      );
      await _collectLocked();
    });
    return result.$1;
  }

  Uri _https(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        text.contains(r'\') ||
        RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(text) ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const ProviderGeoException(ProviderGeoIssue.invalid);
    }
    return uri;
  }

  Future<Directory> _readyDirectory(String name) async {
    if (name != 'raw' && name != 'bundles') {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    final root = await _directory();
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    await root.create(recursive: true);
    final directory = Directory(root.path + '/' + name);
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    await directory.create();
    return directory;
  }

  Future<Uint8List> _readBounded(File file, int maximum) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final part in file.openRead()) {
      if (bytes.length + part.length > maximum) {
        throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
      }
      bytes.add(part);
    }
    return bytes.takeBytes();
  }

  Future<void> _writeImmutable(File file, List<int> bytes) async {
    final name = RegExp(
      r'^([a-f0-9]{64})\.(dat|json)$',
    ).firstMatch(file.uri.pathSegments.last);
    if (name == null || await _hashGeoBytes(bytes) != name.group(1)) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    if (type == FileSystemEntityType.file) {
      if (await file.length() == bytes.length) {
        final current = await _readBounded(file, bytes.length);
        if (await _hashGeoBytes(current) == name.group(1)) return;
      }
      // A fresh download/compiler has reconstructed the exact content-addressed
      // object. Replace only this corrupt regular file; keeping it would make
      // an unchanged provider asset impossible to repair by refreshing.
      await _replaceIndex(file, bytes);
      return;
    }
    if (await _cacheUsageLocked() + bytes.length > maximumCacheBytes) {
      await _collectLocked();
    }
    if (await _cacheUsageLocked() + bytes.length > maximumCacheBytes) {
      throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
    }
    await _replaceIndex(file, bytes);
  }

  Future<void> _replaceIndex(File file, List<int> bytes) async {
    final existing = await FileSystemEntity.type(file.path, followLinks: false);
    if (existing != FileSystemEntityType.notFound &&
        existing != FileSystemEntityType.file) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    final oldLength = existing == FileSystemEntityType.file
        ? await file.length()
        : 0;
    final growth = bytes.length - oldLength;
    if (await _cacheUsageLocked() + growth > maximumCacheBytes) {
      await _collectLocked();
    }
    if (await _cacheUsageLocked() + growth > maximumCacheBytes) {
      throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
    }
    final temp = File(
      file.path + '.part-' + _random.nextInt(1 << 32).toRadixString(16),
    );
    try {
      await temp.create(exclusive: true);
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  static Future<void> _discardBody(
    ResponseBody? body,
    CancelToken token,
  ) async {
    // Do not drain an untrusted response: even a redirect can have an endless
    // body. Cancelling this response subscription leaves the next request alive.
    final subscription = body?.stream.listen(
      (_) {},
      onError: (Object _) {},
      cancelOnError: true,
    );
    // Dio 5.9.2 wraps the adapter stream with its own controller; cancelling only
    // the returned stream does not cancel that underlying subscription. A token
    // dedicated to this response also retires the underlying adapter stream.
    token.cancel('Geo response discarded');
    try {
      if (subscription != null) {
        await subscription.cancel().timeout(const Duration(seconds: 2));
      }
    } on TimeoutException {
      throw const ProviderGeoException(ProviderGeoIssue.download);
    }
  }

  static Map<String, dynamic> _parseIndex(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !{'hash', 'etag', 'fetchedAt', 'revisionHint'}.contains(key),
        ) ||
        value['hash'] is! String ||
        !_hash.hasMatch(value['hash'] as String) ||
        value['fetchedAt'] is! String ||
        DateTime.tryParse(value['fetchedAt'] as String) == null ||
        (value['etag'] != null &&
            (value['etag'] is! String ||
                (value['etag'] as String).length > 512 ||
                RegExp(
                  r'[\x00-\x1f\x7f]',
                ).hasMatch(value['etag'] as String))) ||
        (value['revisionHint'] != null &&
            (value['revisionHint'] is! int ||
                (value['revisionHint'] as int) < 0))) {
      throw const FormatException('providerGeo:index');
    }
    return value;
  }

  /// Safe to call after a persisted subscription deletion. Prepared results
  /// remain pinned until release(), including during another subscription's CAS.
  Future<void> collectGarbage() => _locked(() async {
    try {
      await _collectLocked();
    } on ProviderGeoException {
      rethrow;
    } catch (_) {
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
  });

  Future<void> _collectLocked() async {
    final ProviderGeoRetention retained;
    try {
      retained = await _retention();
      if (!retained.bundleDigests.every(_hash.hasMatch) ||
          !retained.rawIndexDigests.every(_hash.hasMatch)) {
        throw const FormatException('providerGeo:references');
      }
    } catch (_) {
      // Never interpret failed/missing enumeration as an empty reference set.
      throw const ProviderGeoException(ProviderGeoIssue.cache);
    }
    final bundles = {...retained.bundleDigests};
    final indices = {...retained.rawIndexDigests};
    final raw = <String>{};
    for (final lease in _leases) {
      bundles.addAll(lease.bundles);
      indices.addAll(lease.indices);
      raw.addAll(lease.raw);
    }
    final rawDirectory = await _readyDirectory('raw');
    final bundleDirectory = await _readyDirectory('bundles');
    final rawEntries = await rawDirectory.list(followLinks: false).toList();
    final bundleEntries = await bundleDirectory
        .list(followLinks: false)
        .toList();
    final obsoleteIndices = <File>[];
    // Validate every retained index before deleting anything. Fresh, complete
    // URL-reference enumeration proves an unretained index obsolete without
    // interpreting its payload; a corrupt historical index cannot block repair.
    for (final entry in rawEntries) {
      final name = entry.uri.pathSegments.last;
      final match = RegExp(r'^([a-f0-9]{64})\.index\.json$').firstMatch(name);
      if (match == null) continue;
      if (!indices.contains(match.group(1))) {
        if (await FileSystemEntity.type(entry.path, followLinks: false) ==
            FileSystemEntityType.file) {
          obsoleteIndices.add(File(entry.path));
        }
        continue;
      }
      try {
        final value = _parseIndex(await _readBounded(File(entry.path), 4096));
        raw.add(value['hash'] as String);
      } catch (_) {
        throw const ProviderGeoException(ProviderGeoIssue.cache);
      }
    }
    for (final index in obsoleteIndices) {
      await _deleteRegular(index);
    }
    for (final entry in rawEntries) {
      final match = RegExp(
        r'^([a-f0-9]{64})\.dat$',
      ).firstMatch(entry.uri.pathSegments.last);
      if (match != null && !raw.contains(match.group(1))) {
        await _deleteRegular(File(entry.path));
      }
    }
    for (final entry in bundleEntries) {
      final match = RegExp(
        r'^([a-f0-9]{64})\.json$',
      ).firstMatch(entry.uri.pathSegments.last);
      if (match != null && !bundles.contains(match.group(1))) {
        await _deleteRegular(File(entry.path));
      }
    }
  }

  static Future<void> _deleteRegular(File file) async {
    // No links, directories, arbitrary names, or recursive deletion. A changed
    // entry is preserved instead of being followed or presumed owned.
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  Future<int> _cacheUsageLocked() async {
    final root = await _directory();
    var total = 0;
    // Count only direct regular files. Do not descend into unknown directories
    // or follow a link while measuring a caller-uncontrolled cache root.
    for (final directory in [
      root,
      await _readyDirectory('raw'),
      await _readyDirectory('bundles'),
    ]) {
      await for (final entry in directory.list(followLinks: false)) {
        if (await FileSystemEntity.type(entry.path, followLinks: false) ==
            FileSystemEntityType.file) {
          total += await File(entry.path).length();
        }
      }
    }
    return total;
  }
}
