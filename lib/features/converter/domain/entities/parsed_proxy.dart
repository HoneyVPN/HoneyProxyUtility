/// Sealed class hierarchy for all parsed proxy configurations.
/// Use exhaustive switch to handle each protocol.
sealed class ParsedProxy {
  const ParsedProxy();
  String get name;
  String get host;
  int get port;

  String get displayName => name.isNotEmpty ? name : '$host:$port';
  String get protocolLabel;
}

final class VmessConfig extends ParsedProxy {
  const VmessConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.uuid,
    required this.alterId,
    required this.security,
    required this.network,
    required this.path,
    required this.wsHost,
    required this.tls,
    required this.sni,
    required this.alpn,
    required this.fingerprint,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String uuid;
  final int alterId;
  final String security;       // auto | aes-128-gcm | chacha20-poly1305 | none
  final String network;        // tcp | ws | h2 | grpc | httpupgrade
  final String path;
  final String wsHost;
  final String tls;            // '' | 'tls'
  final String sni;
  final String alpn;
  final String fingerprint;

  @override String get protocolLabel => 'VMess';
}

final class VlessConfig extends ParsedProxy {
  const VlessConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.uuid,
    required this.flow,
    required this.encryption,
    required this.security,
    required this.sni,
    required this.fingerprint,
    required this.publicKey,
    required this.shortId,
    required this.spiderX,
    required this.transport,
    required this.path,
    required this.transportHost,
    required this.grpcServiceName,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String uuid;
  final String flow;             // xtls-rprx-vision | ''
  final String encryption;       // none
  final String security;         // none | tls | reality
  final String sni;
  final String fingerprint;
  final String publicKey;        // Reality pbk
  final String shortId;          // Reality sid
  final String spiderX;          // Reality spx
  final String transport;        // tcp | ws | h2 | grpc | httpupgrade
  final String path;
  final String transportHost;
  final String grpcServiceName;

  @override String get protocolLabel => 'VLESS';
}

final class TrojanConfig extends ParsedProxy {
  const TrojanConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.password,
    required this.security,
    required this.sni,
    required this.alpn,
    required this.fingerprint,
    required this.transport,
    required this.path,
    required this.transportHost,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String password;
  final String security;       // tls | xtls
  final String sni;
  final String alpn;
  final String fingerprint;
  final String transport;      // tcp | ws | h2 | grpc
  final String path;
  final String transportHost;

  @override String get protocolLabel => 'Trojan';
}

final class ShadowsocksConfig extends ParsedProxy {
  const ShadowsocksConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.method,
    required this.password,
    required this.plugin,
    required this.pluginOpts,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String method;        // aes-128-gcm | aes-256-gcm | chacha20-ietf-poly1305 | 2022-blake3-*
  final String password;
  final String plugin;        // '' | obfs-local | v2ray-plugin
  final String pluginOpts;

  @override String get protocolLabel => 'SS';
}

final class Hysteria2Config extends ParsedProxy {
  const Hysteria2Config({
    required this.name,
    required this.host,
    required this.port,
    required this.auth,
    required this.sni,
    required this.insecure,
    required this.obfs,
    required this.obfsPassword,
    required this.pinSha256,
    this.ports,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String auth;
  final String sni;
  final bool insecure;
  final String obfs;            // '' | salamander
  final String obfsPassword;
  final String pinSha256;
  final String? ports;          // port hopping e.g. "5000-6000"

  @override String get protocolLabel => 'Hy2';
}

final class TuicConfig extends ParsedProxy {
  const TuicConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.uuid,
    required this.password,
    required this.sni,
    required this.alpn,
    required this.congestionControl,
    required this.udpRelayMode,
    required this.allowInsecure,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String uuid;
  final String password;
  final String sni;
  final String alpn;
  final String congestionControl;  // bbr | cubic | new_reno
  final String udpRelayMode;       // native | quic
  final bool allowInsecure;

  @override String get protocolLabel => 'TUIC';
}

final class WireGuardConfig extends ParsedProxy {
  const WireGuardConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.privateKey,
    required this.publicKey,
    required this.presharedKey,
    required this.addresses,
    required this.dns,
    required this.mtu,
    this.reserved,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String privateKey;
  final String publicKey;
  final String presharedKey;
  final List<String> addresses;
  final List<String> dns;
  final int mtu;
  final List<int>? reserved;

  @override String get protocolLabel => 'WG';
}

final class NaiveConfig extends ParsedProxy {
  const NaiveConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.scheme,  // https | quic
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String username;
  final String password;
  final String scheme;

  @override String get protocolLabel => 'NaïveProxy';
}

final class ShadowTlsConfig extends ParsedProxy {
  const ShadowTlsConfig({
    required this.name,
    required this.host,
    required this.port,
    required this.password,
    required this.sni,
    required this.version,
    required this.innerProxy,
  });

  @override final String name;
  @override final String host;
  @override final int port;
  final String password;
  final String sni;
  final int version;  // 1 | 2 | 3
  final ParsedProxy innerProxy;

  @override String get protocolLabel => 'ShadowTLS';
}
