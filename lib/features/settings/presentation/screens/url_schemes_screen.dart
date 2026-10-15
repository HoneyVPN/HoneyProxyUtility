import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../../app/l10n/strings.dart";

import "../../../../app/app_theme.dart";

class UrlSchemesScreen extends ConsumerWidget {
  const UrlSchemesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    return Scaffold(
      appBar: AppBar(title: Text(strings.urlSchemesScreenTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _InfoCard(
                icon: Icons.link_rounded,
                color: cs.primary,
                title: ru ? 'Импорт по ссылке' : 'Import from a link',
                body: ru
                    ? 'На Android, Windows и macOS ссылка открывает предпросмотр. Нажмите «Добавить» для сохранения. Версия для iPhone пока недоступна.'
                    : 'On Android, Windows and macOS, the link opens a preview. Choose Add to save it. An iPhone version is not available yet.',
              ),
              const SizedBox(height: 16),
              const _SectionLabel('honeyvpn://import'),
              const SizedBox(height: 8),
              _SchemeCard(
                scheme: 'honeyvpn://import?url=URL_ENCODED_LINK',
                description: ru
                    ? 'Параметр url — VPN-ссылка или HTTPS-адрес подписки, закодированный с помощью URL-encoding.'
                    : 'The url parameter is a VPN link or HTTPS subscription address encoded with URL encoding.',
                examples: [
                  _Example(
                    label: ru ? 'Сервер VLESS' : 'VLESS server',
                    value:
                        'honeyvpn://import?url=vless%3A%2F%2F00000000-0000-4000-8000-000000000000%40example.com%3A443%3Fsecurity%3Dtls%26type%3Dtcp%23Example',
                  ),
                  _Example(
                    label: ru ? 'Подписка' : 'Subscription',
                    value:
                        'honeyvpn://import?url=https%3A%2F%2Fsub.example.com%2Fconfig',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _InfoCard(
                icon: Icons.code_rounded,
                color: cs.primary,
                title: ru ? 'Для разработчиков' : 'For developers',
                body:
                    'Python: quote(link, safe="")\nJavaScript: encodeURIComponent(link)\n\nhoneyvpn://import?url={encoded_link}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Example {
  final String label;
  final String value;
  const _Example({required this.label, required this.value});
}

class _SchemeCard extends StatelessWidget {
  final String scheme;
  final String description;
  final List<_Example> examples;
  const _SchemeCard({
    required this.scheme,
    required this.description,
    required this.examples,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexPalette.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexPalette.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CopyRow(text: scheme, isScheme: true),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (examples.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            for (final ex in examples) ...[
              Text(
                ex.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              _CopyRow(text: ex.value, isScheme: false),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }
}

class _CopyRow extends StatefulWidget {
  final String text;
  final bool isScheme;
  const _CopyRow({required this.text, required this.isScheme});

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _copy,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outline.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: widget.isScheme ? 12 : 10,
                  fontFamily: "monospace",
                  color: widget.isScheme
                      ? NexPalette.accent
                      : cs.onSurfaceVariant,
                  fontWeight: widget.isScheme
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 15,
              color: _copied
                  ? NexColors.connected
                  : cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}
