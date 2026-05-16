import 'package:flutter/material.dart';

import '../../domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/widgets/protocol_chip.dart';

class ParsedResultCard extends StatelessWidget {
  final ParsedProxy proxy;
  final VoidCallback onImport;

  const ParsedResultCard({super.key, required this.proxy, required this.onImport});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ProtocolChip(protocol: proxy.protocolLabel.toLowerCase()),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    proxy.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${proxy.host}:${proxy.port}',
                    style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.55)),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onImport,
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}
