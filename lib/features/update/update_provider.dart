import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/flavor.dart';

class UpdateInfo {
  final String currentVersion;
  final String remoteVersion;
  final String downloadUrl;

  const UpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
    required this.downloadUrl,
  });

  bool get hasUpdate => _compare(remoteVersion, currentVersion) > 0;

  static int _compare(String a, String b) {
    final av = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bv = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final ai = i < av.length ? av[i] : 0;
      final bi = i < bv.length ? bv[i] : 0;
      if (ai != bi) return ai - bi;
    }
    return 0;
  }
}

final updateProvider = FutureProvider<UpdateInfo?>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    final current = info.version;
    return isPlayFlavor
        ? await _checkHoneyvpn(current)
        : await _checkGithub(current);
  } catch (_) {
    return null;
  }
});

/// direct flavor: checks GitHub Releases of the public repo
Future<UpdateInfo?> _checkGithub(String current) async {
  final resp = await Dio().get<String>(
    'https://api.github.com/repos/HoneyVPN/HoneyProxyUtility/releases/latest',
    options: Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 5),
      headers: {'Accept': 'application/vnd.github+json'},
    ),
  );

  final data = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
  // tag_name is e.g. "v1.0.82" → strip leading 'v'
  final remote = (data['tag_name'] as String? ?? '').replaceFirst('v', '').trim();
  if (remote.isEmpty) return null;

  final assets = (data['assets'] as List? ?? []).cast<Map<String, dynamic>>();
  String downloadUrl = '';

  if (!kIsWeb && Platform.isAndroid) {
    // Prefer arm64-v8a; fall back to any APK
    final asset = assets.firstWhere(
      (a) => (a['name'] as String? ?? '').contains('arm64'),
      orElse: () => assets.firstWhere(
        (a) => (a['name'] as String? ?? '').endsWith('.apk'),
        orElse: () => <String, dynamic>{},
      ),
    );
    downloadUrl = asset['browser_download_url'] as String? ?? '';
  } else if (!kIsWeb && Platform.isWindows) {
    final asset = assets.firstWhere(
      (a) => (a['name'] as String? ?? '').endsWith('.exe'),
      orElse: () => <String, dynamic>{},
    );
    downloadUrl = asset['browser_download_url'] as String? ?? '';
  }

  return UpdateInfo(
    currentVersion: current,
    remoteVersion: remote,
    downloadUrl: downloadUrl,
  );
}

/// play flavor: checks honeyvpn.ru (Play Store manages the actual update)
Future<UpdateInfo?> _checkHoneyvpn(String current) async {
  final resp = await Dio().get<String>(
    'https://api.honeyvpn.ru/app/api/version',
    options: Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 5),
    ),
  );

  final data = jsonDecode(resp.data ?? '{}') as Map<String, dynamic>;
  final remote = (data['version'] as String? ?? '').trim();
  if (remote.isEmpty) return null;

  // downloadUrl is empty — play flavor opens market:// in _install()
  return UpdateInfo(
    currentVersion: current,
    remoteVersion: remote,
    downloadUrl: '',
  );
}
