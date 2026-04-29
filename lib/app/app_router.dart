import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/connection/presentation/screens/home_screen.dart';
import '../features/servers/presentation/screens/server_detail_screen.dart';
import '../features/converter/presentation/screens/converter_screen.dart';
import '../features/subscriptions/presentation/screens/subscriptions_screen.dart';
import '../features/marketplace/presentation/screens/marketplace_screen.dart';
import '../features/marketplace/presentation/screens/provider_detail_screen.dart';
import '../features/settings/presentation/screens/settings_screen.dart';
import '../features/settings/presentation/screens/routing_settings_screen.dart';
import '../features/settings/presentation/screens/dns_settings_screen.dart';
import '../features/settings/presentation/screens/split_tunnel_screen.dart';
import '../features/settings/presentation/screens/log_screen.dart';
import '../features/settings/presentation/screens/url_schemes_screen.dart';
import '../features/onboarding/presentation/screens/splash_screen.dart';
import '../features/onboarding/presentation/screens/welcome_screen.dart';
import '../features/onboarding/presentation/screens/permission_screen.dart';
import 'shell_scaffold.dart';

final appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (_, __) => const SplashScreen(),
    ),
    GoRoute(
      path: '/welcome',
      builder: (_, __) => const WelcomeScreen(),
    ),
    GoRoute(
      path: '/permission',
      builder: (_, __) => const PermissionScreen(),
    ),
    // Push-only routes (no bottom nav bar)
    GoRoute(
      path: '/servers/:id',
      builder: (_, state) => ServerDetailScreen(id: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/subscriptions',
      builder: (_, __) => const SubscriptionsScreen(),
    ),
    ShellRoute(
      builder: (context, state, child) => ShellScaffold(child: child),
      routes: [
        // Tab routes use NoTransitionPage — AnimatedSwitcher handles the animation
        GoRoute(
          path: '/',
          pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen()),
        ),
        GoRoute(
          path: '/converter',
          pageBuilder: (_, state) => NoTransitionPage(
            child: ConverterScreen(
              initialText: state.uri.queryParameters['initialText'],
            ),
          ),
        ),
        GoRoute(
          path: '/marketplace',
          pageBuilder: (_, __) => const NoTransitionPage(child: MarketplaceScreen()),
          routes: [
            GoRoute(
              path: ':id',
              builder: (_, state) =>
                  ProviderDetailScreen(id: state.pathParameters['id']!),
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (_, __) => const NoTransitionPage(child: SettingsScreen()),
          routes: [
            GoRoute(
              path: 'routing',
              builder: (_, __) => const RoutingSettingsScreen(),
            ),
            GoRoute(
              path: 'dns',
              builder: (_, __) => const DnsSettingsScreen(),
            ),
            GoRoute(
              path: 'split-tunnel',
              builder: (_, __) => const SplitTunnelScreen(),
            ),
            GoRoute(
              path: 'log',
              builder: (_, __) => const LogScreen(),
            ),
            GoRoute(
              path: 'url-schemes',
              builder: (_, __) => const UrlSchemesScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);
