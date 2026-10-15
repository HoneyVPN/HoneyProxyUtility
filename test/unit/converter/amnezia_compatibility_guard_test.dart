import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/base_parser.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';

const _dispatcher = LinkDispatcher();
const _secret = 'synthetic-sensitive-value';

String _uri(Map<String, String> parameters) => Uri(
  scheme: 'awg',
  host: 'node.example.test',
  port: 51820,
  queryParameters: {
    'privateKey': 'synthetic-private-key',
    'publicKey': 'synthetic-public-key',
    ...parameters,
  },
).toString();

String _jsonUri(Map<String, dynamic> parameters) => _uri({
  'config': jsonEncode({
    'privateKey': 'synthetic-private-key',
    'publicKey': 'synthetic-public-key',
    'presharedKey': 'synthetic-preshared-key',
    'addresses': ['10.20.0.2/32'],
    'reserved': [7, 8, 9],
    ...parameters,
  }),
});

String _ini(String extra, {bool scalarAwg = true}) =>
    '''
[Interface]
PrivateKey = synthetic-private-key
Address = 10.20.0.2/32
${scalarAwg ? 'Jc = 7\nH1 = 123' : ''}
$extra
[Peer]
PublicKey = synthetic-public-key
Endpoint = node.example.test:51820
''';

void _expectRejected(String link, String field) {
  expect(
    () => _dispatcher.dispatch(link),
    throwsA(
      isA<ParseException>().having(
        (error) {
          expect(error.message, contains(field));
          expect(error.message, contains('unsupported'));
          expect(error.message, isNot(contains(_secret)));
          expect(error.message, isNot(contains('synthetic-private-key')));
          expect(error.message, isNot(contains(link)));
          return error.message;
        },
        'safe field-specific message',
        isNotEmpty,
      ),
    ),
  );
}

void main() {
  test('scalar URI headers and harmless metadata keep existing behavior', () {
    final parsed =
        _dispatcher.dispatch(
              _uri({
                'H1': '123',
                'S3': '12',
                'version': '3.1',
                'provider_note': _secret,
              }),
            )
            as AmneziaWGConfig;
    expect(parsed.h1, 123);
    expect(parsed.s3, 12);
    expect(parsed.privateKey, 'synthetic-private-key');
  });

  test('JSON scalar/WARP identity survives empty advanced defaults', () {
    final parsed =
        _dispatcher.dispatch(
              _jsonUri({
                'h1': 123,
                'h2': '234',
                'jc': 7,
                'header_protection_key': '',
                'i1': '',
                'j1': '',
                'itime': 0,
                'provider_metadata': {'header_protection_key': _secret},
              }),
            )
            as AmneziaWGConfig;
    expect(parsed.h1, 123);
    expect(parsed.h2, 234);
    expect(parsed.jc, 7);
    expect(parsed.privateKey, 'synthetic-private-key');
    expect(parsed.presharedKey, 'synthetic-preshared-key');
    expect(parsed.reserved, [7, 8, 9]);
    expect(parsed.addresses, ['10.20.0.2/32']);
  });

  test('empty new optional fields do not reclassify a basic WG block', () {
    expect(
      _dispatcher.dispatch(
        _ini('header_protection_key = \nItime = 0', scalarAwg: false),
      ),
      isA<WireGuardConfig>(),
    );
  });

  const securityFields = [
    'header_protection_key',
    'content_padding_addition',
    'rekey_after_time',
    'rekey_timeout',
    'reject_after_time',
    'keepalive_timeout',
    'max_handshake_attempts',
  ];
  test('URI AWG 3.1 security fields cannot be silently discarded', () {
    for (final field in securityFields) {
      _expectRejected(_uri({field: _secret}), field);
    }
    _expectRejected(
      _uri({'HeaderProtectionKey': _secret}),
      'header_protection_key',
    );
  });

  test('JSON unsupported fields escape the legacy catch-and-fallback path', () {
    for (final field in securityFields) {
      _expectRejected(_jsonUri({field: _secret}), field);
      _expectRejected(
        _jsonUri({
          'amnezia': {field: _secret},
        }),
        field,
      );
    }
  });

  test('new-only INI fields cannot fall through to the plain WG parser', () {
    for (final field in securityFields) {
      _expectRejected(_ini('$field = $_secret', scalarAwg: false), field);
    }
    expect(
      () => _dispatcher.dispatchMultiple(
        _ini('header_protection_key = $_secret'),
      ),
      throwsA(isA<ParseException>()),
    );
  });

  test(
    'non-singleton header ranges and arrays are rejected across URI JSON and INI',
    () {
      for (final field in ['H1', 'H2', 'H3', 'H4']) {
        _expectRejected(_uri({field: '100-200'}), field);
        _expectRejected(_jsonUri({field.toLowerCase(): '100-200'}), field);
        _expectRejected(
          _jsonUri({
            field.toLowerCase(): [100, 200],
          }),
          field,
        );
        _expectRejected(_ini('$field = 100-200'), field);
      }
    },
  );

  test(
    'singleton header ranges preserve their exact wire value in all supported representations',
    () {
      final uri =
          _dispatcher.dispatch(_uri({'H1': '456-456'})) as AmneziaWGConfig;
      final json =
          _dispatcher.dispatch(_jsonUri({'h1': '456-456'})) as AmneziaWGConfig;
      final ini = _dispatcher.dispatch(_ini('H1 = 456-456')) as AmneziaWGConfig;
      expect(uri.h1, 456);
      expect(json.h1, 456);
      expect(ini.h1, 456);
    },
  );

  test(
    'disabled optional AWG features do not block exported scalar or standard WireGuard profiles',
    () {
      for (final field in [
        ...securityFields,
        'I1',
        'J1',
        'Itime',
        'RandomTrailers',
        'DisableCookies',
      ]) {
        for (final disabled in ['0', 'off', 'false', '0-0']) {
          expect(
            _dispatcher.dispatch(_uri({field: disabled})),
            isA<AmneziaWGConfig>(),
          );
          expect(
            _dispatcher.dispatch(_ini('$field = $disabled', scalarAwg: false)),
            isA<WireGuardConfig>(),
          );
        }
        expect(
          _dispatcher.dispatch(_jsonUri({field: false})),
          isA<AmneziaWGConfig>(),
        );
      }
    },
  );

  test(
    'active packet/timing parameters unsupported by the DTO are rejected',
    () {
      for (final field in [
        'I1',
        'I2',
        'I3',
        'I4',
        'I5',
        'J1',
        'J2',
        'J3',
        'Itime',
      ]) {
        _expectRejected(_uri({field: _secret}), field);
      }
    },
  );

  test('compressed Amnezia share links apply the same compatibility guard', () {
    final payload = utf8.encode(
      jsonEncode({
        'containers': [
          {
            'container': 'amnezia-awg',
            'awg': {
              'last_config': jsonEncode({
                'config': _ini('header_protection_key = $_secret'),
              }),
            },
          },
        ],
        'description': 'Synthetic',
      }),
    );
    final size = ByteData(4)..setUint32(0, payload.length);
    final link =
        'vpn://${base64UrlEncode([...size.buffer.asUint8List(), ...ZLibEncoder().convert(payload)])}';
    _expectRejected(link, 'header_protection_key');
  });
}
