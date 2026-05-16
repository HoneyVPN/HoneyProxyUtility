import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import '../widgets/protocol_chip.dart';
import '../widgets/latency_badge.dart';

class ServerDetailScreen extends ConsumerWidget {
  final String id;
  const ServerDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iid = int.tryParse(id) ?? 0;
    final server = ref.watch(serversNotifierProvider).value
        ?.where((s) => s.id == iid).firstOrNull;

    if (server == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Server')),
        body: const Center(child: Text('Server not found')),
      );
    }
    return _ServerDetailView(server: server);
  }
}

class _ServerDetailView extends StatelessWidget {
  final ServerProfileModel server;
  const _ServerDetailView({required this.server});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(server.name.isNotEmpty ? server.name : server.host)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ProtocolChip(protocol: server.protocol),
                  const SizedBox(height: 12),
                  _DetailRow('Host', server.host),
                  _DetailRow('Port', server.port.toString()),
                  _DetailRow('Protocol', server.protocol.toUpperCase()),
                  if (server.latencyMs != null)
                    _DetailRow('Latency', '${server.latencyMs!.toStringAsFixed(0)} ms'),
                  _DetailRow('Added', _formatDate(server.addedAt)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.day}.${d.month.toString().padLeft(2,'0')}.${d.year}';
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
          SizedBox(width: 80, child: Text(label, style: TextStyle(color: cs.onSurface.withOpacity(0.6), fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13))),
        ],
      ),
    );
  }
}
