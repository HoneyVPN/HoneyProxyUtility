import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class NaiveParser extends BaseProxyParser<NaiveConfig> {
  const NaiveParser();

  @override
  String get scheme => 'naive+https://';

  @override
  bool canParse(String rawLink) =>
      rawLink.startsWith('naive+https://') ||
      rawLink.startsWith('naive+quic://') ||
      rawLink.startsWith('naive://');

  @override
  NaiveConfig parse(String rawLink) {
    late String scheme;
    late String normalized;
    if (rawLink.startsWith('naive+https://')) {
      scheme = 'https';
      normalized = rawLink.replaceFirst('naive+https://', 'https://');
    } else if (rawLink.startsWith('naive+quic://')) {
      scheme = 'quic';
      normalized = rawLink.replaceFirst('naive+quic://', 'https://');
    } else {
      scheme = 'https';
      normalized = rawLink.replaceFirst('naive://', 'https://');
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) throw const ParseException('Malformed NaïveProxy URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('NaïveProxy: missing host');

    final userInfo = uri.userInfo;
    final colonIdx = userInfo.indexOf(':');
    final username = colonIdx >= 0 ? userInfo.substring(0, colonIdx) : userInfo;
    final password = colonIdx >= 0 ? userInfo.substring(colonIdx + 1) : '';

    return NaiveConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      username: username,
      password: password,
      scheme: scheme,
    );
  }
}
