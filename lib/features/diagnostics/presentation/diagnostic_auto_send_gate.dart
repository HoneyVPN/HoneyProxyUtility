import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/strings.dart';
import '../../connection/domain/entities/connection_state.dart';
import '../../connection/presentation/notifiers/connection_notifier.dart';
import '../../servers/presentation/notifiers/servers_notifier.dart';
import '../../settings/data/models/app_settings.dart';
import '../../settings/presentation/notifiers/settings_notifier.dart';
import '../../subscriptions/data/services/subscriptions_notifier.dart';
import '../data/diagnostic_auto_send.dart';
import '../data/diagnostic_report.dart';
import '../data/diagnostic_upload.dart';

// A standalone screen or web preview has no automatic sender. The real app
// supplies its one lifecycle-bound controller to the navigation subtree.
final diagnosticAutoControllerProvider =
    Provider<DiagnosticAutoSendController?>((_) => null);

final diagnosticAutoConsentProvider = StreamProvider<DiagnosticAutoConsent>((
  ref,
) async* {
  final controller = ref.watch(diagnosticAutoControllerProvider);
  if (controller == null) {
    yield const DiagnosticAutoConsent(asked: true);
    return;
  }
  await controller.initialize();
  yield controller.consent;
  yield* controller.consentChanges;
}, dependencies: [diagnosticAutoControllerProvider]);

Future<bool> showAutomaticDiagnosticConsent(
  BuildContext context, {
  required bool ru,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(ru ? 'Помочь исправлять ошибки?' : 'Help us fix errors?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ru
                  ? 'Разрешить HoneyProxyUtility автоматически отправлять очищенные технические отчёты при ошибках?'
                  : 'Allow HoneyProxyUtility to automatically send redacted technical reports when errors occur?',
            ),
            const SizedBox(height: 12),
            Text(
              ru
                  ? 'Отчёт включает версию приложения, состояние VPN, технические настройки и последние события. Подписки, ключи доступа, историю посещений и содержимое трафика приложение в отчёт не добавляет. Очистка текста не гарантирует удаления любых личных сведений.'
                  : 'Reports include the app version, VPN state, technical settings and recent events. The app does not add subscription URLs, access keys, browsing history or traffic contents to reports. Text redaction cannot guarantee removal of every personal detail.',
            ),
            const SizedBox(height: 12),
            Text(
              ru
                  ? 'Получатель — поддержка Honey: api.honeyvpn.ru, по HTTPS. Не более трёх отчётов за 24 часа. В хранилище поддержки записи старше семи суток удаляются. Можно отказаться сейчас или выключить автоотправку в настройках в любой момент.'
                  : 'Reports go to Honey support at api.honeyvpn.ru over HTTPS, at most three per 24 hours. Reports older than seven days are removed from support storage. You can decline now or turn automatic reporting off in Settings at any time.',
            ),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(
                  'https://api.honeyvpn.ru/privacy#${ru ? 'ru' : 'en'}',
                ),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.privacy_tip_outlined, size: 18),
              label: Text(
                ru ? 'Политика конфиденциальности' : 'Privacy policy',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ru ? 'Нет, спасибо' : 'No, thanks'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              ru ? 'Разрешить автоотправку' : 'Allow automatic reports',
            ),
          ),
        ],
      ),
    ) ??
    false;

class DiagnosticAutoSendGate extends ConsumerStatefulWidget {
  const DiagnosticAutoSendGate({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<DiagnosticAutoSendGate> createState() =>
      _DiagnosticAutoSendGateState();
}

class _DiagnosticAutoSendGateState extends ConsumerState<DiagnosticAutoSendGate>
    with WidgetsBindingObserver {
  DiagnosticAutoSendController? _controller;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    if (kIsWeb ||
        !const {
          TargetPlatform.android,
          TargetPlatform.windows,
        }.contains(defaultTargetPlatform)) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _controller = DiagnosticAutoSendController(
      buildReport: _cachedReport,
      uploader: ref.read(diagnosticUploaderProvider),
      isForeground: () => mounted && _foreground,
    );
    unawaited(_initialize());
  }

  // Observing a failure must not initialize providers that fetch subscriptions
  // or geo data. Missing context makes the redactor omit free text safely.
  Future<DiagnosticReport> _cachedReport() {
    if (!mounted) throw StateError('Automatic diagnostics unavailable');
    final container = ProviderScope.containerOf(context, listen: false);
    final profiles = container.exists(serversNotifierProvider)
        ? ref.read(serversNotifierProvider)
        : null;
    final subscriptions = container.exists(subscriptionsProvider)
        ? ref.read(subscriptionsProvider)
        : null;
    return ref
        .read(diagnosticReportBuilderProvider)
        .build(
          settings: container.exists(settingsProvider)
              ? ref.read(settingsProvider).value ?? const AppSettings()
              : const AppSettings(),
          connection: container.exists(connectionNotifierProvider)
              ? ref.read(connectionNotifierProvider)
              : const NexConnectionState(status: ConnectionStatus.disconnected),
          subscriptions: subscriptions?.value ?? const SubscriptionsState(),
          profiles: profiles?.value ?? [],
          profilesLoaded:
              profiles?.hasValue == true && profiles?.isLoading == false,
          subscriptionsLoaded:
              subscriptions?.hasValue == true &&
              subscriptions?.isLoading == false,
        );
  }

  Future<void> _initialize() async {
    try {
      final controller = _controller!;
      final consent = await controller.initialize();
      if (!mounted || consent.asked) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final dialogContext =
            widget.navigatorKey.currentState?.overlay?.context;
        if (!mounted || !_foreground || dialogContext == null) return;
        try {
          final accepted = await showAutomaticDiagnosticConsent(
            dialogContext,
            ru: ref.read(stringsProvider).locale == 'ru',
          );
          if (!mounted) return;
          if (accepted) {
            await controller.setEnabled(true);
          } else {
            await controller.markAsked();
          }
        } catch (_) {
          // Failed preference storage must never silently enable reporting.
        }
      });
    } catch (_) {
      // Optional diagnostics cannot block startup when storage is unavailable.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : ProviderScope(
          overrides: [
            diagnosticAutoControllerProvider.overrideWithValue(_controller),
          ],
          child: widget.child,
        );
}

class AutomaticDiagnosticsTile extends ConsumerStatefulWidget {
  const AutomaticDiagnosticsTile({super.key});

  @override
  ConsumerState<AutomaticDiagnosticsTile> createState() =>
      _AutomaticDiagnosticsTileState();
}

class _AutomaticDiagnosticsTileState
    extends ConsumerState<AutomaticDiagnosticsTile> {
  bool _saving = false;

  Future<void> _change(bool enabled) async {
    final controller = ref.read(diagnosticAutoControllerProvider);
    if (_saving || controller == null) return;
    setState(() => _saving = true);
    try {
      if (enabled) {
        final accepted = await showAutomaticDiagnosticConsent(
          context,
          ru: ref.read(stringsProvider).locale == 'ru',
        );
        if (!mounted) return;
        if (!accepted) {
          await controller.markAsked();
          return;
        }
      }
      await controller.setEnabled(enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ref.read(stringsProvider).settingsSaveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(diagnosticAutoControllerProvider);
    final state = ref.watch(diagnosticAutoConsentProvider);
    final ru = ref.watch(stringsProvider).locale == 'ru';
    final enabled = state.value?.enabled ?? false;
    final reportId = controller?.lastAcceptedReportId;
    return Column(
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.bug_report_outlined),
          title: Text(
            ru ? 'Автоматическая диагностика' : 'Automatic diagnostics',
          ),
          subtitle: Text(
            ru
                ? 'При ошибках отправлять очищенные отчёты в поддержку Honey. Не более трёх за 24 часа.'
                : 'Send redacted error reports to Honey support. At most three per 24 hours.',
          ),
          value: enabled,
          onChanged: controller == null || state.isLoading || _saving
              ? null
              : _change,
        ),
        if (reportId != null)
          ListTile(
            title: Text(ru ? 'Последний отчёт' : 'Latest report'),
            subtitle: SelectableText(reportId),
            trailing: IconButton(
              tooltip: ru ? 'Копировать номер' : 'Copy ID',
              onPressed: () => Clipboard.setData(ClipboardData(text: reportId)),
              icon: const Icon(Icons.copy_outlined),
            ),
          ),
      ],
    );
  }
}
