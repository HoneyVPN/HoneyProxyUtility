import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/vpn_provider.dart';
import '../../../../app/app_theme.dart';

class ProviderDetailScreen extends StatelessWidget {
  final String id;
  const ProviderDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final provider = ProviderCatalog.all.where((p) => p.id == id).firstOrNull;
    if (provider == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Provider')),
        body: const Center(child: Text('Provider not found')),
      );
    }
    return _ProviderDetailView(provider: provider);
  }
}

class _ProviderDetailView extends StatelessWidget {
  final VpnProvider provider;
  const _ProviderDetailView({required this.provider});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(provider.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // "Our service" banner
          if (provider.isOwn) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [NexPalette.accent.withOpacity(0.18), NexPalette.accent.withOpacity(0.06)],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexPalette.accent.withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_rounded, color: NexPalette.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.tagline,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: NexPalette.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Header card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: provider.logoAsset.isNotEmpty
                        ? Image.asset(
                            provider.logoAsset,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 80,
                            height: 80,
                            color: provider.isOwn
                                ? NexPalette.accent.withOpacity(0.15)
                                : cs.surfaceContainerHighest,
                            child: Center(
                              child: Text(
                                provider.name.substring(0, 1).toUpperCase(),
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                  color: provider.isOwn ? NexPalette.accent : cs.primary,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  Text(provider.name,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    provider.pricing.priceLabel ?? '90₽ / мес',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Description
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('О сервисе',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(provider.shortDescription,
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Features
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Возможности',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: provider.features
                        .map((f) => Chip(
                          label: Text(f, style: TextStyle(fontSize: 12, color: cs.onSurface)),
                          backgroundColor: cs.surfaceContainerHighest,
                          side: BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
                        ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Protocols
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Протоколы',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: provider.protocols
                        .map((p) => Chip(
                              label: Text(p, style: const TextStyle(fontSize: 12)),
                              backgroundColor: cs.primaryContainer.withOpacity(0.5),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Trial period banner
          if (provider.pricing.trialDescription != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [const Color(0xFFFFB300).withOpacity(0.15), const Color(0xFFFFB300).withOpacity(0.05)],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(child: Text('🎁', style: TextStyle(fontSize: 22))),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Пробный период',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFFFFB300)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '3 дня бесплатного доступа',
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65)),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '3 дня',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFFFB300)),
                    ),
                  ),
                ],
              ),
            ),

          // CTA — try free via Telegram bot
          FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(provider.referralUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Text('🎁', style: TextStyle(fontSize: 18)),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('3 дня бесплатно', style: TextStyle(fontSize: 16)),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
