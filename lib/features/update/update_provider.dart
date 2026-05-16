import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

    final downloadUrl = !kIsWeb && !Platform.isAndroid
        ? (data['download_windows'] as String? ?? '')
        : (data['download_android'] as String? ?? '');

    return UpdateInfo(
      currentVersion: current,
      remoteVersion: remote,
      downloadUrl: downloadUrl,
    );
  } catch (_) {
    return null;
  }
});
