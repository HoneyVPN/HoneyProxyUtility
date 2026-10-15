import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/vpn_provider.dart';

class TopProvidersCarousel extends ConsumerWidget {
  final List<VpnProvider> providers;
  final void Function(VpnProvider) onTap;
  const TopProvidersCarousel({
    super.key,
    required this.providers,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(stringsProvider).locale;
    return SizedBox(
      height: 112,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: providers.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final provider = providers[index];
            final theme = Theme.of(context);
            return SizedBox(
              width: 208,
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onTap(provider),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (provider.logoAsset.isNotEmpty) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.asset(
                                  provider.logoAsset,
                                  width: 28,
                                  height: 28,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                provider.name,
                                style: theme.textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          provider.pricing.priceLabelForLocale(locale) ??
                              provider.pricing.freeDescriptionForLocale(
                                locale,
                              ) ??
                              provider.protocols.join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
