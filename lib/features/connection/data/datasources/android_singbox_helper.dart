import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Runs sing-box as a subprocess on Android for protocols not supported by xray-core.
/// The binary is shipped as libsingbox.so in jniLibs and executed from nativeLibraryDir.
class AndroidSingboxHelper {
  static const _nativeChannel = MethodChannel('ru.honeyvpn.proxy/native');
  static const chainProxyPort = 18080;

  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  Future<String> _binaryPath() async {
    final dir = await _nativeChannel.invokeMethod<String>('getNativeLibDir');
    return '$dir/libsingbox.so';
  }

  Future<void> start(Map<String, dynamic> singboxConfig) async {
    await stop();
    final binaryPath = await _binaryPath();
    final tmp = await getTemporaryDirectory();
    final cfgFile = File('${tmp.path}/honeyvpn_chain.json');
    await cfgFile.writeAsString(jsonEncode(singboxConfig));

    _process = await Process.start(binaryPath, ['run', '-c', cfgFile.path]);
    _stdoutSub = _process!.stdout.transform(const SystemEncoding().decoder).listen((_) {});
    _stderrSub = _process!.stderr.transform(const SystemEncoding().decoder).listen((_) {});
  }

  Future<void> stop() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process?.kill();
    _process = null;
  }
}
