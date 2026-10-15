import 'dart:convert';

import '../../domain/entities/provider_geo_state.dart';
import '../../domain/entities/provider_routing_metadata.dart';
import '../../../converter/data/parsers/provider_routing_parser.dart';

class SubscriptionModel {
  final int id;
  final String url;
  final String name;
  final DateTime? lastUpdated;
  final int serverCount;
  final ProviderRoutingMetadata? providerRouting;
  final ProviderGeoReference? providerGeo;
  final ProviderGeoStatus providerGeoStatus;
  final ProviderGeoIssue? providerGeoIssue;
  final bool updateIntervalOverridden;
  final int updateIntervalHours; // 0 = manual only; 1 / 6 / 12 / 24

  const SubscriptionModel({
    required this.id,
    required this.url,
    required this.name,
    this.lastUpdated,
    this.serverCount = 0,
    this.updateIntervalHours = 0,
    this.updateIntervalOverridden = false,
    this.providerRouting,
    this.providerGeo,
    this.providerGeoStatus = ProviderGeoStatus.absent,
    this.providerGeoIssue,
  });

  SubscriptionModel copyWith({
    String? name,
    DateTime? lastUpdated,
    int? serverCount,
    int? updateIntervalHours,
    bool? updateIntervalOverridden,
    ProviderRoutingMetadata? providerRouting,
    ProviderGeoReference? providerGeo,
    ProviderGeoStatus? providerGeoStatus,
    ProviderGeoIssue? providerGeoIssue,
    bool clearProviderGeoIssue = false,
  }) => SubscriptionModel(
    id: id,
    url: url,
    name: name ?? this.name,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    serverCount: serverCount ?? this.serverCount,
    updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
    updateIntervalOverridden:
        updateIntervalOverridden ?? this.updateIntervalOverridden,
    providerRouting: providerRouting ?? this.providerRouting,
    providerGeo: providerGeo ?? this.providerGeo,
    providerGeoStatus: providerGeoStatus ?? this.providerGeoStatus,
    providerGeoIssue: clearProviderGeoIssue
        ? null
        : providerGeoIssue ?? this.providerGeoIssue,
  );

  bool get needsRefresh {
    if (updateIntervalHours <= 0) return false;
    final lu = lastUpdated;
    if (lu == null) return true;
    return DateTime.now().difference(lu).inHours >= updateIntervalHours;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'name': name,
    'lastUpdated': lastUpdated?.toIso8601String(),
    'serverCount': serverCount,
    'updateIntervalHours': updateIntervalHours,
    'updateIntervalOverridden': updateIntervalOverridden,
    if (providerRouting != null) 'providerRouting': providerRouting!.toJson(),
    if (providerGeo != null) 'providerGeo': providerGeo!.toJson(),
    'providerGeoStatus': providerGeoStatus.name,
    if (providerGeoIssue != null) 'providerGeoIssue': providerGeoIssue!.name,
  };

  factory SubscriptionModel.fromJson(Map<String, dynamic> m) =>
      SubscriptionModel(
        id: m['id'] as int,
        url: m['url'] as String,
        name: (m['name'] as String?) ?? '',
        lastUpdated: m['lastUpdated'] != null
            ? DateTime.tryParse(m['lastUpdated'] as String)
            : null,
        serverCount: (m['serverCount'] as int?) ?? 0,
        updateIntervalHours: (m['updateIntervalHours'] as int?) ?? 0,
        updateIntervalOverridden: m['updateIntervalOverridden'] == true,
        providerRouting: _storedRouting(m),
        providerGeo: _storedGeo(m),
        providerGeoStatus: _storedGeoStatus(m),
        providerGeoIssue: _storedGeoIssue(m),
      );

  static ProviderRoutingMetadata? _storedRouting(Map<String, dynamic> m) {
    try {
      final value = m['providerRouting'];
      if (value == null) return null;
      return const ProviderRoutingParser().parseStored(
        value as Map<String, dynamic>,
        subscriptionId: m['id'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  static ProviderGeoReference? _storedGeo(Map<String, dynamic> m) {
    try {
      final value = m['providerGeo'];
      return value == null
          ? null
          : ProviderGeoReference.fromJson(value as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static ProviderGeoStatus _storedGeoStatus(Map<String, dynamic> m) {
    if ((m['providerRouting'] != null && _storedRouting(m) == null) ||
        (m['providerGeo'] != null && _storedGeo(m) == null)) {
      return ProviderGeoStatus.unavailable;
    }
    if (m['providerGeoStatus'] == 'updating') {
      return _storedGeo(m) == null
          ? ProviderGeoStatus.unavailable
          : ProviderGeoStatus.stale;
    }
    return ProviderGeoStatus.values.firstWhere(
      (value) => value.name == m['providerGeoStatus'],
      orElse: () => ProviderGeoStatus.absent,
    );
  }

  static ProviderGeoIssue? _storedGeoIssue(Map<String, dynamic> m) {
    final status = _storedGeoStatus(m);
    if (status != ProviderGeoStatus.unavailable &&
        status != ProviderGeoStatus.stale)
      return null;
    if ((m['providerRouting'] != null && _storedRouting(m) == null) ||
        (m['providerGeo'] != null && _storedGeo(m) == null))
      return ProviderGeoIssue.invalid;
    return ProviderGeoIssue.values
        .where((issue) => issue.name == m['providerGeoIssue'])
        .firstOrNull;
  }

  static List<SubscriptionModel> listFromJson(String jsonStr) {
    final list = json.decode(jsonStr) as List<dynamic>;
    return list
        .map((e) => SubscriptionModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJson(List<SubscriptionModel> models) =>
      json.encode(models.map((m) => m.toJson()).toList());
}
