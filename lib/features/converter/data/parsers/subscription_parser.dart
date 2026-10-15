import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import 'base_parser.dart';
import 'link_dispatcher.dart';
import '../../domain/entities/parsed_proxy.dart';
import '../../domain/validation/protocol_compatibility.dart';

final _log = Logger('SubscriptionParser');

enum SubscriptionFormat { v2ray, clash, singbox, unknown }

class SubscriptionParser {
  final LinkDispatcher _dispatcher;
  const SubscriptionParser({LinkDispatcher dispatcher = const LinkDispatcher()})
    : _dispatcher = dispatcher;

  /// Detect format and parse a subscription body into a list of proxies.
  List<ParsedProxy> parse(String body) {
    body = body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
    final fmt = detect(body);
    switch (fmt) {
      case SubscriptionFormat.v2ray:
        return _parseV2Ray(body);
      case SubscriptionFormat.clash:
        return _parseClash(body);
      case SubscriptionFormat.singbox:
        return _parseSingBox(body);
      case SubscriptionFormat.unknown:
        // Last resort: try line-by-line
        return _dispatcher.dispatchMultiple(body);
    }
  }

  SubscriptionFormat detect(String body) {
    final trimmed = body.trim();
    // sing-box JSON: starts with { and contains "outbounds"
    if (trimmed.startsWith('{') && trimmed.contains('"outbounds"')) {
      return SubscriptionFormat.singbox;
    }
    // Clash YAML: contains "proxies:" key
    if (trimmed.contains('proxies:') || trimmed.startsWith('mixed-port:')) {
      return SubscriptionFormat.clash;
    }
    // V2Ray base64: try to decode as base64 and check for proxy links
    if (_isLikelyBase64(trimmed)) {
      return SubscriptionFormat.v2ray;
    }
    return SubscriptionFormat.unknown;
  }

  List<ParsedProxy> _parseV2Ray(String body) {
    final trimmed = body.trim();
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(_addPadding(trimmed)));
    } catch (_) {
      try {
        decoded = utf8.decode(base64Url.decode(_addPadding(trimmed)));
      } catch (_) {
        throw const ParseException('V2Ray subscription: cannot decode base64');
      }
    }
    return _dispatcher.dispatchMultiple(decoded);
  }

  List<ParsedProxy> _parseClash(String body) {
    final results = <ParsedProxy>[];
    try {
      final doc = loadYaml(body);
      if (doc is! YamlMap) return results;
      final proxies = doc['proxies'];
      if (proxies is! YamlList) return results;
      for (final item in proxies) {
        if (item is! YamlMap) continue;
        final proxy = _clashProxyToLink(item);
        if (proxy != null) results.add(proxy);
      }
    } on UnsupportedConfigurationException {
      rethrow;
    } catch (e) {
      _log.warning('Malformed Clash YAML', e);
    }
    return results;
  }

  ParsedProxy? _clashProxyToLink(YamlMap m) {
    try {
      final type = (m['type'] as String?)?.toLowerCase() ?? '';
      final name = (m['name'] as String?) ?? '';
      final server = (m['server'] as String?) ?? '';
      final port = m['port'] is int
          ? m['port'] as int
          : int.tryParse(m['port'].toString()) ?? 0;

      switch (type) {
        case 'hysteria':
          throw const UnsupportedConfigurationException(
            'Hysteria 1 is unsupported by this app.',
          );
        case 'vmess':
          return VmessConfig(
            name: name,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            alterId: m['alterId'] is int ? m['alterId'] as int : 0,
            security: (m['cipher'] as String?) ?? 'auto',
            network: (m['network'] as String?) ?? 'tcp',
            path: (m['ws-opts']?['path'] as String?) ?? '/',
            wsHost: (m['ws-opts']?['headers']?['Host'] as String?) ?? '',
            tls: (m['tls'] == true) ? 'tls' : '',
            sni: (m['servername'] as String?) ?? '',
            alpn: ((m['alpn'] as YamlList?)?.toList().join(',')) ?? '',
            fingerprint: (m['fingerprint'] as String?) ?? '',
          );
        case 'vless':
          _rejectFields(m, const ['ech-opts', 'packet-encoding']);
          if (m['reality-opts'] is Map)
            _rejectFields(m['reality-opts'], const [
              'mldsa65-verify',
              'spider-x',
            ]);
          final network = (m['network'] as String?) ?? 'tcp';
          final opts = m['$network-opts'];
          if (opts is Map)
            _rejectFields(opts, const [
              'extra',
              'max-early-data',
              'early-data-header-name',
            ]);
          final config = VlessConfig(
            name: name,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            flow: (m['flow'] as String?) ?? '',
            encryption: (m['encryption'] as String?) ?? 'none',
            security: m['reality-opts'] != null
                ? 'reality'
                : ((m['tls'] == true) ? 'tls' : 'none'),
            sni: (m['servername'] as String?) ?? '',
            fingerprint:
                (m['client-fingerprint'] as String?) ??
                (m['fingerprint'] as String?) ??
                '',
            publicKey: (m['reality-opts']?['public-key'] as String?) ?? '',
            shortId: (m['reality-opts']?['short-id'] as String?) ?? '',
            spiderX: '',
            transport: network == 'websocket' ? 'ws' : network,
            path: _singleText(opts?['path'], 'path', fallback: '/'),
            transportHost: _singleText(
              opts?['host'] ?? opts?['headers']?['Host'],
              'host',
            ),
            grpcServiceName:
                (m['grpc-opts']?['grpc-service-name'] as String?) ?? '',
            xhttpMode: (m['xhttp-opts']?['mode'] as String?) ?? '',
            xPaddingBytes:
                (m['xhttp-opts']?['x-padding-bytes'] as String?) ?? '',
            alpn: _stringList(m['alpn']),
            allowInsecure: m['skip-cert-verify'] == true,
          );
          return _validated(config);
        case 'trojan':
          return TrojanConfig(
            name: name,
            host: server,
            port: port,
            password: (m['password'] as String?) ?? '',
            security: 'tls',
            sni: (m['sni'] as String?) ?? '',
            alpn: ((m['alpn'] as YamlList?)?.toList().join(',')) ?? '',
            fingerprint: (m['fingerprint'] as String?) ?? '',
            transport: (m['network'] as String?) ?? 'tcp',
            path: (m['ws-opts']?['path'] as String?) ?? '/',
            transportHost: '',
          );
        case 'ss':
        case 'shadowsocks':
          return ShadowsocksConfig(
            name: name,
            host: server,
            port: port,
            method: (m['cipher'] as String?) ?? 'aes-256-gcm',
            password: (m['password'] as String?) ?? '',
            plugin: (m['plugin'] as String?) ?? '',
            pluginOpts: (m['plugin-opts']?.toString()) ?? '',
          );
        case 'hysteria2':
        case 'hysteria 2':
          _rejectFields(m, const [
            'ech-opts',
            'realm',
            'hop-interval-max',
            'up',
            'down',
            'fingerprint',
          ]);
          final config = Hysteria2Config(
            name: name,
            host: server,
            port: port > 0
                ? port
                : _firstHoppingPort(_portsText(m['ports'] ?? m['mport'])),
            auth:
                (m['password'] as String?) ??
                (m['auth'] as String?) ??
                (m['auth-str'] as String?) ??
                '',
            sni: (m['sni'] as String?) ?? '',
            insecure: m['skip-cert-verify'] == true,
            obfs: (m['obfs'] as String?) ?? '',
            obfsPassword: (m['obfs-password'] as String?) ?? '',
            pinSha256:
                (m['pinSHA256'] as String?) ??
                (m['fingerprint-sha256'] as String?) ??
                '',
            ports: _portsText(m['ports'] ?? m['mport']),
            hopInterval: _interval(m['hop-interval']),
          );
          return _validated(config);
        case 'tuic':
          return TuicConfig(
            name: name,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            password: (m['password'] as String?) ?? '',
            sni: (m['sni'] as String?) ?? '',
            alpn: ((m['alpn'] as YamlList?)?.toList().join(',')) ?? '',
            congestionControl: (m['congestion-controller'] as String?) ?? 'bbr',
            udpRelayMode: (m['udp-relay-mode'] as String?) ?? 'native',
            allowInsecure: m['skip-cert-verify'] == true,
          );
        case 'wireguard':
          final peers = m['peers'] as YamlList?;
          final rawPeer = (peers != null && peers.isNotEmpty)
              ? peers.first
              : null;
          final peerMap = rawPeer is YamlMap ? rawPeer : null;
          final endpoint = (peerMap?['server'] as String?) ?? '';
          final epPort = peerMap?['port'] is int ? peerMap!['port'] as int : 0;
          return WireGuardConfig(
            name: name,
            host: endpoint.isNotEmpty ? endpoint : server,
            port: epPort > 0 ? epPort : port,
            privateKey: (m['private-key'] as String?) ?? '',
            publicKey: (peerMap?['public-key'] as String?) ?? '',
            presharedKey: (peerMap?['pre-shared-key'] as String?) ?? '',
            addresses: [(m['ip'] as String?) ?? '10.0.0.2/32'],
            dns: [(m['dns'] as String?) ?? '1.1.1.1'],
            mtu: m['mtu'] is int ? m['mtu'] as int : 1420,
          );
        default:
          return null;
      }
    } on UnsupportedConfigurationException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static ParsedProxy _validated(ParsedProxy proxy) {
    try {
      if (proxy is VlessConfig) proxy.validateCoreCompatibility();
      if (proxy is Hysteria2Config) proxy.validateCoreCompatibility();
    } on UnsupportedError catch (error) {
      throw UnsupportedConfigurationException(error.message.toString());
    }
    return proxy;
  }

  static void _rejectFields(Map fields, List<String> names) {
    for (final name in names) {
      final value = fields[name];
      if (value == null ||
          value == false ||
          value == '' ||
          value == 0 ||
          (value is List && value.isEmpty) ||
          (value is Map && value.isEmpty)) {
        continue;
      }
      throw UnsupportedConfigurationException(
        'Subscription field $name is unsupported by this app.',
      );
    }
  }

  static String _singleText(
    Object? value,
    String field, {
    String fallback = '',
  }) {
    if (value == null) return fallback;
    if (value is String) return value;
    if (value is List && value.length <= 1) {
      return value.isEmpty ? fallback : value.single.toString();
    }
    throw UnsupportedConfigurationException(
      'Subscription field $field requires a single value.',
    );
  }

  static List<String> _stringList(Object? value) => value == null
      ? const []
      : value is List
      ? value.map((v) => v.toString()).toList()
      : [value.toString()];

  static String? _portsText(Object? value) => value == null
      ? null
      : value is List
      ? value.join(',')
      : value.toString();

  static String _interval(Object? value) => value == null
      ? ''
      : value is num
      ? '${value}s'
      : value.toString();

  static int _firstHoppingPort(String? value) {
    try {
      final ranges = hysteria2ServerPorts(value);
      return ranges.isEmpty ? 443 : int.parse(ranges.first.split(':').first);
    } on UnsupportedError catch (error) {
      throw UnsupportedConfigurationException(error.message.toString());
    }
  }

  List<ParsedProxy> _parseSingBox(String body) {
    final results = <ParsedProxy>[];
    try {
      final doc = json.decode(body) as Map<String, dynamic>;
      final outbounds = doc['outbounds'] as List<dynamic>?;
      if (outbounds == null) return results;
      for (final item in outbounds) {
        if (item is! Map<String, dynamic>) continue;
        final proxy = _singboxOutboundToProxy(item);
        if (proxy != null) results.add(proxy);
      }
    } on UnsupportedConfigurationException {
      rethrow;
    } catch (e) {
      _log.warning('Malformed sing-box JSON', e);
    }
    return results;
  }

  ParsedProxy? _singboxOutboundToProxy(Map<String, dynamic> m) {
    try {
      final type = (m['type'] as String?) ?? '';
      final tag = (m['tag'] as String?) ?? '';
      final server = (m['server'] as String?) ?? '';
      final port = m['server_port'] is int
          ? m['server_port'] as int
          : type == 'hysteria2'
          ? _firstHoppingPort(_portsText(m['server_ports']))
          : 0;
      if (server.isEmpty || port == 0) return null;

      switch (type) {
        case 'hysteria':
          throw const UnsupportedConfigurationException(
            'Hysteria 1 is unsupported by this app.',
          );
        case 'vless':
          final tls = m['tls'] as Map<String, dynamic>?;
          final reality = tls?['reality'] as Map<String, dynamic>?;
          _rejectFields(reality ?? {}, const ['mldsa65_verify', 'spider_x']);
          _rejectFields(tls ?? {}, const [
            'ech',
            'certificate',
            'certificate_path',
            'certificate_public_key_sha256',
            'min_version',
            'max_version',
            'cipher_suites',
            'disable_sni',
            'client_certificate',
            'client_key',
            'client_certificate_path',
            'client_key_path',
          ]);
          final transport = m['transport'] as Map<String, dynamic>?;
          _rejectFields(transport ?? {}, const [
            'extra',
            'download',
            'xmux',
            'max_early_data',
            'early_data_header_name',
          ]);
          final config = VlessConfig(
            name: tag,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            flow: (m['flow'] as String?) ?? '',
            encryption: (m['encryption'] as String?) ?? 'none',
            security: reality != null
                ? 'reality'
                : ((tls?['enabled'] == true) ? 'tls' : 'none'),
            sni: (tls?['server_name'] as String?) ?? '',
            fingerprint: (tls?['utls']?['fingerprint'] as String?) ?? '',
            publicKey: (reality?['public_key'] as String?) ?? '',
            shortId: (reality?['short_id'] as String?) ?? '',
            spiderX: '',
            transport: (m['transport']?['type'] as String?) ?? 'tcp',
            path: (m['transport']?['path'] as String?) ?? '/',
            transportHost: _singleText(
              transport?['host'] ?? transport?['headers']?['Host'],
              'host',
            ),
            grpcServiceName: (m['transport']?['service_name'] as String?) ?? '',
            xhttpMode: (transport?['mode'] as String?) ?? '',
            xPaddingBytes: (transport?['x_padding_bytes'] as String?) ?? '',
            alpn: _stringList(tls?['alpn']),
            allowInsecure: tls?['insecure'] == true,
          );
          return _validated(config);
        case 'vmess':
          final tls = m['tls'] as Map<String, dynamic>?;
          return VmessConfig(
            name: tag,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            alterId: m['alter_id'] is int ? m['alter_id'] as int : 0,
            security: (m['security'] as String?) ?? 'auto',
            network: (m['transport']?['type'] as String?) ?? 'tcp',
            path: (m['transport']?['path'] as String?) ?? '/',
            wsHost: '',
            tls: (tls?['enabled'] == true) ? 'tls' : '',
            sni: (tls?['server_name'] as String?) ?? '',
            alpn: '',
            fingerprint: (tls?['utls']?['fingerprint'] as String?) ?? '',
          );
        case 'trojan':
          final tls = m['tls'] as Map<String, dynamic>?;
          return TrojanConfig(
            name: tag,
            host: server,
            port: port,
            password: (m['password'] as String?) ?? '',
            security: 'tls',
            sni: (tls?['server_name'] as String?) ?? '',
            alpn: '',
            fingerprint: (tls?['utls']?['fingerprint'] as String?) ?? '',
            transport: (m['transport']?['type'] as String?) ?? 'tcp',
            path: (m['transport']?['path'] as String?) ?? '/',
            transportHost: '',
          );
        case 'shadowsocks':
          return ShadowsocksConfig(
            name: tag,
            host: server,
            port: port,
            method: (m['method'] as String?) ?? 'aes-256-gcm',
            password: (m['password'] as String?) ?? '',
            plugin: (m['plugin'] as String?) ?? '',
            pluginOpts: (m['plugin_opts'] as String?) ?? '',
          );
        case 'hysteria2':
          final tls = m['tls'] as Map<String, dynamic>?;
          final obfs = m['obfs'] as Map<String, dynamic>?;
          _rejectFields(tls ?? {}, const [
            'ech',
            'certificate',
            'certificate_path',
            'certificate_public_key_sha256',
          ]);
          _rejectFields(m, const [
            'realm',
            'hop_interval_max',
            'up_mbps',
            'down_mbps',
          ]);
          final config = Hysteria2Config(
            name: tag,
            host: server,
            port: port,
            auth: (m['password'] as String?) ?? '',
            sni: (tls?['server_name'] as String?) ?? '',
            insecure: tls?['insecure'] == true,
            obfs: (obfs?['type'] as String?) ?? '',
            obfsPassword: (obfs?['password'] as String?) ?? '',
            pinSha256:
                (tls?['pinSHA256'] as String?) ??
                (tls?['pinned_peer_certificate_chain_sha256'] != null
                    ? 'unsupported'
                    : ''),
            ports: _portsText(m['server_ports']),
            hopInterval: (m['hop_interval'] as String?) ?? '',
          );
          return _validated(config);
        case 'tuic':
          final tls = m['tls'] as Map<String, dynamic>?;
          return TuicConfig(
            name: tag,
            host: server,
            port: port,
            uuid: (m['uuid'] as String?) ?? '',
            password: (m['password'] as String?) ?? '',
            sni: (tls?['server_name'] as String?) ?? '',
            alpn: '',
            congestionControl: (m['congestion_control'] as String?) ?? 'bbr',
            udpRelayMode: (m['udp_relay_mode'] as String?) ?? 'native',
            allowInsecure: tls?['insecure'] == true,
          );
        case 'wireguard':
          final peers = m['peers'] as List<dynamic>?;
          final peer = (peers?.isNotEmpty == true)
              ? peers!.first as Map<String, dynamic>?
              : null;
          return WireGuardConfig(
            name: tag,
            host: server,
            port: port,
            privateKey: (m['private_key'] as String?) ?? '',
            publicKey: (peer?['public_key'] as String?) ?? '',
            presharedKey: (peer?['pre_shared_key'] as String?) ?? '',
            addresses: ((m['address'] as List<dynamic>?) ?? [])
                .map((e) => e.toString())
                .toList(),
            dns: ((m['dns'] as List<dynamic>?) ?? [])
                .map((e) => e.toString())
                .toList(),
            mtu: m['mtu'] is int ? m['mtu'] as int : 1420,
            reserved: (m['reserved'] as List<dynamic>?)
                ?.map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0)
                .toList(),
          );
        default:
          return null;
      }
    } on UnsupportedConfigurationException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static bool _isLikelyBase64(String s) {
    if (s.length < 20) return false;
    if (s.contains("://")) return false;
    final base64Chars = RegExp(r'^[A-Za-z0-9+/_=\-\s]+$');
    return base64Chars.hasMatch(s);
  }

  static String _addPadding(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    final mod = clean.length % 4;
    if (mod == 0) return clean;
    return clean + '=' * (4 - mod);
  }
}
