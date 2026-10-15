import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../../servers/data/models/server_profile_model.dart';
import '../../../servers/presentation/widgets/country_presentation.dart';

class ServerSelectorChip extends ConsumerWidget {
  final ServerProfileModel? server;
  final VoidCallback onTap;
  final String? labelOverride;

  const ServerSelectorChip({
    super.key,
    required this.server,
    required this.onTap,
    this.labelOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final desktop = MediaQuery.sizeOf(context).width >= 700;
    final current = server;
    final country = CountryPresentation.fromName(
      current?.name ?? '',
      fallbackName: current?.host ?? '',
    );
    final title =
        labelOverride ??
        (current == null ? s.chooseServer : country.displayName);
    return Semantics(
      container: true,
      button: true,
      label: title,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          key: const ValueKey('selected-server-control'),
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: desktop ? 8 : 14,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CountryFlagIcon(presentation: country),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
