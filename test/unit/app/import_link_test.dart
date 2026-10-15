import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/import_links/import_link.dart';

String _link(String source) =>
    'honeyvpn://import?url=${Uri.encodeComponent(source)}';

void main() {
  test('one optional slash preserves the complete decoded import source', () {
    for (final source in [
      'https://sub.example.test:8443/token%252Fpath?one=a%2Bb&two=x+y#name',
      'vless://synthetic-id@example.test:443?type=ws&path=%2Fsocket%252Fencoded',
    ]) {
      final raw = _link(source).replaceFirst('import?', 'import/?');
      expect(ImportLink.parse(raw).source, source);
    }
    expect(
      ImportLink.parse(
        'honeyvpn://import/?url=https://example.invalid/shell-protocol-test',
      ).source,
      'https://example.invalid/shell-protocol-test',
    );
  });

  test('optional slash does not permit extra or encoded paths', () {
    for (final path in ['//', '/foo', '/%2F', '%2F']) {
      expect(
        () => ImportLink.parse(
          'honeyvpn://import$path?url=https%3A%2F%2Fexample.invalid%2Ftest',
        ),
        throwsA(isA<ImportLinkException>()),
      );
    }
  });

  test(
    'subscription credentials and nested URL parameters are decoded once',
    () {
      const source =
          'https://sub.example.test/private-token?one=a%2Bb&two=x+y#name';
      final link = ImportLink.parse(_link(source));
      expect(link.source, source);
      expect(Uri.parse(link.location).queryParameters['initialText'], source);
    },
  );

  test(
    'existing Android server imports and subscription URLs remain supported',
    () {
      for (final source in [
        'http://sub.example.test:8080/config',
        'https://sub.example.test/config',
        'https://user:synthetic%2Bpassword@sub.example.test:8443/config%252Fpath?one=a+b#Name',
        'vless://synthetic-id@example.test:443?security=tls#Name',
        'vless://synthetic-id@example.test:443?type=ws&path=%2Fsocket%2Fencoded#Name',
        'vmess://eyJhZGQiOiJleGFtcGxlLnRlc3QifQ==',
        'vpn://synthetic-encoded-profile',
        'awg://example.test:51820?config=synthetic',
      ]) {
        expect(ImportLink.parse(_link(source)).source, source);
      }
    },
  );

  test(
    'malformed sources cannot normalize into a different authority or default port',
    () {
      for (final source in [
        'vless://synthetic-id@example.test:443?type=ws&path=%wrong',
        'https://sub.example.test:/config',
        'https://bad host/config',
        r'https://sub.example.test\@other.example/config',
      ]) {
        expect(
          () => ImportLink.parse(_link(source)),
          throwsA(
            isA<ImportLinkException>().having(
              (error) => error.failure,
              'safe failure',
              ImportLinkFailure.invalid,
            ),
          ),
        );
      }
    },
  );

  test('malformed envelopes fail with safe codes instead of source URLs', () {
    const secret = 'private-credential-marker';
    for (final raw in [
      'honeyvpn://connect?url=https%3A%2F%2F$secret.example',
      'honeyvpn://import/path?url=https%3A%2F%2F$secret.example',
      'honeyvpn://user@import?url=https%3A%2F%2F$secret.example',
      'honeyvpn://import:123?url=https%3A%2F%2F$secret.example',
      'honeyvpn://import?url=https%3A%2F%2F$secret.example#fragment',
      'honeyvpn://import?url=https%3A%2F%2F$secret.example&url=https%3A%2F%2Fother.example',
      'honeyvpn://import?url=https%3A%2F%2F$secret.example&connect=true',
      'honeyvpn://import?url=',
      'honeyvpn://import?url=%FF',
      'honeyvpn://import?url=%zz',
      _link('https://$secret.example:65536/config'),
      _link('https://$secret.example/config\nsecond'),
      _link('https://$secret.example/%wrong'),
    ]) {
      expect(
        () => ImportLink.parse(raw),
        throwsA(
          isA<ImportLinkException>().having(
            (error) => error.toString(),
            'safe diagnostic',
            isNot(contains(secret)),
          ),
        ),
      );
    }
  });

  test(
    'activation cannot open files, nested commands or arbitrary schemes',
    () {
      for (final source in [
        'file:///private/synthetic',
        'javascript:synthetic',
        'intent://synthetic',
        'honeyvpn://connect',
        'unknown://synthetic',
        '[Interface]\nPrivateKey=synthetic',
      ]) {
        expect(
          () => ImportLink.parse(_link(source)),
          throwsA(isA<ImportLinkException>()),
        );
      }
    },
  );

  test(
    'input bounds count UTF8 bytes and reject oversized decoded sources',
    () {
      final source =
          'https://sub.example.test/${'a' * ImportLink.maxSourceBytes}';
      expect(
        () => ImportLink.parse(_link(source)),
        throwsA(
          isA<ImportLinkException>().having(
            (error) => error.failure,
            'failure',
            ImportLinkFailure.tooLong,
          ),
        ),
      );
      expect(
        () => ImportLink.parse('honeyvpn://import?url=${'é' * 40000}'),
        throwsA(
          isA<ImportLinkException>().having(
            (error) => error.failure,
            'failure',
            ImportLinkFailure.tooLong,
          ),
        ),
      );
    },
  );

  test(
    'startup queue retains the newest link and suppresses recent native duplicates',
    () {
      var now = Duration.zero;
      final inbox = ImportLinkInbox(clock: () => now);
      final first = _link('https://sub.example.test/first');
      final second = _link('https://sub.example.test/second');
      expect(inbox.receive(first), isTrue);
      expect(inbox.receive(second), isTrue);
      expect(inbox.receive(second), isFalse);
      expect(inbox.receive('honeyvpn://import?url='), isTrue);
      expect(inbox.receive(second), isTrue);
      expect(
        (inbox.take() as ImportLink).source,
        'https://sub.example.test/second',
      );
      expect(inbox.take(), isNull);
      now = const Duration(seconds: 3);
      expect(inbox.receive(second), isTrue);
      inbox.close();
      expect(inbox.take(), isNull);
      expect(inbox.receive(first), isFalse);
    },
  );
}
