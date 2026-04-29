import 'package:flutter/material.dart';

import '../../domain/entities/vpn_provider.dart';

class TopProvidersCarousel extends StatelessWidget {
  final List<VpnProvider> providers;
  final void Function(VpnProvider) onTap;

  const TopProvidersCarousel({super.key, required this.providers, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final badges = ['TOP PICK', '#1 RATED', 'BEST VALUE'];
    final gradients = [
      [const Color(0xFF8B5CF6), const Color(0xFF6366F1)],
      [const Color(0xFFEAB308), const Color(0xFFF97316)],
      [const Color(0xFF22C55E), const Color(0xFF06B6D4)],
    ];

    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: providers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (ctx, i) {
          final p = providers[i];
          final colors = gradients[i % gradients.length];
          final badge = badges[i % badges.length];
          return _TopCard(provider: p, badge: badge, gradientColors: colors, onTap: () => onTap(p));
        },
      ),
    );
  }
}

class _TopCard extends StatelessWidget {
  final VpnProvider provider;
  final String badge;
  final List<Color> gradientColors;
  final VoidCallback onTap;

  const _TopCard({
    required this.provider,
    required this.badge,
    required this.gradientColors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 200,
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background image
              if (provider.logoAsset.isNotEmpty)
                Image.asset(
                  provider.logoAsset,
                  fit: BoxFit.cover,
                  width: 200,
                  height: 180,
                ),

              // Dark gradient overlay
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.25),
                      Colors.black.withOpacity(0.72),
                    ],
                  ),
                ),
              ),

              // Border overlay
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: gradientColors.first.withOpacity(0.45),
                    width: 1.5,
                  ),
                ),
              ),

              // Content
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: gradientColors),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      provider.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.star_rounded, size: 14, color: gradientColors.first),
                        const SizedBox(width: 2),
                        Text(
                          provider.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '(${provider.reviewCount})',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      provider.pricing.priceLabel ??
                          (provider.pricing.hasFree
                              ? 'Free available'
                              : 'From \$${provider.pricing.monthlyPriceUsd.toStringAsFixed(2)}/mo'),
                      style: TextStyle(
                        fontSize: 12,
                        color: gradientColors.first,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
