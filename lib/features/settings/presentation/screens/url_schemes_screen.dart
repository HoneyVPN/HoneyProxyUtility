import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';

class UrlSchemesScreen extends ConsumerWidget {
  const UrlSchemesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final ru = s.locale == 'ru';

    return Scaffold(
      appBar: AppBar(title: Text(s.urlSchemesScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _InfoBanner(
            ru
              ? 'VPN-провайдеры и внешние приложения могут открывать HoneyProxyUtility '
                'напрямую через эти URL-схемы.'
              : 'VPN providers and external apps can deep-link directly into '
                'HoneyProxyUtility using these URL schemes.',
          ),
          const SizedBox(height: 4),

          _SectionLabel(ru ? 'Схема honey:// (мобильный)' : 'honey:// Scheme (Mobile)'),
          _SchemeRow(
            scheme: 'honey://connect',
            description: ru ? 'Подключить VPN с текущим сервером' : 'Connect VPN with current server',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: 'honey://disconnect',
            description: ru ? 'Отключить VPN' : 'Disconnect VPN',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: 'honey://toggle',
            description: ru ? 'Переключить подключение' : 'Toggle connection on/off',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: 'honey://add{encoded_url}',
            description: ru
                ? 'Импортировать ссылку прокси или URL подписки (URL-encoded)'
                : 'Import a proxy link or subscription URL (URL-encoded)',
            example: 'honey://addvless%3A%2F%2Fuuid%40host%3A443',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: 'honey://routing/add/{base64}',
            description: ru
                ? 'Добавить правила маршрутизации (base64)'
                : 'Add routing rules (base64-encoded rule list)',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: 'honey://routing/off',
            description: ru
                ? 'Отключить пользовательские правила маршрутизации'
                : 'Disable custom routing rules',
            copied: s.copied,
          ),

          const Divider(height: 24),
          _SectionLabel(ru ? 'Параметры веб-запроса' : 'Web Query Parameters'),
          _SchemeRow(
            scheme: '?import={url}',
            description: ru
                ? 'Открыть экран импорта с заполненным URL'
                : 'Open Import screen with URL pre-filled',
            example: 'https://app.honeyvpn.ru/?import=https%3A%2F%2Fsub.example.com%2Fconfig',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: '?action=connect',
            description: ru
                ? 'Подключить VPN при открытии приложения'
                : 'Trigger VPN connect on app open',
            copied: s.copied,
          ),
          _SchemeRow(
            scheme: '?action=add&url={encoded}',
            description: ru
                ? 'Открыть импорт с URL (веб-аналог honey://add)'
                : 'Open Import screen with URL (web equivalent of honey://add)',
            copied: s.copied,
          ),

          const Divider(height: 24),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NexColors.connecting.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexColors.connecting.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.integration_instructions_outlined,
                        color: NexColors.connecting, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      s.urlSchemesForProviders,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: cs.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  ru
                    ? 'Чтобы добавить кнопку импорта в один клик на ваш сайт:\n\n'
                      '1. URL-encode вашу ссылку на подписку\n'
                      '2. Добавьте: honey://add{encoded_link}\n'
                      '3. Разместите ссылку в вашей панели управления\n\n'
                      'Пользователи с установленным HoneyProxyUtility импортируют '
                      'вашу подписку в один клик.'
                    : 'To add a one-tap import button to your website:\n\n'
                      '1. URL-encode your subscription link\n'
                      '2. Append it: honey://add{encoded_link}\n'
                      '3. Link to it from your customer dashboard\n\n'
                      'Users with HoneyProxyUtility installed will import your '
                      'subscription in one tap.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.55),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SchemeRow extends StatelessWidget {
  final String scheme;
  final String description;
  final String? example;
  final String copied;

  const _SchemeRow({
    required this.scheme,
    required this.description,
    required this.copied,
    this.example,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withOpacity(0.1)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: NexPalette.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      scheme,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: NexPalette.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (example != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'e.g. $example',
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant.withOpacity(0.6)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 16),
              color: cs.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              tooltip: copied,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: example ?? scheme));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(copied),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                    width: 140,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
