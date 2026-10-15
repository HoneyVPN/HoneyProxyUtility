import 'dart:math';

import '../../../converter/domain/entities/parsed_proxy.dart';
import 'proxy_identity.dart';

const builtInSubscriptionUrl = 'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH';
final _builtInUri = Uri.parse(builtInSubscriptionUrl);
final _authorityWithUserInfo = RegExp(r'^[^:/?#]+://[^/?#]*@');

String normalizeSubscriptionUrl(String url) {
  final cleaned = url.replaceAll('\x00', '').trim();
  final uri = Uri.tryParse(cleaned);
  // Canonicalize only transport-equivalent spellings of the built-in HTTPS
  // feed. Fragment/default port/host casing must not bypass its one-node limit.
  // Preserve other provider URLs, including meaningful query strings/paths.
  if (uri != null &&
      uri.scheme == 'https' &&
      uri.host == _builtInUri.host &&
      uri.port == 443 &&
      uri.path == _builtInUri.path &&
      uri.query.isEmpty &&
      uri.userInfo.isEmpty &&
      !_authorityWithUserInfo.hasMatch(cleaned)) {
    return builtInSubscriptionUrl;
  }
  return cleaned;
}

/// Only the built-in free feed is limited. Custom/paid subscriptions retain all
/// distinct connections, including different accounts on the same endpoint.
List<ParsedProxy> subscriptionProxies(
  String url,
  List<ParsedProxy> proxies, {
  Random? random,
}) {
  final unique = <String, ParsedProxy>{};
  for (final proxy in proxies) {
    unique.putIfAbsent(proxyIdentity(proxy), () => proxy);
  }
  final all = unique.values.toList();
  if (normalizeSubscriptionUrl(url) != builtInSubscriptionUrl || all.isEmpty) {
    return all;
  }
  // Every distinct parsed node is eligible, including the current one. The
  // caller validates the feed normally; protocol and selection do not bias it.
  return [all[(random ?? Random()).nextInt(all.length)]];
}
