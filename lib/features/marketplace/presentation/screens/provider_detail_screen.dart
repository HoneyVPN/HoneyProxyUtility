import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/l10n/strings.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../subscriptions/data/services/subscriptions_notifier.dart';
import '../../domain/entities/vpn_provider.dart';

class ProviderDetailScreen extends ConsumerStatefulWidget {
  final String id;
  final List<VpnProvider>? catalog;
  final ValueChanged<String>? onOpenExternal;
  const ProviderDetailScreen({
    super.key,
    required this.id,
    this.catalog,
    this.onOpenExternal,
  });

  @override
  ConsumerState<ProviderDetailScreen> createState() =>
      _ProviderDetailScreenState();
}

class _ProviderDetailScreenState extends ConsumerState<ProviderDetailScreen> {
  bool _addingFreeServer = false;

  Future<void> _addFreeServer(bool ru) async {
    if (_addingFreeServer) return;
    setState(() => _addingFreeServer = true);
    try {
      await ref.read(subscriptionsProvider.notifier).addBuiltInFreeServer();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ru ? 'Не удалось добавить сервер' : 'Could not add server',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _addingFreeServer = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(stringsProvider).locale;
    final ru = locale == 'ru';
    final provider = (widget.catalog ?? ProviderCatalog.all)
        .where((p) => p.id == widget.id)
        .firstOrNull;
    if (provider == null) {
      return Scaffold(
        appBar: AppBar(title: Text(ru ? 'Сервис' : 'Provider')),
        body: Center(
          child: Text(ru ? 'Сервис не найден' : 'Provider not found'),
        ),
      );
    }
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final priceLabel = provider.pricing.priceLabelForLocale(locale);
    final trialDescription = provider.pricing.trialDescriptionForLocale(locale);
    final features = provider.featuresForLocale(locale);
    final isHoney = provider.id == 'honeyvpn';
    final hasFreeServer =
        isHoney && ref.watch(builtInFreeServerPresentProvider);
    final serversLoaded =
        !isHoney || ref.watch(serversNotifierProvider).hasValue;
    return Scaffold(
      appBar: AppBar(title: Text(provider.name)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 44,
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
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (priceLabel != null)
                              Text(
                                priceLabel,
                                style: theme.textTheme.titleMedium,
                              ),
                            const SizedBox(height: 4),
                            Text(
                              _summary(provider, locale),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ru ? 'Протоколы' : 'Protocols',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: provider.protocols
                            .map((p) => Chip(label: Text(p)))
                            .toList(),
                      ),
                      if (provider.countryCount > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          ru
                              ? 'Стран: ${provider.countryCount}'
                              : '${provider.countryCount} countries',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (features.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          shape: const Border(),
                          collapsedShape: const Border(),
                          title: Text(
                            ru ? 'Подробнее о сервисе' : 'Provider details',
                            style: theme.textTheme.bodyMedium,
                          ),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: features
                                    .map((f) => Chip(label: Text(f)))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (trialDescription != null) ...[
                Text(
                  trialDescription.replaceAll('🎁', '').trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      if (widget.onOpenExternal != null) {
                        widget.onOpenExternal!(provider.referralUrl);
                      } else {
                        launchUrl(
                          Uri.parse(provider.referralUrl),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(
                      Uri.tryParse(provider.referralUrl)?.host == 't.me'
                          ? (ru ? 'Открыть в Telegram' : 'Open in Telegram')
                          : (ru ? 'Открыть сайт' : 'Open website'),
                    ),
                  ),
                  if (isHoney)
                    TextButton.icon(
                      key: const ValueKey('add-built-in-free-server'),
                      onPressed:
                          _addingFreeServer || hasFreeServer || !serversLoaded
                          ? null
                          : () => _addFreeServer(ru),
                      icon: _addingFreeServer
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.add_rounded, size: 18),
                      label: Text(
                        hasFreeServer
                            ? (ru ? 'Сервер добавлен' : 'Server added')
                            : (ru ? 'Добавить сервер' : 'Add server'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _summary(VpnProvider provider, String locale) =>
      switch (provider.id) {
        'honeyvpn' =>
          locale == 'ru'
              ? 'VLESS и Hysteria2. Подключение через Telegram.'
              : 'VLESS and Hysteria2. Set up through Telegram.',
        'alphavpn' =>
          locale == 'ru'
              ? 'AmneziaWG. Серверы во Франции и Германии.'
              : 'AmneziaWG. Servers in France and Germany.',
        _ => provider.shortDescriptionForLocale(locale),
      };
}
