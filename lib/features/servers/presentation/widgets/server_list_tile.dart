import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import 'latency_badge.dart';
import 'country_presentation.dart';
import 'server_connection_label.dart';

enum _ServerAction { favorite, details, ping, delete }

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
  var _pinging = false;
  var _favoriting = false;
  ServerProfileModel? _menuServer;

  Future<void> _setFavorite(ServerProfileModel expected) async {
    if (_favoriting) return;
    setState(() => _favoriting = true);
    try {
      final saved = await ref
          .read(serversNotifierProvider.notifier)
          .setFavoriteIfCurrent(expected, !expected.isFavorite);
      if (!saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.read(stringsProvider).favoriteServerChanged),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.read(stringsProvider).favoriteUpdateFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _favoriting = false);
    }
  }

  Future<void> _ping() async {
    if (_pinging) return;
    setState(() => _pinging = true);
    try {
      await ref
          .read(serversNotifierProvider.notifier)
          .testLatency(widget.server);
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final server = widget.server;
    final country = CountryPresentation.fromName(
      server.name,
      fallbackName: server.host,
    );
    final name = country.displayName;
    final batchPinging = ref.watch(
      latencyTestProgressProvider.select(
        (progress) => progress.activeIds.contains(server.id),
      ),
    );
    final pinging = _pinging || batchPinging;
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = MediaQuery.sizeOf(context).width >= 700;
        return Semantics(
          container: true,
          button: true,
          selected: widget.isSelected,
          value: server.isFavorite ? s.favoriteServer : null,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onTapDetail,
            focusColor: cs.primary.withValues(alpha: 0.12),
            child: Container(
              decoration: BoxDecoration(
                color: widget.isSelected
                    ? cs.primary.withValues(alpha: 0.065)
                    : null,
                borderRadius: BorderRadius.circular(7),
              ),
              padding: EdgeInsets.fromLTRB(
                10,
                desktop ? 3 : 5,
                2,
                desktop ? 3 : 5,
              ),
              child: Row(
                children: [
                  CountryFlagIcon(presentation: country),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: widget.isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          ServerConnectionLabel.fromProfile(server),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (server.isFavorite) ...[
                    Tooltip(
                      message: s.favoriteServer,
                      excludeFromSemantics: true,
                      child: Icon(
                        Icons.star_rounded,
                        size: 13,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (server.protocol != 'awg')
                    pinging
                        ? const RepaintBoundary(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : server.latencyMs != null
                        ? LatencyBadge(ms: server.latencyMs!)
                        : const SizedBox.shrink(),
                  PopupMenuButton<_ServerAction>(
                    key: ValueKey('server-actions-${server.id}'),
                    tooltip: s.serverActions,
                    style: IconButton.styleFrom(
                      minimumSize: Size.square(desktop ? 30 : 44),
                      maximumSize: Size.square(desktop ? 30 : 44),
                      padding: const EdgeInsets.all(6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 17,
                      color: cs.onSurfaceVariant,
                    ),
                    onOpened: () => _menuServer = widget.server,
                    onCanceled: () => _menuServer = null,
                    onSelected: (action) {
                      final expected = _menuServer ?? server;
                      _menuServer = null;
                      switch (action) {
                        case _ServerAction.favorite:
                          _setFavorite(expected);
                        case _ServerAction.details:
                          widget.onTapDetail();
                        case _ServerAction.ping:
                          _ping();
                        case _ServerAction.delete:
                          widget.onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        height: desktop ? 34 : 44,
                        value: _ServerAction.favorite,
                        enabled: !_favoriting,
                        child: Row(
                          children: [
                            Icon(
                              server.isFavorite
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              size: 17,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                server.isFavorite
                                    ? s.removeFromFavorites
                                    : s.addToFavorites,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        height: desktop ? 34 : 44,
                        value: _ServerAction.details,
                        child: Text(s.serverDetails),
                      ),
                      if (server.protocol != 'awg')
                        PopupMenuItem(
                          height: desktop ? 34 : 44,
                          value: _ServerAction.ping,
                          enabled: !pinging,
                          child: Text(s.pingServer),
                        ),
                      PopupMenuItem(
                        height: desktop ? 34 : 44,
                        value: _ServerAction.delete,
                        child: Text(
                          s.deleteButton,
                          style: TextStyle(color: cs.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
