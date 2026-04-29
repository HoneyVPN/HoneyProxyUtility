import '../../domain/entities/parsed_proxy.dart';

class ParseException implements Exception {
  final String message;
  const ParseException(this.message);
  @override
  String toString() => 'ParseException: $message';
}

class UnsupportedProtocolException implements Exception {
  const UnsupportedProtocolException();
  @override
  String toString() => 'Unsupported protocol or malformed link';
}

abstract class BaseProxyParser<T extends ParsedProxy> {
  const BaseProxyParser();

  bool canParse(String rawLink);
  T parse(String rawLink);
  String get scheme;

  /// Safely decode URI component, returning original string on failure.
  static String decodeUri(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }
}
