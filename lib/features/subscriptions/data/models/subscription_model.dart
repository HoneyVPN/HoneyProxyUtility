import 'dart:convert';

class SubscriptionModel {
  final int id;
  final String url;
  final String name;
  final DateTime? lastUpdated;
  final int serverCount;
  final bool autoRefresh;
  final int updateIntervalHours; // 0 = manual only; 1 / 6 / 12 / 24

  const SubscriptionModel({
    required this.id,
    required this.url,
    required this.name,
    this.lastUpdated,
    this.serverCount = 0,
    this.autoRefresh = false,
    this.updateIntervalHours = 0,
  });

  SubscriptionModel copyWith({
    String? name,
    DateTime? lastUpdated,
    int? serverCount,
    bool? autoRefresh,
    int? updateIntervalHours,
  }) => SubscriptionModel(
    id: id,
    url: url,
    name: name ?? this.name,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    serverCount: serverCount ?? this.serverCount,
    autoRefresh: autoRefresh ?? this.autoRefresh,
    updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
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
    'autoRefresh': autoRefresh,
    'updateIntervalHours': updateIntervalHours,
  };

  factory SubscriptionModel.fromJson(Map<String, dynamic> m) => SubscriptionModel(
    id: m['id'] as int,
    url: m['url'] as String,
    name: (m['name'] as String?) ?? '',
    lastUpdated: m['lastUpdated'] != null ? DateTime.tryParse(m['lastUpdated'] as String) : null,
    serverCount: (m['serverCount'] as int?) ?? 0,
    autoRefresh: (m['autoRefresh'] as bool?) ?? false,
    updateIntervalHours: (m['updateIntervalHours'] as int?) ?? 0,
  );

  static List<SubscriptionModel> listFromJson(String jsonStr) {
    final list = json.decode(jsonStr) as List<dynamic>;
    return list.map((e) => SubscriptionModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<SubscriptionModel> models) =>
      json.encode(models.map((m) => m.toJson()).toList());
}
