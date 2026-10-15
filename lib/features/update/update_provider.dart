import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/flavor.dart';
import 'release_selection.dart';

class UpdateInfo {
  final String currentVersion;
  final String remoteVersion;
  final String downloadUrl;

  const UpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
    required this.downloadUrl,
  });

  bool get hasUpdate =>
      (compareReleaseVersions(remoteVersion, currentVersion) ?? 0) > 0;
}

final updateProvider = FutureProvider<UpdateInfo?>((ref) async {
  // Apple preview has no downloadable VPN release yet. Its future Store
  // distribution must use Store updates, rather than Android/Windows assets.
  if (kIsWeb || (!Platform.isAndroid && !Platform.isWindows)) return null;
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
  final resp =
      await Dio(
        BaseOptions(connectTimeout: const Duration(seconds: 10)),
      ).get<String>(
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
  final remote = (data['tag_name'] as String? ?? '')
      .replaceFirst('v', '')
      .trim();
  if (remote.isEmpty) return null;

  final assets = (data['assets'] as List? ?? []).cast<Map<String, dynamic>>();
  String downloadUrl = '';

  if (!kIsWeb && Platform.isAndroid) {
    final device = await DeviceInfoPlugin().androidInfo;
    downloadUrl = selectAndroidReleaseUrl(assets, device.supportedAbis);
    if (downloadUrl.isEmpty) return null;
  } else if (!kIsWeb && Platform.isWindows) {
    downloadUrl = selectWindowsReleaseUrl(assets);
    if (downloadUrl.isEmpty) return null;
  }

  return UpdateInfo(
    currentVersion: current,
    remoteVersion: remote,
    downloadUrl: downloadUrl,
  );
}

/// play flavor: checks honeyvpn.ru (Play Store manages the actual update)
Future<UpdateInfo?> _checkHoneyvpn(String current) async {
  final resp =
      await Dio(
        BaseOptions(connectTimeout: const Duration(seconds: 10)),
      ).get<String>(
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
