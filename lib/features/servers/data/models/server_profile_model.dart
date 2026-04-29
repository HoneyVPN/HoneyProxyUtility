import 'dart:convert';

class ServerProfileModel {
  final int id;
  final String protocol;
  final String name;
  final String host;
  final int port;
  final String configJson;
  final String subscriptionId;
  final DateTime addedAt;
  final double? latencyMs;
  final bool isSelected;
  final bool isFavorite;

  const ServerProfileModel({
    required this.id,
    required this.protocol,
    required this.name,
    required this.host,
    required this.port,
    required this.configJson,
    required this.subscriptionId,
    required this.addedAt,
    this.latencyMs,
    this.isSelected = false,
    this.isFavorite = false,
  });

  ServerProfileModel copyWith({
    double? latencyMs,
    bool? isSelected,
    bool? isFavorite,
  }) => ServerProfileModel(
    id: id,
    protocol: protocol,
    name: name,
    host: host,
    port: port,
    configJson: configJson,
    subscriptionId: subscriptionId,
    addedAt: addedAt,
    latencyMs: latencyMs ?? this.latencyMs,
    isSelected: isSelected ?? this.isSelected,
    isFavorite: isFavorite ?? this.isFavorite,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'protocol': protocol,
    'name': name,
    'host': host,
    'port': port,
    'configJson': configJson,
    'subscriptionId': subscriptionId,
    'addedAt': addedAt.toIso8601String(),
    'latencyMs': latencyMs,
    'isSelected': isSelected,
    'isFavorite': isFavorite,
  };

  factory ServerProfileModel.fromJson(Map<String, dynamic> m) => ServerProfileModel(
    id: m['id'] as int,
    protocol: m['protocol'] as String,
    name: m['name'] as String,
    host: m['host'] as String,
    port: m['port'] as int,
    configJson: m['configJson'] as String,
    subscriptionId: (m['subscriptionId'] as String?) ?? '',
    addedAt: DateTime.parse(m['addedAt'] as String),
    latencyMs: (m['latencyMs'] as num?)?.toDouble(),
    isSelected: (m['isSelected'] as bool?) ?? false,
    isFavorite: (m['isFavorite'] as bool?) ?? false,
  );

  static List<ServerProfileModel> listFromJson(String jsonStr) {
    final list = json.decode(jsonStr) as List<dynamic>;
    return list.map((e) => ServerProfileModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<ServerProfileModel> models) =>
      json.encode(models.map((m) => m.toJson()).toList());
}
