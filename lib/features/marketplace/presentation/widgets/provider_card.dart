import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/vpn_provider.dart';

class ProviderCard extends ConsumerWidget {
  final VpnProvider provider;
  final VoidCallback onTap;
  final ValueChanged<String>? onOpenExternal;

  const ProviderCard({
    super.key,
    required this.provider,
    required this.onTap,
    this.onOpenExternal,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final locale = ref.watch(stringsProvider).locale;
    final ru = locale == 'ru';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          container: true,
          button: true,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: provider.logoAsset.isNotEmpty
                              ? Image.asset(
                                  provider.logoAsset,
                                  fit: BoxFit.cover,
                                )
                              : ColoredBox(
                                  color: cs.surfaceContainer,
                                  child: Center(
                                    child: Text(provider.name.substring(0, 1)),
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
                              style: theme.textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              provider.protocols.join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          provider.pricing.priceLabelForLocale(locale) ??
                              (provider.pricing.hasFree
                                  ? provider.pricing.freeDescriptionForLocale(
                                          locale,
                                        ) ??
                                        (ru
                                            ? 'Бесплатный доступ'
                                            : 'Free access')
                                  : (ru ? 'От ' : 'From ') +
                                        '\$${provider.pricing.monthlyPriceUsd.toStringAsFixed(2)}/${ru ? 'мес.' : 'mo'}'),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          if (onOpenExternal != null) {
                            onOpenExternal!(provider.referralUrl);
                          } else {
                            launchUrl(
                              Uri.parse(provider.referralUrl),
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                        child: Text(ru ? 'Перейти' : 'Open'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
