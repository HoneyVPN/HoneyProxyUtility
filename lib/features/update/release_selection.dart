/// Release selection is independent of platform plugins so it can be tested
/// against all supported device architectures.
String selectAndroidReleaseUrl(
  List<Map<String, dynamic>> assets,
  List<String> supportedAbis,
) {
  // A single universal release is also understood by the original updater,
  // which otherwise selected ARM64 even on ARMv7/x86_64 devices.
  for (final asset in assets) {
    final name = (asset['name'] as String? ?? '').toLowerCase();
    if (name.endsWith('-universal.apk') &&
        supportedAbis.any(['armeabi-v7a', 'arm64-v8a', 'x86_64'].contains)) {
      final url = _trustedUrl(asset);
      if (url.isNotEmpty) return url;
    }
  }
  for (final abi in supportedAbis) {
    for (final asset in assets) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      final abiToken = RegExp(
        '(?:^|[-_.])${RegExp.escape(abi.toLowerCase())}(?=[-.]|\$)',
      );
      if (name.endsWith('.apk') && abiToken.hasMatch(name)) {
        final url = _trustedUrl(asset);
        if (url.isNotEmpty) return url;
      }
    }
  }
  // Only a universal APK can be a fallback. An arbitrary APK may contain a
  // different architecture and fail to install (or lack the VPN core).
  for (final asset in assets) {
    final name = (asset['name'] as String? ?? '').toLowerCase();
    if (name.endsWith('.apk') &&
        supportedAbis.any(['armeabi-v7a', 'arm64-v8a', 'x86_64'].contains) &&
        !['arm64', 'armeabi', 'x86', 'riscv'].any(name.contains)) {
      return _trustedUrl(asset);
    }
  }
  return '';
}

String selectWindowsReleaseUrl(List<Map<String, dynamic>> assets) {
  for (final asset in assets) {
    if ((asset['name'] as String? ?? '').toLowerCase().endsWith('.exe')) {
      return _trustedUrl(asset);
    }
  }
  return '';
}

String _trustedUrl(Map<String, dynamic> asset) {
  final value = asset['browser_download_url'] as String? ?? '';
  final uri = Uri.tryParse(value);
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host == 'github.com' &&
          uri.path.startsWith('/HoneyVPN/HoneyProxyUtility/releases/download/')
      ? value
      : '';
}

/// Returns null for malformed versions rather than advertising a false update.
int? compareReleaseVersions(String a, String b) {
  final av = _ReleaseVersion.tryParse(a);
  final bv = _ReleaseVersion.tryParse(b);
  if (av == null || bv == null) return null;
  for (var i = 0; i < 3; i++) {
    final difference = av.core[i].compareTo(bv.core[i]);
    if (difference != 0) return difference;
  }
  if (av.prerelease.isEmpty && bv.prerelease.isEmpty) return 0;
  if (av.prerelease.isEmpty) return 1;
  if (bv.prerelease.isEmpty) return -1;
  for (var i = 0; i < av.prerelease.length && i < bv.prerelease.length; i++) {
    final left = av.prerelease[i];
    final right = bv.prerelease[i];
    final ln = int.tryParse(left);
    final rn = int.tryParse(right);
    final difference = ln != null && rn != null
        ? ln.compareTo(rn)
        : ln != null
        ? -1
        : rn != null
        ? 1
        : left.compareTo(right);
    if (difference != 0) return difference;
  }
  return av.prerelease.length.compareTo(bv.prerelease.length);
}

class _ReleaseVersion {
  final List<int> core;
  final List<String> prerelease;
  const _ReleaseVersion(this.core, this.prerelease);

  static _ReleaseVersion? tryParse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final prerelease = match.group(4)?.split('.') ?? <String>[];
    if (prerelease.any(
      (part) =>
          RegExp(r'^\d+$').hasMatch(part) &&
          part.length > 1 &&
          part.startsWith('0'),
    )) {
      return null;
    }
    return _ReleaseVersion([
      for (var i = 1; i <= 3; i++) int.parse(match.group(i)!),
    ], prerelease);
  }
}
