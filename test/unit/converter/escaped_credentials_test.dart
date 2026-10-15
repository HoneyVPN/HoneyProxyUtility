import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/naive_parser.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/tuic_parser.dart';

void main() {
  test('Naive credentials are URI decoded once', () {
    final proxy = const NaiveParser().parse(
      'naive+https://user%40mail:p%3Aa%26ss%2520@vpn.example.com:443',
    );
    expect(proxy.username, 'user@mail');
    expect(proxy.password, 'p:a&ss%20');
  });
  test('TUIC passwords retain escaped separators correctly', () {
    final proxy = const TuicParser().parse(
      'tuic://uuid:p%3Aa%40ss%26word@vpn.example.com:443',
    );
    expect(proxy.password, 'p:a@ss&word');
  });
}
