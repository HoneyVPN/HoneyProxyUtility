import 'dart:convert';

import '../../features/converter/data/parsers/link_dispatcher.dart';

enum ImportLinkFailure { invalid, tooLong, unsupportedSource, unavailable }

/// Contains only a safe code; external URLs may contain subscription credentials.
class ImportLinkException implements Exception {
  const ImportLinkException(this.failure);
  final ImportLinkFailure failure;
  @override
  String toString() => 'importLink:${failure.name}';
}

class ImportLink {
  const ImportLink._(this.source);
  static const maxEnvelopeBytes = 65536;
  static const maxSourceBytes = 16384;
  static final _controls = RegExp(r'[\x00-\x1f\x7f]');
  static final _badEscape = RegExp(r'%(?![0-9a-fA-F]{2})');
  static final _httpAuthority = RegExp(r'^https?://([^/?#]*)');
  static final _badAuthority = RegExp(r'[\s\\]');
  final String source;

  String get location =>
      '/converter?initialText=${Uri.encodeComponent(source)}';

  static ImportLink parse(Object? event) {
    if (event is! String || event.isEmpty) {
      throw const ImportLinkException(ImportLinkFailure.invalid);
    }
    if (event.length > maxEnvelopeBytes ||
        utf8.encode(event).length > maxEnvelopeBytes) {
      throw const ImportLinkException(ImportLinkFailure.tooLong);
    }
    if (_controls.hasMatch(event) || _badEscape.hasMatch(event)) {
      throw const ImportLinkException(ImportLinkFailure.invalid);
    }
    try {
      final uri = Uri.parse(event);
      if (uri.scheme != 'honeyvpn' ||
          uri.host != 'import' ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasFragment) {
        throw const ImportLinkException(ImportLinkFailure.invalid);
      }
      final parameters = uri.queryParametersAll;
      final sources = parameters['url'];
      if (parameters.length != 1 || sources == null || sources.length != 1) {
        throw const ImportLinkException(ImportLinkFailure.invalid);
      }
      final source = sources.single;
      if (source.isEmpty ||
          _controls.hasMatch(source) ||
          _badEscape.hasMatch(source)) {
        throw const ImportLinkException(ImportLinkFailure.invalid);
      }
      if (source.length > maxSourceBytes ||
          utf8.encode(source).length > maxSourceBytes) {
        throw const ImportLinkException(ImportLinkFailure.tooLong);
      }
      if (source.startsWith('https://') || source.startsWith('http://')) {
        // Uri.parse normalizes some invalid authority syntax. Reject it before
        // parsing so another hostname or a default port cannot replace the input.
        final authority = _httpAuthority.firstMatch(source)?.group(1);
        if (authority == null ||
            authority.isEmpty ||
            _badAuthority.hasMatch(authority) ||
            authority.endsWith(':')) {
          throw const ImportLinkException(ImportLinkFailure.invalid);
        }
        final subscription = Uri.parse(source);
        if (!subscription.hasAuthority ||
            subscription.host.isEmpty ||
            _badAuthority.hasMatch(subscription.host) ||
            subscription.port < 1 ||
            subscription.port > 65535) {
          throw const ImportLinkException(ImportLinkFailure.invalid);
        }
      } else if (!source.contains('://') ||
          !const LinkDispatcher().canParse(source)) {
        throw const ImportLinkException(ImportLinkFailure.unsupportedSource);
      }
      return ImportLink._(source);
    } on FormatException {
      throw const ImportLinkException(ImportLinkFailure.invalid);
    }
  }
}

/// Keeps the newest activation until the router has rendered its first frame.
/// A duplicated native cold/warm delivery must not fetch the same subscription twice.
class ImportLinkInbox {
  ImportLinkInbox({Duration Function()? clock})
    : _clock = clock ?? (Stopwatch()..start()).elapsedGetter;

  final Duration Function() _clock;
  String? _lastSource;
  Duration? _lastReceived;
  Object? _pending;
  bool _closed = false;

  bool receive(Object? event) {
    if (_closed) return false;
    try {
      final link = ImportLink.parse(event);
      final now = _clock();
      if (_lastSource == link.source &&
          _pending is! ImportLinkFailure &&
          _lastReceived != null &&
          now - _lastReceived! < const Duration(seconds: 2)) {
        return false;
      }
      _lastSource = link.source;
      _lastReceived = now;
      _pending = link;
    } on ImportLinkException catch (error) {
      _pending = error.failure;
    }
    return true;
  }

  void fail(ImportLinkFailure failure) {
    if (!_closed) _pending = failure;
  }

  Object? take() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  void close() {
    _closed = true;
    _pending = null;
    _lastSource = null;
    _lastReceived = null;
  }
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
