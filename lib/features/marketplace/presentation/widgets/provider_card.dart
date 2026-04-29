import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/vpn_provider.dart';
import '../../../../app/app_theme.dart';

class ProviderCard extends StatelessWidget {
  final VpnProvider provider;
  final VoidCallback onTap;

  const ProviderCard({super.key, required this.provider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Logo
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: Colors.black,
                        child: provider.logoAsset.isNotEmpty
                            ? Image.asset(
                                provider.logoAsset,
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                              )
                            : Center(
                                child: Text(
                                  provider.name.substring(0, 1).toUpperCase(),
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: cs.primary),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.name,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(Icons.star_rounded, size: 13, color: NexColors.gold),
                              const SizedBox(width: 2),
                              Text(
                                provider.rating.toStringAsFixed(1),
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  provider.shortDescription,
                  style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.7)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: provider.features.take(4).map((f) => _FeatureChip(label: f)).toList(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        provider.pricing.priceLabel ??
                            (provider.pricing.hasFree
                                ? provider.pricing.freeDescription ?? 'Free tier'
                                : 'From \$${provider.pricing.monthlyPriceUsd.toStringAsFixed(2)}/mo'),
                        style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w600),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => launchUrl(
                        Uri.parse(provider.referralUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      child: Text(provider.isOwn ? '3 дня бесплатно →' : 'Visit →'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final String label;
  const _FeatureChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500)),
    );
  }
}
