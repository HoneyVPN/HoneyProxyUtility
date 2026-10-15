import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'diagnostic_android.dart';
import 'diagnostic_core_versions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../connection/domain/entities/connection_state.dart';
import '../../connection/presentation/notifiers/connection_notifier.dart';
import '../../settings/data/models/app_settings.dart';
import '../../settings/presentation/notifiers/settings_notifier.dart';
import '../../servers/data/models/server_profile_model.dart';
import '../../servers/presentation/notifiers/servers_notifier.dart';
import '../../subscriptions/data/services/subscriptions_notifier.dart';
import 'diagnostic_journal.dart';
import 'diagnostic_redactor.dart';
import 'diagnostic_connection_details.dart';

class DiagnosticReport {
  DiagnosticReport(Map<String, Object?> data)
    : data = Map.unmodifiable(data),
      bytes = utf8.encode(jsonEncode(data)) {
    if (bytes.length > maximumBytes)
      throw const FormatException('diagnostic:size');
  }
  static const maximumBytes = 512 * 1024;
  final Map<String, Object?> data;
  final List<int> bytes;
  int get errorCount => (data['events'] as List)
      .where((row) => (row as Map)['level'] == 'error')
      .length;
}

/// No profile URLs, hostnames, profile IDs, selected names or configuration are
/// fields in the schema. Existing values are used only as redaction needles.
class DiagnosticReportBuilder {
  DiagnosticReportBuilder({
    DiagnosticJournal? journal,
    Future<Map<String, Object?>> Function()? native,
  }) : journal = journal ?? DiagnosticJournal.shared,
       native = native ?? readAndroidDiagnostics;
  final DiagnosticJournal journal;
  final Future<Map<String, Object?>> Function() native;
  Future<DiagnosticReport> build({
    required AppSettings settings,
    required NexConnectionState connection,
    required SubscriptionsState subscriptions,
    required List<ServerProfileModel> profiles,
    String description = '',
    PackageInfo? package,
    DateTime? now,
    String? platform,
    bool profilesLoaded = true,
    bool subscriptionsLoaded = true,
  }) async {
    await journal.initialize();
    final frozenEvents = journal.events;
    final info = package ?? await PackageInfo.fromPlatform();
    final snapshot = await native();
    final secrets = <String>[];
    var secretBytes = 0, configBytes = 0, nodes = 0;
    final contextProfiles = [
      ...profiles.take(257),
      if (connection.activeServer != null &&
          !profiles
              .take(257)
              .any(
                (p) => p.hasSameConnectionIdentity(connection.activeServer!),
              ))
        connection.activeServer!,
    ];
    var contextTooLarge =
        !profilesLoaded ||
        !subscriptionsLoaded ||
        contextProfiles.length > 256 ||
        subscriptions.subs.length > 128;
    void needle(String value) {
      if (contextTooLarge || value.isEmpty || secrets.contains(value)) return;
      if (secrets.length >= 512 || secretBytes + value.length > 65536) {
        contextTooLarge = true;
        return;
      }
      secrets.add(value);
      secretBytes += value.length;
    }

    void visit(Object? node, int depth) {
      if (contextTooLarge) return;
      if (depth > 8 || ++nodes > 2048) {
        contextTooLarge = true;
        return;
      }
      if (node is String) {
        needle(node);
        if (!contextTooLarge && node.contains('://')) {
          try {
            if (node.length > 16384) {
              contextTooLarge = true;
              return;
            }
            final uri = Uri.parse(node);
            needle(uri.host);
            needle(Uri.decodeComponent(uri.fragment));
            final user = Uri.decodeComponent(uri.userInfo);
            needle(user);
            for (final part in user.split(':')) {
              needle(part);
            }
            for (final value in uri.queryParametersAll.values.expand(
              (v) => v,
            )) {
              needle(value);
            }
            for (final part in uri.pathSegments) {
              needle(part);
            }
            if (uri.scheme == 'vmess' || uri.scheme == 'ss') {
              final encoded = uri.userInfo.isNotEmpty
                  ? uri.userInfo
                  : node
                        .substring(node.indexOf('://') + 3)
                        .split(RegExp(r'[?#]'))
                        .first;
              final decoded = uri.scheme == 'ss' && user.contains(':')
                  ? user
                  : utf8.decode(base64.decode(base64.normalize(encoded)));
              if ((configBytes += decoded.length) > 256 * 1024) {
                contextTooLarge = true;
                return;
              }
              if (uri.scheme == 'vmess') {
                visit(jsonDecode(decoded), depth + 1);
              } else {
                for (final part in decoded.split(RegExp(r'[:@]'))) {
                  needle(part);
                }
              }
            }
          } catch (_) {
            contextTooLarge = true;
          }
        }
      } else if (node is Map) {
        if (node.length > 128) {
          contextTooLarge = true;
          return;
        }
        for (final entry in node.entries) {
          if (contextTooLarge) break;
          if (entry.value is num &&
              RegExp(
                r'password|passwd|uuid|key|secret|token',
                caseSensitive: false,
              ).hasMatch(entry.key.toString()))
            needle(entry.value.toString());
          else
            visit(entry.value, depth + 1);
        }
      } else if (node is List) {
        if (node.length > 128) {
          contextTooLarge = true;
          return;
        }
        for (final value in node) {
          if (contextTooLarge) break;
          visit(value, depth + 1);
        }
      }
    }

    for (final profile in contextProfiles.take(256)) {
      if (contextTooLarge) break;
      for (final value in [
        profile.name,
        profile.host,
        profile.subscriptionId,
      ]) {
        needle(value);
      }
      if (profile.configJson.length > 65536 ||
          (configBytes += profile.configJson.length) > 256 * 1024) {
        contextTooLarge = true;
        break;
      }
      try {
        final raw = jsonDecode(profile.configJson);
        if (raw is! Map) {
          contextTooLarge = true;
          break;
        }
        visit(raw, 0);
      } catch (_) {
        contextTooLarge = true;
        break;
      }
    }
    for (final sub in subscriptions.subs.take(128)) {
      if (contextTooLarge) break;
      needle(sub.name);
      needle(sub.url);
    }
    needle(settings.customDnsUrl);
    final redactor = DiagnosticRedactor(secrets: secrets);
    final instant = now ?? DateTime.now();
    int age(DateTime? t) =>
        t == null ? -1 : instant.difference(t).inHours.clamp(0, 87600);
    final rows = subscriptions.subs.take(128).indexed.map((pair) {
      final (index, sub) = pair;
      return <String, Object>{
        'slot': index + 1,
        'serverCount': sub.serverCount.clamp(0, 100000),
        'refresh': subscriptions.refreshing.contains(sub.id)
            ? 'updating'
            : subscriptions.failures[sub.id]?.name ?? 'ok',
        'updateIntervalHours': sub.updateIntervalHours.clamp(0, 8760),
        'updateIntervalOverridden': sub.updateIntervalOverridden,
        'lastUpdateAgeHours': age(sub.lastUpdated),
        'geoStatus': sub.providerGeoStatus.name,
        'geoIssue': sub.providerGeoIssue?.name ?? 'none',
        'geoCachePresent': sub.providerGeo != null,
        'geoAgeHours': age(sub.providerGeo?.updatedAt),
      };
    }).toList();
    final events = [
      ...frozenEvents.map((e) => e.toJson(redactor)),
      ...snapshot['events'] as List,
    ].cast<Map<String, Object>>();
    events.sort((a, b) => (a['time'] as String).compareTo(b['time'] as String));
    if (contextTooLarge) {
      for (final event in events) {
        event['message'] = '[text omitted: redaction context limit]';
      }
    }
    final bounded = events.length > 300
        ? events.sublist(events.length - 300)
        : events;
    final random = Random.secure();
    return DiagnosticReport({
      'schema': 1,
      'requestId': List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      'createdAt': instant.toUtc().toIso8601String(),
      'description': contextTooLarge
          ? '[text omitted: redaction context limit]'
          : redactor.text(description, limit: 1000),
      'app': {
        'version': const DiagnosticRedactor().text(info.version, limit: 64),
        'build': const DiagnosticRedactor().text(info.buildNumber, limit: 64),
        'platform': platform ?? (kIsWeb ? 'web' : defaultTargetPlatform.name),
      },
      'cores': diagnosticCoreVersions(
        platform ?? (kIsWeb ? 'web' : defaultTargetPlatform.name),
      ),
      'native': {
        'availability': snapshot['availability'],
        'state': snapshot['state'],
        'apiLevel': snapshot['apiLevel'],
        'droppedEvents': snapshot['droppedEvents'] ?? 0,
      },
      'connection': {
        'state': connection.status.name,
        ...diagnosticConnectionDetails(
          contextTooLarge ? null : connection.activeServer,
        ),
        'protocol': _protocol(connection.activeServer?.protocol),
        'mode': settings.connectionMode.name,
        'routing': settings.routingMode.name,
        'geoMode': settings.geoRoutingMode.name,
        'logLevel': settings.logLevel.name,
        'dns': settings.dnsPreset.name,
        'ipType': settings.preferredIpType.name,
        'tunStack': settings.tunStack.name,
        'fakeip': settings.enableFakeip,
        'fragmentation': settings.fragmentationEnabled,
        'multiplexer': settings.multiplexerEnabled,
        'allowLan': settings.allowLanConnections,
        'error': contextTooLarge
            ? '[text omitted: redaction context limit]'
            : redactor.text(connection.errorMessage ?? ''),
      },
      'coverage': {
        'persistedAppEvents': journal.persist && journal.storageAvailable,
        'androidCoreEvents': snapshot['availability'] == 'available',
        'windowsSessionEvents': bounded.any(
          (e) => e['source'] == 'windows-session',
        ),
        'windowsCoreEvents': bounded.any((e) => e['source'] == 'windows-core'),
        'rawWindowsCoreOutput': false,
        'installerLog': false,
        'historyLimited': true,
        'redactionContextComplete': !contextTooLarge,
        'appEntriesDroppedThisRun': journal.droppedThisRun,
      },
      'subscriptions': rows,
      'subscriptionsOmitted': subscriptions.subs.length > 128,
      'events': bounded,
    });
  }

  static String _protocol(String? value) {
    final protocol = value?.toLowerCase();
    return const {
          'vless',
          'vmess',
          'trojan',
          'ss',
          'shadowsocks',
          'hysteria',
          'hysteria2',
          'hy2',
          'tuic',
          'wireguard',
          'awg',
          'socks',
          'http',
        }.contains(protocol)
        ? protocol!
        : 'unknown';
  }
}

final diagnosticReportBuilderProvider = Provider(
  (ref) => DiagnosticReportBuilder(),
);
Future<DiagnosticReport> buildDiagnosticReport(
  WidgetRef ref, {
  String description = '',
}) => ref
    .read(diagnosticReportBuilderProvider)
    .build(
      settings: ref.read(settingsProvider).value ?? const AppSettings(),
      connection: ref.read(connectionNotifierProvider),
      subscriptions:
          ref.read(subscriptionsProvider).value ?? const SubscriptionsState(),
      profiles: ref.read(serversNotifierProvider).value ?? [],
      profilesLoaded:
          ref.read(serversNotifierProvider).hasValue &&
          !ref.read(serversNotifierProvider).isLoading,
      subscriptionsLoaded:
          ref.read(subscriptionsProvider).hasValue &&
          !ref.read(subscriptionsProvider).isLoading,
      description: description,
    );
