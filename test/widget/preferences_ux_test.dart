import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/dns_settings_screen.dart';

void main() {
  testWidgets('DNS editor receives saved URL when settings finish loading', (
    tester,
  ) async {
    final loaded = Completer<AppSettings>();
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _DelayedSettings(loaded)),
            stringsProvider.overrideWithValue(const S('ru')),
          ],
          child: MaterialApp(
            theme: honeyThemeForWidth(honeyThemeLight, 800),
            home: const DnsSettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      loaded.complete(
        const AppSettings(
          dnsPreset: DnsPreset.custom,
          customDnsUrl: 'https://saved.example.invalid/dns-query',
        ),
      );
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('custom-dns-field'));
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'https://saved.example.invalid/dns-query',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DnsSettingsScreen)),
      );
      await tester.tap(find.text('Cloudflare'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.dnsPreset,
        DnsPreset.cloudflare,
      );
      await tester.tap(find.text(const S('ru').dnsPresetLabel('custom')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'https://saved.example.invalid/dns-query',
      );
      await tester.enterText(
        editor,
        'https://edited.example.invalid/dns-query',
      );
      await tester.tap(find.text(const S('ru').saveButton));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.customDnsUrl,
        'https://edited.example.invalid/dns-query',
      );
      expect(tester.takeException(), isNull);
    } finally {
      if (!loaded.isCompleted) loaded.complete(const AppSettings());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
  testWidgets(
    'custom DNS validates supported forms before changing preferences',
    (tester) async {
      try {
        final container = await _renderDns(tester, const AppSettings());
        final notifier =
            container.read(settingsProvider.notifier) as _DelayedSettings;
        await tester.tap(find.text(const S('ru').dnsPresetLabel('custom')));
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).requireValue.dnsPreset,
          DnsPreset.cloudflare,
        );
        expect(notifier.writes, 0);
        final editor = find.byKey(const ValueKey('custom-dns-field'));
        final s = const S('ru');
        final invalid = {
          '': s.invalidDnsAddress,
          'not-a-server': s.invalidDnsAddress,
          'https://': s.invalidDnsAddress,
          'udp://1.1.1.1': s.invalidDnsAddress,
          'https://dns.example:0/dns-query': s.customDnsPortUnsupported,
          'https://dns.example:65536/dns-query': s.customDnsPortUnsupported,
          'https://dns.example/dns-query?token=sample':
              s.customDnsExtrasUnsupported,
          'https://user:password@dns.example/dns-query':
              s.customDnsExtrasUnsupported,
          'tls://dns.example#fragment': s.customDnsExtrasUnsupported,
          'tls://dns.example/path': s.customDnsTlsPathUnsupported,
        };
        for (final entry in invalid.entries) {
          await tester.enterText(editor, entry.key);
          await tester.tap(find.text(s.saveButton));
          await tester.pumpAndSettle();
          expect(find.text(entry.value), findsOneWidget, reason: entry.key);
          expect(notifier.writes, 0);
          expect(
            container.read(settingsProvider).requireValue.dnsPreset,
            DnsPreset.cloudflare,
          );
        }
        for (final address in [
          'https://dns.example:443/custom-dns',
          'https://dns.example:8443/custom-dns',
          'tls://dns.example:853',
          'tls://dns.example:8853',
          'tls://[2001:4860:4860::8888]',
        ]) {
          await tester.enterText(editor, address);
          await tester.tap(find.text(s.saveButton));
          await tester.pumpAndSettle();
          expect(
            container.read(settingsProvider).requireValue.dnsPreset,
            DnsPreset.custom,
          );
          expect(
            container.read(settingsProvider).requireValue.customDnsUrl,
            address,
          );
          expect(
            tester.widget<TextField>(editor).decoration!.errorText,
            isNull,
          );
        }
        expect(notifier.writes, 5);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'an existing unsupported DNS address stays visible until the user corrects it',
    (tester) async {
      const address = 'https://legacy.example:0/dns-query';
      try {
        final container = await _renderDns(
          tester,
          const AppSettings(dnsPreset: DnsPreset.custom, customDnsUrl: address),
        );
        final editor = find.byKey(const ValueKey('custom-dns-field'));
        expect(tester.widget<TextField>(editor).controller!.text, address);
        await tester.tap(find.text(const S('ru').saveButton));
        await tester.pumpAndSettle();
        expect(
          find.text(const S('ru').customDnsPortUnsupported),
          findsOneWidget,
        );
        expect(
          container.read(settingsProvider).requireValue.customDnsUrl,
          address,
        );
        expect(
          (container.read(settingsProvider.notifier) as _DelayedSettings)
              .writes,
          0,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
}

class _DelayedSettings extends SettingsNotifier {
  final Completer<AppSettings> loaded;
  int writes = 0;
  _DelayedSettings(this.loaded);
  @override
  Future<AppSettings> build() => loaded.future;
  @override
  Future<void> setDns(DnsPreset preset, {String customUrl = ''}) async {
    writes++;
    state = AsyncData(
      state.requireValue.copyWith(dnsPreset: preset, customDnsUrl: customUrl),
    );
  }
}

Future<ProviderContainer> _renderDns(
  WidgetTester tester,
  AppSettings settings,
) async {
  final loaded = Completer<AppSettings>()..complete(settings);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _DelayedSettings(loaded)),
        stringsProvider.overrideWithValue(const S('ru')),
      ],
      child: MaterialApp(
        theme: honeyThemeForWidth(honeyThemeLight, 800),
        home: const DnsSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(DnsSettingsScreen)),
  );
}
