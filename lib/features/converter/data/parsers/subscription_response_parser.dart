import 'package:flutter/foundation.dart';

import '../../domain/entities/parsed_proxy.dart';
import '../../../subscriptions/domain/entities/provider_routing_metadata.dart';
import 'base_parser.dart';
import 'provider_routing_parser.dart';
import 'subscription_parser.dart';

/// The result contains plain Dart data only, so native platforms can transfer
/// it from the worker isolate without moving HTTP clients or notifier state.
class ParsedSubscriptionResponse {
  const ParsedSubscriptionResponse({
    required this.envelope,
    required this.proxies,
    required this.routingParseFailed,
    required this.routingDeclared,
  });

  final ProviderRoutingEnvelope? envelope;
  final List<ParsedProxy> proxies;
  final bool routingParseFailed;
  final bool routingDeclared;
}

class SubscriptionResponseParser {
  const SubscriptionResponseParser();

  /// YAML/JSON/base64 decoding and per-profile validation must not occupy the
  /// rendering isolate while the refresh indicator is animating. Flutter's
  /// compute uses an isolate on native and its supported fallback on the web.
  Future<ParsedSubscriptionResponse> parse({
    required int subscriptionId,
    required String body,
    Map<String, List<String>> headers = const {},
    bool includeProxies = true,
  }) => compute(_parseSubscriptionResponse, (
    subscriptionId: subscriptionId,
    body: body,
    headers: headers,
    includeProxies: includeProxies,
  ), debugLabel: 'parse-subscription');
}

typedef _SubscriptionResponseInput = ({
  int subscriptionId,
  String body,
  Map<String, List<String>> headers,
  bool includeProxies,
});

ParsedSubscriptionResponse _parseSubscriptionResponse(
  _SubscriptionResponseInput input,
) {
  ProviderRoutingEnvelope? envelope;
  var routingParseFailed = false;
  var routingDeclared = false;
  try {
    envelope = const ProviderRoutingParser().parse(
      subscriptionId: input.subscriptionId,
      body: input.body,
      headers: input.headers,
    );
  } on ProviderRoutingParseException catch (error) {
    routingParseFailed = true;
    routingDeclared =
        error.declarationPresent ||
        input.headers.keys.any((name) => name.toLowerCase() == 'routing') ||
        input.body
            .substring(
              0,
              input.body.length.clamp(
                0,
                ProviderRoutingParser.maximumBodyBytes,
              ),
            )
            .contains('happ://routing/');
  }
  final proxies = input.includeProxies
      ? const SubscriptionParser().parse(envelope?.proxyBody ?? input.body)
      : const <ParsedProxy>[];
  if (input.includeProxies && proxies.isEmpty) {
    throw const ParseException('Subscription has no valid profiles');
  }
  return ParsedSubscriptionResponse(
    envelope: envelope,
    proxies: proxies,
    routingParseFailed: routingParseFailed,
    routingDeclared: routingDeclared,
  );
}
