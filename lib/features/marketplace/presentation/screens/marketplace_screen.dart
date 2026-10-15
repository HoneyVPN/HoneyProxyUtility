import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/vpn_provider.dart';
import '../widgets/provider_card.dart';

class MarketplaceScreen extends ConsumerWidget {
  const MarketplaceScreen({super.key, this.catalog, this.onOpenExternal});

  final List<VpnProvider>? catalog;
  final ValueChanged<String>? onOpenExternal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    final providers = catalog ?? ProviderCatalog.all;
    return Scaffold(
      appBar: AppBar(title: Text(strings.marketTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final provider in providers)
                ProviderCard(
                  provider: provider,
                  onTap: () => context.push('/marketplace/${provider.id}'),
                  onOpenExternal: onOpenExternal,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      const url = 'https://t.me/honeyvpnmanager';
                      if (onOpenExternal != null) {
                        onOpenExternal!(url);
                      } else {
                        launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: Text(ru ? 'Разместить сервис' : 'List a provider'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
