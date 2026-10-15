enum ProviderGeoStatus { absent, ready, updating, stale, unavailable, off }

/// A reference to complete immutable app-owned content, never a caller path.
class ProviderGeoReference {
  const ProviderGeoReference({required this.scope, required this.bundleDigest,
    required this.metadataDigest, required this.updatedAt});
  final String scope, bundleDigest, metadataDigest;
  final DateTime updatedAt;
  Map<String, dynamic> toJson() => {'schema': 1, 'scope': scope,
    'bundleDigest': bundleDigest, 'metadataDigest': metadataDigest,
    'updatedAt': updatedAt.toUtc().toIso8601String()};
  factory ProviderGeoReference.fromJson(Map<String, dynamic> value) {
    final hash = RegExp(r'^[0-9a-f]{64}$');
    if (value['schema'] != 1 || value.keys.any((k) => !{'schema', 'scope',
      'bundleDigest', 'metadataDigest', 'updatedAt'}.contains(k)) ||
      !['scope', 'bundleDigest', 'metadataDigest'].every((k) =>
        value[k] is String && hash.hasMatch(value[k] as String))) {
      throw const FormatException('providerGeo:reference');
    }
    final time = value['updatedAt'] is String
      ? DateTime.tryParse(value['updatedAt'] as String) : null;
    if (time == null) throw const FormatException('providerGeo:reference');
    return ProviderGeoReference(scope: value['scope'] as String,
      bundleDigest: value['bundleDigest'] as String,
      metadataDigest: value['metadataDigest'] as String, updatedAt: time);
  }
}

enum ProviderGeoIssue { absent, off, download, invalid, tooLarge, cache }

/// Stable localizable issue, without provider addresses, query or payload.
class ProviderGeoException implements Exception {
  const ProviderGeoException(this.issue);
  final ProviderGeoIssue issue;
  @override
  String toString() => 'providerGeo:' + issue.name;
}
