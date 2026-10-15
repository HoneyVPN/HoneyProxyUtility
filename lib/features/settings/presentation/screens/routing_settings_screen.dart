import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../../../app/app_theme.dart';
import '../../data/models/app_settings.dart';
import '../notifiers/settings_notifier.dart';
import '../widgets/settings_save_feedback.dart';
import '../../../subscriptions/data/services/subscriptions_notifier.dart';
import '../../../subscriptions/presentation/widgets/subscription_refresh_action.dart';
import '../../../subscriptions/domain/entities/provider_geo_state.dart';

class RoutingSettingsScreen extends ConsumerWidget {
  const RoutingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final storedMode = settings.routingMode;
    final mode = storedMode == RoutingMode.rules
        ? RoutingMode.bypassRU
        : storedMode;
    const modes = [RoutingMode.global, RoutingMode.bypassRU];
    final s = ref.watch(stringsProvider);
    final cs = Theme.of(context).colorScheme;
    final geoRows =
        ref
            .watch(subscriptionsProvider)
            .value
            ?.subs
            .where((sub) => sub.providerGeoStatus != ProviderGeoStatus.absent)
            .toList() ??
        [];
    return Scaffold(
      appBar: AppBar(title: Text(s.routingScreenTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Material(
                color: cs.surface,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: RadioGroup<RoutingMode>(
                  groupValue: mode,
                  onChanged: (value) {
                    if (value != null) {
                      saveSettingsWithFeedback(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setRouting(value),
                        s.settingsSaveFailed,
                      );
                    }
                  },
                  child: Column(
                    children: [
                      for (var i = 0; i < modes.length; i++) ...[
                        if (i > 0) const Divider(height: 0.5, indent: 12),
                        RadioListTile<RoutingMode>(
                          value: modes[i],
                          dense: true,
                          controlAffinity: ListTileControlAffinity.trailing,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          title: Text(
                            s.routingModeLabel(modes[i].name),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          subtitle: Text(
                            s.routingModeDescription(modes[i].name),
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  s.geoRoutingTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Material(
                color: cs.surface,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: RadioGroup<GeoRoutingMode>(
                  groupValue: settings.geoRoutingMode,
                  onChanged: (value) {
                    if (value != null && mode != RoutingMode.global) {
                      saveSettingsWithFeedback(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setGeoRoutingMode(value),
                        s.settingsSaveFailed,
                      );
                    }
                  },
                  child: Column(
                    children: [
                      for (final geoMode in GeoRoutingMode.values) ...[
                        if (geoMode != GeoRoutingMode.values.first)
                          const Divider(height: 0.5, indent: 12),
                        RadioListTile<GeoRoutingMode>(
                          value: geoMode,
                          enabled: mode != RoutingMode.global,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.trailing,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          title: Text(switch (geoMode) {
                            GeoRoutingMode.builtIn => s.geoRoutingBuiltIn,
                            GeoRoutingMode.provider => s.geoRoutingProvider,
                            GeoRoutingMode.combined => s.geoRoutingCombined,
                          }),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: Text(
                  mode == RoutingMode.global
                      ? s.geoRoutingGlobal
                      : switch (settings.geoRoutingMode) {
                          GeoRoutingMode.builtIn =>
                            s.geoRoutingBuiltInDescription,
                          GeoRoutingMode.provider => s.geoRoutingOptional,
                          GeoRoutingMode.combined => s.geoRoutingPriority,
                        },
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              for (final sub in geoRows)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: Text(
                    sub.name.isEmpty
                        ? Uri.tryParse(sub.url)?.host ?? ''
                        : sub.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(switch (sub.providerGeoStatus) {
                    ProviderGeoStatus.ready => s.providerGeoReady,
                    ProviderGeoStatus.updating => s.providerGeoUpdating,
                    ProviderGeoStatus.stale ||
                    ProviderGeoStatus.unavailable => s.providerGeoWarning(
                      sub.providerGeoIssue,
                      hasLastGood: sub.providerGeo != null,
                    ),
                    ProviderGeoStatus.off => s.providerGeoOff,
                    _ => s.providerGeoUnavailable,
                  }),
                  leading: sub.providerGeoStatus == ProviderGeoStatus.updating
                      ? const RefreshingSyncIcon(running: true, size: 20)
                      : Icon(
                          switch (sub.providerGeoStatus) {
                            ProviderGeoStatus.ready => Icons.public_rounded,
                            ProviderGeoStatus.updating => Icons.sync_rounded,
                            ProviderGeoStatus.off => Icons.public_off_rounded,
                            _ => Icons.warning_rounded,
                          },
                          size: 20,
                          color:
                              sub.providerGeoStatus ==
                                      ProviderGeoStatus.stale ||
                                  sub.providerGeoStatus ==
                                      ProviderGeoStatus.unavailable
                              ? NexColors.warningFor(
                                  Theme.of(context).brightness,
                                )
                              : cs.onSurfaceVariant,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
