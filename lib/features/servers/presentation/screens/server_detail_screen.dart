import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import '../widgets/country_presentation.dart';
import '../../../../app/l10n/strings.dart';

class ServerDetailScreen extends ConsumerWidget {
  final String id;
  const ServerDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    final iid = int.tryParse(id) ?? 0;
    final server = ref
        .watch(serversNotifierProvider)
        .value
        ?.where((s) => s.id == iid)
        .firstOrNull;

    if (server == null) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.serverDetails)),
        body: Center(child: Text(ru ? 'Сервер не найден' : 'Server not found')),
      );
    }
    return _ServerDetailView(server: server, ru: ru);
  }
}

class _ServerDetailView extends StatelessWidget {
  final ServerProfileModel server;
  final bool ru;
  const _ServerDetailView({required this.server, required this.ru});

  @override
  Widget build(BuildContext context) {
    final country = CountryPresentation.fromName(
      server.name,
      fallbackName: server.host,
    );
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CountryFlagIcon(presentation: country),
            const SizedBox(width: 10),
            Flexible(child: Text(country.displayName)),
          ],
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _DetailRow(ru ? 'Адрес' : 'Host', server.host),
                      _DetailRow(ru ? 'Порт' : 'Port', server.port.toString()),
                      _DetailRow(
                        ru ? 'Протокол' : 'Protocol',
                        server.protocol.toUpperCase(),
                      ),
                      if (server.latencyMs != null)
                        _DetailRow(
                          ru ? 'Задержка' : 'Latency',
                          server.latencyMs! < 0 || !server.latencyMs!.isFinite
                              ? (ru ? 'Недоступна' : 'Unavailable')
                              : '${server.latencyMs!.toStringAsFixed(0)} ${ru ? 'мс' : 'ms'}',
                        ),
                      _DetailRow(
                        ru ? 'Добавлен' : 'Added',
                        _formatDate(server.addedAt),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.day}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
