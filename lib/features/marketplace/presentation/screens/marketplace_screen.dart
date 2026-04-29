import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/vpn_provider.dart';
import '../widgets/top_providers_carousel.dart';
import '../widgets/provider_card.dart';

class MarketplaceScreen extends StatelessWidget {
  const MarketplaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VPN Marketplace')),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      const Text('VPN сервисы', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                TopProvidersCarousel(
                  providers: ProviderCatalog.top3,
                  onTap: (p) => context.push('/marketplace/${p.id}'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => ProviderCard(
                provider: ProviderCatalog.all[i],
                onTap: () => ctx.push('/marketplace/${ProviderCatalog.all[i].id}'),
              ),
              childCount: ProviderCatalog.all.length,
            ),
          ),

          // Ad placement slot
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _AdSlot(),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdSlot extends StatelessWidget {
  const _AdSlot();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse('https://t.me/honeyvpnmanager'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outline.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(Icons.campaign_outlined, size: 20, color: cs.onSurface.withOpacity(0.4)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Здесь может быть размещен ваш сервис',
                style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.55)),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'TG · @honeyvpnmanager',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
