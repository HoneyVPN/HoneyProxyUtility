import 'diagnostic_redactor.dart';

const _sources = {
  'ConnectionNotifier',
  'WindowsVpnDatasource',
  'VpnDatasource',
  'SubscriptionsNotifier',
  'SubscriptionParser',
};
const _stages = {
  'Cleanup failed after provider disposal',
  'Failed to restore VPN state on startup',
  'Connection failed',
  'Error during disconnect',
  'Could not resolve the active native VPN profile',
  'Failed to deserialize proxy config',
  'Failed to load subscriptions from storage',
  'Malformed Clash YAML',
  'Malformed sing-box JSON',
  'VPN stats stream error',
  'Windows VPN status probe unavailable; session retained',
  'Windows VPN cleanup was not confirmed during disposal',
  'FlutterError',
  'Unhandled',
};
const _safeCodes = {
  'busy',
  'recoveryRequired',
  'startFailed',
  'stopUnconfirmed',
  'connectionLost',
  'proxyAccountMismatch',
  'serviceNotInstalled',
  'serviceUnavailable',
  'serviceAccessDenied',
  'absent',
  'off',
  'download',
  'invalid',
  'tooLarge',
  'cache',
  'ports',
  'dnsAddress',
  'dnsPort',
  'dnsExtras',
  'dnsTlsPath',
};
const _files = {
  'connection_notifier',
  'windows_session',
  'windows_service_backend',
  'vpn_datasource_windows',
  'singbox_datasource',
  'apple_vpn_datasource',
  'provider_geo_runtime',
  'provider_geo_bundle',
  'provider_geo_decoder',
  'singbox_config_generator',
  'subscriptions_notifier',
  'subscription_parser',
  'link_dispatcher',
  'converter_screen',
  'servers_notifier',
  'settings_notifier',
  'log_screen',
  'bootstrap',
  'main',
  'app',
  'home_screen',
  'diagnostic_upload',
  'diagnostic_report',
  'diagnostic_journal',
  'diagnostic_send_sheet',
  'windows_core_diagnostics',
};

/// App parser errors can echo short credentials with no recognizable key name.
/// Persist their typed cause and technical words, never arbitrary error prose.
String diagnosticApplicationError(
  String stage, {
  String source = '',
  Object? error,
  StackTrace? stack,
}) {
  final label = _stages.contains(stage)
      ? stage
      : stage.startsWith('Failed to refresh subscription ')
      ? 'Failed to refresh subscription'
      : 'Application event';
  final scope = _sources.contains(source) ? '$source: ' : '';
  final parts = <String>['$scope$label'];
  if (error != null) {
    final type = error.runtimeType.toString();
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(type)) parts.add(type);
    final raw = error.toString();
    if (raw.length <= 8192) {
      final codes =
          RegExp(
                r'\b(windowsSession|providerGeo|settingsValidation):([a-zA-Z]+)\b',
              )
              .allMatches(raw)
              .where((m) => _safeCodes.contains(m[2]))
              .map((m) => m[0]!)
              .take(4);
      parts.addAll(codes);
      parts.add(DiagnosticRedactor.coreSummary(raw));
    } else {
      parts.add('oversized error details omitted');
    }
  }
  if (stack != null) {
    // Package/module and line number are enough to locate the cause. No
    // username/path, external package path, arguments or arbitrary frame prose.
    final text = stack.toString();
    if (text.length <= 16384) {
      final pattern = RegExp(
        r'^#(\d{1,3})\s+[^\r\n]{1,180}\(package:honeyproxyutility/(?:[a-zA-Z0-9_./-]{1,200}/)?([a-zA-Z0-9_]+)\.dart:(\d{1,7}):(\d{1,5})\)$',
        multiLine: true,
      );
      parts.addAll(
        pattern
            .allMatches(text)
            .where((m) => _files.contains(m[2]))
            .take(8)
            .map((m) => '#${m[1]} ${m[2]}:${m[3]}'),
      );
    }
  }
  return const DiagnosticRedactor().text(parts.join(' | '));
}
