import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../../../app/app_theme.dart";

class UrlSchemesScreen extends StatelessWidget {
  const UrlSchemesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("URL Schemes")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _InfoCard(
            icon: Icons.link_rounded,
            color: NexPalette.accent,
            title: "Автоимпорт конфига",
            body: "Внешние приложения (Telegram-боты, браузер, QR-коды) могут "
                "открыть HoneyProxy и автоматически добавить сервер или подписку "
                "одной ссылкой.",
          ),
          const SizedBox(height: 16),

          _SectionLabel("Схема honeyvpn://import"),
          const SizedBox(height: 8),
          _SchemeCard(
            scheme: "honeyvpn://import?url=ССЫЛКА",
            description: "Открывает приложение и импортирует VPN-ссылку или URL подписки.\n"
                "ССЫЛКА должна быть URL-encoded.",
            examples: const [
              _Example(
                label: "Одиночный сервер (vless):",
                value: "honeyvpn://import?url=vless%3A%2F%2Fuuid%40host.com%3A443%3Fsecurity%3Dreality%23MyServer",
              ),
              _Example(
                label: "Подписка:",
                value: "honeyvpn://import?url=https%3A%2F%2Fsub.example.com%2Fconfig%3Ftoken%3Dabc",
              ),
            ],
          ),

          const SizedBox(height: 20),
          _SectionLabel("Для Telegram-бота"),
          const SizedBox(height: 8),
          _InfoCard(
            icon: Icons.telegram,
            color: const Color(0xFF2AABEE),
            title: "Кнопка «Подключить»",
            body: "В BotFather создайте inline-кнопку с URL:\n\n"
                "honeyvpn://import?url={url_encoded_config}\n\n"
                "При нажатии Android откроет HoneyProxy и автоматически добавит сервер.",
          ),

          const SizedBox(height: 20),
          _SectionLabel("Как закодировать ссылку"),
          const SizedBox(height: 8),
          _InfoCard(
            icon: Icons.code_rounded,
            color: cs.primary,
            title: "URL-encoding",
            body: "Python:\n"
                "  from urllib.parse import quote\n"
                "  url = quote(\"vless://...\", safe=\"\")\n\n"
                "JavaScript:\n"
                "  const url = encodeURIComponent(\"vless://...\")\n\n"
                "Итоговая ссылка:\n"
                "  honeyvpn://import?url=\" + url",
          ),
        ],
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
  const _InfoCard({required this.icon, required this.color, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
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
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5)),
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
  const _SchemeCard({required this.scheme, required this.description, required this.examples});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexPalette.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexPalette.accent.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CopyRow(text: scheme, isScheme: true),
          const SizedBox(height: 8),
          Text(description, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5)),
          if (examples.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            for (final ex in examples) ...[
              Text(ex.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
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
          color: cs.surfaceContainerHighest.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outline.withOpacity(0.15)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: widget.isScheme ? 12 : 10,
                  fontFamily: "monospace",
                  color: widget.isScheme ? NexPalette.accent : cs.onSurfaceVariant,
                  fontWeight: widget.isScheme ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 15,
              color: _copied ? NexColors.connected : cs.onSurfaceVariant.withOpacity(0.5),
            ),
          ],
        ),
      ),
    );
  }
}
