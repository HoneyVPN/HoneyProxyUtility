// Local visual review entrypoint. No production router, native VPN or network.
// flutter run -d web-server -t test/support/design_preview.dart
import 'dart:convert';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_journal.dart';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/app/shell_scaffold.dart';
import 'package:honeyproxyutility/features/connection/data/vpn_disclosure_provider.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/converter/presentation/screens/converter_screen.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/marketplace/domain/entities/vpn_provider.dart';
import 'package:honeyproxyutility/features/marketplace/presentation/screens/marketplace_screen.dart';
import 'package:honeyproxyutility/features/marketplace/presentation/screens/provider_detail_screen.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/screens/server_detail_screen.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/data/log_provider.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/routing_settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/dns_settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/log_screen.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/screens/subscriptions_screen.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_order.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';
import 'package:honeyproxyutility/features/update/update_provider.dart';

void main() => runApp(designPreviewApp());

/// Long enough to review progress without fetching a real subscription.
const designPreviewRefreshDuration = Duration(milliseconds: 2400);

/// Same mock app used by browser review and widget screenshot exports.
Widget designPreviewApp({
  bool showControls = true,
  GlobalKey? repaintKey,
  HttpClientAdapter? converterAdapter,
}) => designPreviewScope(
  converterAdapter: converterAdapter,
  child: RepaintBoundary(
    key: repaintKey,
    child: _DesignPreview(showControls: showControls),
  ),
);

/// Mock all platform/network state when reviewing real production widgets.
Widget designPreviewScope({
  required Widget child,
  HttpClientAdapter? converterAdapter,
}) {
  PackageInfo.setMockInitialValues(
    appName: 'HoneyProxyUtility',
    packageName: 'ru.honeyvpn.proxy.preview',
    version: '1.2.0-preview',
    buildNumber: '2127',
    buildSignature: '',
  );
  return ProviderScope(
    overrides: [
      diagnosticUploaderProvider.overrideWith(
        (_) => DiagnosticUploader(demo: true),
      ),
      diagnosticReportBuilderProvider.overrideWith(
        (_) => DiagnosticReportBuilder(
          journal: DiagnosticJournal(persist: false),
          native: () async => {
            'availability': 'not-supported',
            'state': 'unknown',
            'apiLevel': 0,
            'events': <Object>[],
          },
        ),
      ),
      connectionNotifierProvider.overrideWith(_DemoConnection.new),
      serversNotifierProvider.overrideWith(_DemoServers.new),
      builtInFreeServerPresentProvider.overrideWith(
        (ref) => (ref.watch(serversNotifierProvider).value ?? []).any(
          (server) => server.subscriptionId == _freeUrl,
        ),
      ),
      subscriptionsProvider.overrideWith(_DemoSubscriptions.new),
      subscriptionDioProvider.overrideWith(
        (_) => throw UnsupportedError(
          'Subscriptions are not fetched in the design preview',
        ),
      ),
      settingsProvider.overrideWith(_DemoSettings.new),
      logProvider.overrideWith((_) => _DemoLogs()),
      converterDioProvider.overrideWith((ref) {
        final client = Dio()
          ..httpClientAdapter = converterAdapter ?? _DemoHttpAdapter();
        ref.onDispose(() => client.close(force: true));
        return client;
      }),
      vpnDisclosureProvider.overrideWith(_DemoDisclosure.new),
      updateProvider.overrideWithValue(const AsyncData(null)),
    ],
    child: child,
  );
}

GoRouter _createRouter() => GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) => ShellScaffold(child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (_, state) =>
              NoTransitionPage(key: state.pageKey, child: const HomeScreen()),
        ),
        GoRoute(
          path: '/converter',
          pageBuilder: (_, state) => NoTransitionPage(
            key: state.pageKey,
            child: ConverterScreen(
              initialText:
                  state.uri.queryParameters['initialText'] ??
                  designPreviewProxyLink.replaceFirst(
                    '#Demo%20Amsterdam',
                    '#NL%20Demo%20Amsterdam',
                  ),
            ),
          ),
        ),
        GoRoute(
          path: '/marketplace',
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: MarketplaceScreen(
              catalog: _demoCatalog,
              onOpenExternal: (_) => _showDemoExternalAction(context),
            ),
          ),
          routes: [
            GoRoute(
              path: ':id',
              builder: (context, state) => ProviderDetailScreen(
                id: state.pathParameters['id']!,
                catalog: _demoCatalog,
                onOpenExternal: (_) => _showDemoExternalAction(context),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (_, state) => NoTransitionPage(
            key: state.pageKey,
            child: const SettingsScreen(),
          ),
          routes: [
            GoRoute(
              path: 'routing',
              builder: (_, __) => const RoutingSettingsScreen(),
            ),
            GoRoute(path: 'dns', builder: (_, __) => const DnsSettingsScreen()),
            GoRoute(path: 'log', builder: (_, __) => const LogScreen()),
            for (final detail in ['split-tunnel', 'url-schemes'])
              GoRoute(
                path: detail,
                builder: (_, __) => const _PreviewPlaceholder(),
              ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/subscriptions',
      builder: (_, __) => const _PreviewSubscriptions(),
    ),
    GoRoute(
      path: '/servers/:id',
      builder: (_, state) =>
          ServerDetailScreen(id: state.pathParameters['id']!),
    ),
  ],
);

class _DesignPreview extends ConsumerStatefulWidget {
  final bool showControls;
  const _DesignPreview({required this.showControls});
  @override
  ConsumerState<_DesignPreview> createState() => _DesignPreviewState();
}

class _DesignPreviewState extends ConsumerState<_DesignPreview> {
  final GoRouter _router = _createRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Honey · Design preview',
      theme: honeyThemeLight.copyWith(platform: TargetPlatform.macOS),
      darkTheme: honeyThemeDark.copyWith(platform: TargetPlatform.macOS),
      themeMode: settings?.themeMode ?? ThemeMode.light,
      locale: Locale(settings?.locale ?? 'ru'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('ru')],
      routerConfig: _router,
      // Browser view focus can arrive before its first layout. The review
      // toolbar and router share tree order, so traversal needs no box rects.
      builder: (context, child) {
        final product = Theme(
          data: honeyThemeForWidth(
            Theme.of(context),
            MediaQuery.sizeOf(context).width,
          ),
          child: child ?? const SizedBox.shrink(),
        );
        return FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: widget.showControls
                ? Column(
                    children: [
                      const _PreviewControls(),
                      Expanded(
                        // Keep GoRouter's ModalBarrier semantics within the
                        // content so the review controls remain accessible.
                        child: Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: product,
                        ),
                      ),
                    ],
                  )
                : product,
          ),
        );
      },
    );
  }
}

class _PreviewControls extends ConsumerWidget {
  const _PreviewControls();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final connected = ref.watch(connectionNotifierProvider).isConnected;
    final ru = settings.locale == 'ru';
    void toggleTheme() {
      ref
          .read(settingsProvider.notifier)
          .setTheme(
            settings.themeMode == ThemeMode.dark
                ? ThemeMode.light
                : ThemeMode.dark,
          );
    }

    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              Text(
                ru ? 'Предпросмотр' : 'Preview',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              // This review toolbar is above GoRouter's Navigator/Overlay.
              // Expose the label directly instead of creating a Tooltip there.
              Semantics(
                container: true,
                button: true,
                label: ru ? 'Сменить тему' : 'Change theme',
                onTap: toggleTheme,
                child: ExcludeSemantics(
                  child: IconButton(
                    icon: Icon(
                      settings.themeMode == ThemeMode.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      size: 18,
                    ),
                    onPressed: toggleTheme,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .setLocale(ru ? 'en' : 'ru'),
                child: Text(
                  ru ? 'RU' : 'EN',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              TextButton.icon(
                icon: Icon(
                  connected
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 16,
                ),
                label: Text(
                  ru ? 'Соединение' : 'Connection',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () {
                  final notifier = ref.read(
                    connectionNotifierProvider.notifier,
                  );
                  if (connected) {
                    notifier.disconnect();
                  } else {
                    final server = ref.read(selectedServerProvider);
                    if (server != null) notifier.connect(server);
                  }
                },
              ),
              TextButton(
                child: Text(
                  ru ? '1 / 3 сервера' : '1 / 3 servers',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () {
                  ref.read(connectionNotifierProvider.notifier).disconnect();
                  (ref.read(serversNotifierProvider.notifier) as _DemoServers)
                      .togglePaid();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewSubscriptions extends ConsumerWidget {
  const _PreviewSubscriptions();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ru = ref.watch(stringsProvider).locale == 'ru';
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              ru
                  ? 'Демо: подписки временные, ссылки не загружаются.'
                  : 'Demo: subscriptions are temporary; links are not fetched.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const Expanded(child: SubscriptionsScreen()),
      ],
    );
  }
}

class _PreviewPlaceholder extends ConsumerWidget {
  const _PreviewPlaceholder();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ru = ref.watch(stringsProvider).locale == 'ru';
    return Scaffold(
      appBar: AppBar(title: Text(ru ? 'Предпросмотр' : 'Preview')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ru
                    ? 'Этот экран не включён в локальное демо.'
                    : 'This screen is outside the local demo.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/'),
                child: Text(ru ? 'На главный экран' : 'Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _freeUrl = 'https://free.example.invalid/demo';
const _paidUrl = 'https://paid.example.invalid/demo';

const designPreviewProxyLink =
    'vless://11111111-1111-4111-8111-111111111111@import.example.invalid:443'
    '?encryption=none&security=tls&sni=import.example.invalid&type=tcp'
    '#Demo%20Amsterdam';

const _demoCatalog = [
  VpnProvider(
    id: 'honeyvpn',
    name: 'HoneyVPN · Демо',
    logoAsset: 'assets/images/honey_bear.jpg',
    websiteUrl: 'https://demo.example.invalid/honey',
    referralUrl: 'https://demo.example.invalid/honey',
    rating: 0,
    reviewCount: 0,
    tier: ProviderTier.standard,
    categories: [ProviderCategory.privacy],
    protocols: ['VLESS', 'Hysteria2'],
    serverCount: 3,
    countryCount: 3,
    pricing: PricingInfo(
      hasFree: true,
      monthlyPriceUsd: 0,
      priceLabel: 'Демо-тариф',
      trialDescription: 'Пример пробного доступа',
    ),
    features: ['Импорт подписки', 'Несколько серверов'],
    shortDescription: 'Пример каталога. Внешние ссылки в демо не открываются.',
    supportsImport: true,
    subscriptionUrlTemplate: 'https://demo.example.invalid/subscription',
  ),
];

void _showDemoExternalAction(BuildContext context) {
  final ru =
      ProviderScope.containerOf(context).read(stringsProvider).locale == 'ru';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        ru
            ? 'Демо: внешние ссылки не открываются.'
            : 'Demo: external links are not opened.',
      ),
    ),
  );
}

class _DemoHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    designPreviewProxyLink,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

List<ServerProfileModel> _sampleServers() => [
  for (final item in [
    (1, 'NL Нидерланды', _freeUrl, 42.0),
    (2, 'DE Германия', _paidUrl, 58.0),
    (3, 'FI Финляндия', _paidUrl, 67.0),
  ])
    ServerProfileModel(
      id: item.$1,
      protocol: 'vless',
      name: item.$2,
      host: 'server-${item.$1}.example.invalid',
      port: 443,
      configJson: jsonEncode({'rawLink': _sampleLink(item.$1)}),
      subscriptionId: item.$3,
      addedAt: DateTime(2026, 1, 1),
      latencyMs: item.$4,
      isSelected: item.$1 == 1,
    ),
];

String _sampleLink(int id) {
  final options = switch (id) {
    2 => 'type=ws&security=tls&path=%2Fdemo',
    3 =>
      'type=xhttp&security=reality&mode=auto&fp=ios'
          '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=00',
    _ => 'type=tcp&security=tls',
  };
  return 'vless://11111111-1111-4111-8111-111111111111'
      '@server-$id.example.invalid:443?$options'
      '&sni=server-$id.example.invalid#Demo';
}

class _DemoConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => NexConnectionState.initial();
  @override
  Future<void> connect(ServerProfileModel server) async {
    state = NexConnectionState(
      status: ConnectionStatus.connected,
      activeServer: server,
      stats: const VpnStats(
        downloadSpeed: 3.8 * 1024 * 1024,
        uploadSpeed: 172 * 1024,
        sessionDuration: Duration(minutes: 17, seconds: 26),
      ),
    );
  }

  @override
  Future<void> disconnect() async => state = NexConnectionState.initial();
}

class _DemoServers extends ServersNotifier {
  var _showPaid = true;
  @override
  Future<List<ServerProfileModel>> build() async => _sampleServers();
  @override
  Future<void> addFromProxy(ParsedProxy proxy, {String subscriptionId = ''}) =>
      addFromProxies([proxy], subscriptionId: subscriptionId);

  @override
  Future<void> addFromProxies(
    List<ParsedProxy> proxies, {
    String subscriptionId = '',
  }) async {
    final current = state.value ?? await future;
    var id = current.isEmpty
        ? 1
        : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    state = AsyncData([
      ...current,
      for (final proxy in proxies)
        ServerProfileModel(
          id: id++,
          protocol: switch (proxy.protocolLabel.toLowerCase()) {
            'amneziawg' => 'awg',
            'wireguard' => 'wg',
            final label => label,
          },
          name: proxy.displayName,
          host: proxy.host,
          port: proxy.port,
          configJson: '{}',
          subscriptionId: subscriptionId,
          addedAt: DateTime.now(),
        ),
    ]);
  }

  void togglePaid() {
    _showPaid = !_showPaid;
    state = AsyncData(
      _sampleServers().where((server) => _showPaid || server.id == 1).toList(),
    );
  }

  void addDemoSubscription(String url, String label) {
    final current = state.value ?? [];
    final id = current.isEmpty
        ? 1
        : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    state = AsyncData([
      ...current,
      ServerProfileModel(
        id: id,
        protocol: 'vless',
        name: label,
        host: 'demo-$id.example.invalid',
        port: 443,
        configJson: '{}',
        subscriptionId: url,
        addedAt: DateTime.now(),
        latencyMs: 54,
      ),
    ]);
  }

  @override
  Future<void> selectServer(ServerProfileModel server) async {
    state = AsyncData(
      (state.value ?? [])
          .map((item) => item.copyWith(isSelected: item.id == server.id))
          .toList(),
    );
  }

  @override
  Future<bool> selectServerIfCurrent(ServerProfileModel expected) async {
    if (!state.requireValue.any(expected.hasSameConnectionIdentity))
      return false;
    await selectServer(expected);
    return true;
  }

  @override
  Future<void> delete(int id, {String? expectedSubscriptionId}) async {
    state = AsyncData(
      (state.value ?? [])
          .where(
            (server) =>
                server.id != id ||
                (expectedSubscriptionId != null &&
                    server.subscriptionId != expectedSubscriptionId),
          )
          .toList(),
    );
  }

  @override
  Future<void> deleteAll(
    List<int> ids, {
    String? expectedSubscriptionId,
  }) async {
    state = AsyncData(
      (state.value ?? [])
          .where(
            (server) =>
                !ids.contains(server.id) ||
                (expectedSubscriptionId != null &&
                    server.subscriptionId != expectedSubscriptionId),
          )
          .toList(),
    );
  }

  @override
  Future<void> updateLatency(int id, double ms) async {
    state = AsyncData([
      for (final server in state.value ?? <ServerProfileModel>[])
        server.id == id ? server.copyWith(latencyMs: ms) : server,
    ]);
  }

  @override
  Future<bool> setFavoriteIfCurrent(
    ServerProfileModel expected,
    bool isFavorite,
  ) async {
    final profiles = state.requireValue;
    if (!profiles.any(
      (profile) => expected.hasSameConnectionIdentity(profile),
    )) {
      return false;
    }
    state = AsyncData([
      for (final profile in profiles)
        expected.hasSameConnectionIdentity(profile)
            ? profile.copyWith(isFavorite: isFavorite)
            : profile,
    ]);
    return true;
  }

  @override
  Future<double> testLatency(ServerProfileModel server) async {
    final latency = server.latencyMs ?? 42;
    await updateLatency(server.id, latency);
    return latency;
  }

  @override
  Future<void> testAllLatency() async {
    state = AsyncData([
      for (final server in state.value ?? <ServerProfileModel>[])
        server.copyWith(latencyMs: server.latencyMs ?? 42),
    ]);
  }

  @override
  Future<void> deleteBySubscription(String subscriptionId) async {
    state = AsyncData(
      (state.value ?? [])
          .where((server) => server.subscriptionId != subscriptionId)
          .toList(),
    );
  }
}

class _DemoSubscriptions extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState(
    failures: {2: SubscriptionFailure.updateFailed},
    subs: [
      SubscriptionModel(
        id: 1,
        url: _freeUrl,
        name: 'HoneyVPN · Бесплатно',
        serverCount: 1,
      ),
      SubscriptionModel(
        id: 2,
        url: _paidUrl,
        name: 'HoneyVPN · Plus',
        serverCount: 2,
        providerGeoStatus: ProviderGeoStatus.stale,
        providerGeoIssue: ProviderGeoIssue.download,
      ),
    ],
  );
  @override
  Future<void> addBuiltInFreeServer() async {
    final profiles = await ref.read(serversNotifierProvider.future);
    if (profiles.any((server) => server.subscriptionId == _freeUrl)) return;
    final current = state.value ?? await future;
    final latest = ref.read(serversNotifierProvider).value ?? profiles;
    if (latest.any((server) => server.subscriptionId == _freeUrl)) return;
    (ref.read(serversNotifierProvider.notifier) as _DemoServers)
        .addDemoSubscription(_freeUrl, 'NL Нидерланды');
    final existing = current.subs.any((sub) => sub.url == _freeUrl);
    state = AsyncData(
      current.copyWith(
        subs: existing
            ? current.subs
                  .map(
                    (sub) => sub.url == _freeUrl
                        ? sub.copyWith(
                            serverCount: 1,
                            lastUpdated: DateTime.now(),
                          )
                        : sub,
                  )
                  .toList()
            : [
                ...current.subs,
                SubscriptionModel(
                  id: current.subs.isEmpty
                      ? 1
                      : current.subs
                                .map((sub) => sub.id)
                                .reduce((a, b) => a > b ? a : b) +
                            1,
                  url: _freeUrl,
                  name: 'HoneyVPN · Бесплатно',
                  serverCount: 1,
                  lastUpdated: DateTime.now(),
                ),
              ],
      ),
    );
  }

  @override
  Future<void> move(
    int id, {
    required String expectedUrl,
    int? beforeId,
    String? expectedBeforeUrl,
  }) async {
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        subs: moveSubscription(
          current.subs,
          id,
          expectedUrl: expectedUrl,
          beforeId: beforeId,
          expectedBeforeUrl: expectedBeforeUrl,
        ),
      ),
    );
  }

  @override
  Future<void> refreshAll() async =>
      _demoRefresh(state.requireValue.subs.map((sub) => sub.id).toSet());
  @override
  Future<void> refresh(int id) async => _demoRefresh({id});
  Future<void> _demoRefresh(Set<int> ids) async {
    if (state.requireValue.refreshing.isNotEmpty) return;
    final previous = {
      for (final sub in state.requireValue.subs) sub.id: sub.providerGeoStatus,
    };
    final previousFailures = state.requireValue.failures;
    state = AsyncData(
      state.requireValue.copyWith(
        refreshing: ids,
        failures: {...previousFailures}
          ..removeWhere((id, _) => ids.contains(id)),
        subs: state.requireValue.subs
            .map(
              (sub) =>
                  ids.contains(sub.id) &&
                      sub.providerGeoStatus != ProviderGeoStatus.absent &&
                      sub.providerGeoStatus != ProviderGeoStatus.off
                  ? sub.copyWith(providerGeoStatus: ProviderGeoStatus.updating)
                  : sub,
            )
            .toList(),
      ),
    );
    try {
      await Future<void>.delayed(designPreviewRefreshDuration);
    } finally {
      if (ref.mounted) {
        final current = state.requireValue;
        state = AsyncData(
          current.copyWith(
            refreshing: {},
            failures: {
              for (final row in previousFailures.entries)
                if (current.subs.any((sub) => sub.id == row.key))
                  row.key: row.value,
            },
            subs: current.subs
                .map(
                  (sub) => ids.contains(sub.id) && previous.containsKey(sub.id)
                      ? sub.copyWith(providerGeoStatus: previous[sub.id])
                      : sub,
                )
                .toList(),
          ),
        );
      }
    }
  }

  @override
  Future<void> adoptProviderResponse(
    String url,
    String body,
    Map<String, List<String>> headers,
  ) async {}
  @override
  Future<void> setInterval(int id, int hours) async {
    final current = state.value ?? await future;
    state = AsyncData(
      current.copyWith(
        subs: current.subs
            .map(
              (sub) =>
                  sub.id == id ? sub.copyWith(updateIntervalHours: hours) : sub,
            )
            .toList(),
      ),
    );
  }

  @override
  Future<void> add(String url, {String name = ''}) async {
    if (url.trim().isEmpty) return;
    final current = state.value ?? await future;
    final id = current.subs.isEmpty
        ? 1
        : current.subs.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    final demoUrl = 'https://demo.example.invalid/sub-$id';
    final label = name.trim().isEmpty ? 'Демо-подписка $id' : name.trim();
    final sub = SubscriptionModel(
      id: id,
      url: demoUrl,
      name: label,
      serverCount: 1,
      lastUpdated: DateTime.now(),
    );
    (ref.read(serversNotifierProvider.notifier) as _DemoServers)
        .addDemoSubscription(demoUrl, label);
    state = AsyncData(current.copyWith(subs: [...current.subs, sub]));
  }

  @override
  Future<void> register(String url, {String name = '', int serverCount = 0}) =>
      add(url, name: name);
  @override
  Future<int> importProxies(String url, List<ParsedProxy> proxies) async {
    await add(url);
    return 1;
  }

  @override
  Future<void> delete(int id) async {
    final current = state.value ?? const SubscriptionsState();
    final removed = current.subs.where((sub) => sub.id == id).firstOrNull;
    state = AsyncData(
      current.copyWith(
        subs: current.subs.where((sub) => sub.id != id).toList(),
      ),
    );
    if (removed != null)
      await ref
          .read(serversNotifierProvider.notifier)
          .deleteBySubscription(removed.url);
  }
}

class _DemoLogs extends LogNotifier {
  _DemoLogs() {
    state = [
      LogEntry(
        time: DateTime(2026, 10, 7, 17, 26),
        message: 'Демо: события отображаются локально, VPN не запускается.',
      ),
    ];
  }
}

class _DemoSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(locale: 'ru', themeMode: ThemeMode.light);

  Future<void> _change(AppSettings Function(AppSettings) transform) async {
    final current = state.value ?? await future;
    if (ref.mounted) state = AsyncData(transform(current));
  }

  @override
  Future<void> setTheme(ThemeMode value) =>
      _change((s) => s.copyWith(themeMode: value));
  @override
  Future<void> setRouting(RoutingMode value) =>
      _change((s) => s.copyWith(routingMode: value));
  @override
  Future<void> setGeoRoutingMode(GeoRoutingMode value) =>
      _change((s) => s.copyWith(geoRoutingMode: value));
  @override
  Future<void> setConnectionMode(ConnectionMode value) =>
      _change((s) => s.copyWith(connectionMode: value));
  @override
  Future<void> setFragmentation(bool value) =>
      _change((s) => s.copyWith(fragmentationEnabled: value));
  @override
  Future<void> setMultiplexer(bool value) =>
      _change((s) => s.copyWith(multiplexerEnabled: value));
  @override
  Future<void> setIpType(IpType value) =>
      _change((s) => s.copyWith(preferredIpType: value));
  @override
  Future<void> setAllowLan(bool value) =>
      _change((s) => s.copyWith(allowLanConnections: value));
  @override
  Future<void> setLocale(String value) =>
      _change((s) => s.copyWith(locale: value));
  @override
  Future<void> setTunStack(TunStack value) =>
      _change((s) => s.copyWith(tunStack: value));
  @override
  Future<void> setFakeip(bool value) =>
      _change((s) => s.copyWith(enableFakeip: value));
  @override
  Future<void> setLogLevel(LogLevel value) =>
      _change((s) => s.copyWith(logLevel: value));
  @override
  Future<void> setSocksPort(int value) =>
      _change((s) => s.copyWith(socksPort: value));
  @override
  Future<void> setHttpPort(int value) =>
      _change((s) => s.copyWith(httpPort: value));
  @override
  Future<void> setDns(DnsPreset preset, {String customUrl = ''}) =>
      _change((s) => s.copyWith(dnsPreset: preset, customDnsUrl: customUrl));
  @override
  Future<void> setPorts(int socks, int http) {
    if (socks < 1 ||
        socks > 65535 ||
        http < 1 ||
        http > 65535 ||
        socks == http) {
      throw ArgumentError('Ports must be distinct and between 1 and 65535');
    }
    return _change((s) => s.copyWith(socksPort: socks, httpPort: http));
  }
}

class _DemoDisclosure extends VpnDisclosureNotifier {
  @override
  Future<bool> build() async => true;
  @override
  Future<void> accept() async => state = const AsyncData(true);
}
