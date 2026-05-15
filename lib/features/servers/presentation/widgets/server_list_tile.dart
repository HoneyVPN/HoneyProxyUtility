import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import 'latency_badge.dart';
import 'protocol_chip.dart';

String _countryCode(String name) {
  final runes = name.runes.toList();
  if (runes.length >= 2 &&
      runes[0] >= 0x1F1E6 && runes[0] <= 0x1F1FF &&
      runes[1] >= 0x1F1E6 && runes[1] <= 0x1F1FF) {
    return String.fromCharCode(runes[0] - 0x1F1E6 + 65) +
        String.fromCharCode(runes[1] - 0x1F1E6 + 65);
  }
  return '';
}

String _stripFlag(String name) {
  final runes = name.runes.toList();
  if (runes.length >= 2 &&
      runes[0] >= 0x1F1E6 && runes[0] <= 0x1F1FF &&
      runes[1] >= 0x1F1E6 && runes[1] <= 0x1F1FF) {
    var i = 2;
    if (runes.length > i && runes[i] == 32) i++;
    return String.fromCharCodes(runes.sublist(i));
  }
  return name;
}

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
    final code = _countryCode(server.name);
    final displayName = code.isNotEmpty
        ? _stripFlag(server.name)
        : (server.name.isNotEmpty ? server.name : server.host);

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
            const SizedBox(width: 8),
            if (code.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: CountryFlag.fromCountryCode(code, height: 14, width: 20),
              ),
              const SizedBox(width: 6),
            ] else
              const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      fontSize: 15,
                      color: cs.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 52,
              child: Align(
                alignment: Alignment.centerRight,
                child: _pinging
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : GestureDetector(
                        onTap: _ping,
                        child: server.latencyMs != null
                            ? LatencyBadge(ms: server.latencyMs!)
                            : Icon(Icons.network_ping_outlined, size: 17,
                                color: cs.onSurfaceVariant.withOpacity(0.4)),
                      ),
              ),
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
