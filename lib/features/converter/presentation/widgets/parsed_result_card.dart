import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/widgets/country_presentation.dart';
import '../../../servers/presentation/widgets/server_connection_label.dart';

class ParsedResultCard extends ConsumerWidget {
  final ParsedProxy proxy;
  final VoidCallback onImport;
  final bool enabled;
  final bool importing;
  final bool primaryAction;

  const ParsedResultCard({
    super.key,
    required this.proxy,
    required this.onImport,
    this.enabled = true,
    this.importing = false,
    this.primaryAction = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final strings = ref.watch(stringsProvider);
    final host = proxy.host.contains(':') && !proxy.host.startsWith('[')
        ? '[${proxy.host}]'
        : proxy.host;
    final endpoint = '$host:${proxy.port}';
    final country = CountryPresentation.fromName(
      proxy.name,
      fallbackName: proxy.host.isNotEmpty ? endpoint : proxy.protocolLabel,
    );
    final actionStyle = ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled) && !importing) return null;
        return primaryAction ? cs.onPrimary : cs.primary;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled) && !importing) return null;
        return primaryAction ? cs.primary : Colors.transparent;
      }),
      minimumSize: const WidgetStatePropertyAll(Size.square(44)),
      maximumSize: const WidgetStatePropertyAll(Size.square(44)),
      fixedSize: const WidgetStatePropertyAll(Size.square(44)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
    final actionIcon = importing
        ? SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: primaryAction ? cs.onPrimary : cs.primary,
            ),
          )
        : const Icon(CupertinoIcons.plus, size: 18);
    final onPressed = enabled && !importing ? onImport : null;
    final add = primaryAction
        ? IconButton.filled(
            key: const ValueKey('import-add-action'),
            onPressed: onPressed,
            style: actionStyle,
            icon: actionIcon,
            tooltip: strings.addButton,
          )
        : IconButton(
            key: const ValueKey('import-add-action'),
            onPressed: onPressed,
            style: actionStyle,
            icon: actionIcon,
            tooltip: strings.addButton,
          );
    final details = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        country.hasFlag
            ? CountryFlagIcon(presentation: country)
            : ExcludeSemantics(
                child: SizedBox(
                  width: 24,
                  height: 20,
                  child: Icon(
                    CupertinoIcons.globe,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: proxy.host.isNotEmpty ? endpoint : country.displayName,
                child: Text(
                  country.displayName,
                  style: textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    height: 1.3,
                    leadingDistribution: TextLeadingDistribution.even,
                    color: cs.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                ServerConnectionLabel.fromProxy(proxy),
                style: textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  letterSpacing: 0,
                  height: 1.3,
                  leadingDistribution: TextLeadingDistribution.even,
                  color: cs.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
            // The compact action leaves room for the name on narrow screens.
            final stacked = constraints.maxWidth < 90 + 90 * scale;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  details,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: add),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 12),
                add,
              ],
            );
          },
        ),
      ),
    );
  }
}
