import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_journal.dart';
import 'package:honeyproxyutility/features/diagnostics/data/windows_core_diagnostics.dart';

List<int> line(String payload, [String type = 'error']) =>
    utf8.encode('${jsonEncode({'type': type, 'payload': payload})}\n');
void main() {
  test(
    'bounded JSON core lines preserve technical error and hide raw credentials',
    () {
      final journal = DiagnosticJournal(persist: false);
      final parser = CoreDiagnosticLineParser(journal: journal);
      final bytes = line(
        'tls handshake failed vless://tiny@private.example:443 secret',
      );
      parser.add(bytes.take(5).toList());
      parser.add(bytes.skip(5).toList());
      expect(journal.events.single.message, 'tls handshake failed');
      expect(journal.events.single.level, 'error');
      expect(
        jsonEncode(journal.events.map((e) => e.toJson()).toList()),
        isNot(contains('private.example')),
      );
      parser.add(utf8.encode('x' * 100000 + '\n'));
      parser.add(line('connection timeout'));
      expect(
        journal.events.any(
          (e) => e.message == 'core output exceeded line limit',
        ),
        true,
      );
      expect(journal.events.last.message, 'connection timeout');
    },
  );
  test('bad UTF8/config/unknown schema discarded without raw publication', () {
    final journal = DiagnosticJournal(persist: false);
    final parser = CoreDiagnosticLineParser(journal: journal);
    parser.add([255, 10]);
    parser.add(utf8.encode('{"config":"tiny"}\n'));
    parser.add(utf8.encode('{"type":"private","payload":"secret"}\n'));
    expect(journal.events, isEmpty);
  });
  test(
    'rotated session rejects late old stream and never changes VPN state',
    () async {
      final journal = DiagnosticJournal(persist: false);
      final old = Completer<Stream<List<int>>>();
      final newest = StreamController<List<int>>();
      var allowed = true;
      final nonces = <String>[];
      final capture = WindowsCoreDiagnostics(
        journal: journal,
        stream: (nonce) {
          nonces.add(nonce);
          return nonce == 'old' ? old.future : Future.value(newest.stream);
        },
      );
      final pending = capture.attach('old', isCurrent: () => allowed);
      await capture.stop();
      await capture.attach('new', isCurrent: () => allowed);
      old.complete(Stream.value(line('fatal old')));
      await pending;
      newest.add(line('handshake failed secret'));
      await Future<void>.delayed(Duration.zero);
      expect(journal.events.any((e) => e.message.contains('old')), false);
      expect(journal.events.single.message, 'handshake failed');
      expect(nonces, ['old', 'new']);
      allowed = false;
      newest.add(line('connection failed'));
      await Future<void>.delayed(Duration.zero);
      expect(journal.events.length, 1);
      await capture.stop();
      await newest.close();
    },
  );
  test(
    'dead stream is diagnostics only; current=false makes no request',
    () async {
      final journal = DiagnosticJournal(persist: false);
      var requests = 0;
      final capture = WindowsCoreDiagnostics(
        journal: journal,
        stream: (_) async {
          requests++;
          throw StateError('private path');
        },
      );
      await capture.attach('nonce', isCurrent: () => false);
      expect(requests, 0);
      await capture.attach('nonce', isCurrent: () => true);
      expect(
        journal.events.single.message,
        'core diagnostics stream unavailable',
      );
      expect(journal.events.single.message, isNot(contains('private path')));
      await capture.stop();
    },
  );
  test('hung diagnostic stream cancellation cannot block VPN stop', () async {
    final never = Completer<void>();
    final stream = StreamController<List<int>>(onCancel: () => never.future);
    final capture = WindowsCoreDiagnostics(
      journal: DiagnosticJournal(persist: false),
      stream: (_) async => stream.stream,
      cancelTimeout: const Duration(milliseconds: 20),
    );
    await capture.attach('nonce', isCurrent: () => true);
    final watch = Stopwatch()..start();
    await capture.stop();
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(250));
    never.complete();
    await stream.close();
  });
}
