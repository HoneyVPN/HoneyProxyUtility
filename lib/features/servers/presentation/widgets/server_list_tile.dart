import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import 'latency_badge.dart';
import 'protocol_chip.dart';

class ServerListTile extends ConsumerStatefulWidget {
  final ServerProfileModel server;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onTapDetail;

  const ServerListTile({
    super.key,
    required this.server,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    required this.onTapDetail,
  });

  @override
  ConsumerState<ServerListTile> createState() => _ServerListTileState();
}

class _ServerListTileState extends ConsumerState<ServerListTile> {
  bool _pinging = false;

  Future<void> _ping() async {
    if (_pinging) return;
    setState(() => _pinging = true);
    await ref.read(serversNotifierProvider.notifier).testLatency(widget.server);
    if (mounted) setState(() => _pinging = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final server = widget.server;
    final selected = widget.isSelected;

    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onTapDetail,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: selected ? NexPalette.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            ProtocolChip(protocol: server.protocol),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.name.isNotEmpty ? server.name : server.host,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      fontSize: 15,
                      color: selected ? cs.onSurface : cs.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_pinging)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.onSurfaceVariant),
              )
            else if (server.latencyMs != null && server.latencyMs! >= 0)
              GestureDetector(
                onTap: _ping,
                child: LatencyBadge(ms: server.latencyMs!),
              )
            else
              GestureDetector(
                onTap: _ping,
                child: Icon(Icons.network_ping_outlined, size: 17, color: cs.onSurfaceVariant.withOpacity(0.45)),
              ),
            const SizedBox(width: 8),
            if (selected)
              Icon(Icons.check_circle_rounded, color: NexColors.connected, size: 18),
            if (!selected) const SizedBox(width: 18),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: widget.onDelete,
              child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant.withOpacity(0.35)),
            ),
          ],
        ),
      ),
    );
  }
}
