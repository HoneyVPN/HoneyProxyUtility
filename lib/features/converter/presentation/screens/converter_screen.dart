import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../../../app/app_toast.dart';
import '../widgets/qr_scan_dialog.dart';

import '../../data/parsers/base_parser.dart';
import '../../data/parsers/link_dispatcher.dart';
import '../../data/parsers/subscription_parser.dart';
import '../../data/parsers/provider_routing_parser.dart';
import '../../domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../subscriptions/data/services/subscriptions_notifier.dart';
import '../../../subscriptions/data/services/subscription_policy.dart';
import '../../../../app/l10n/strings.dart';
import '../widgets/parsed_result_card.dart';

final converterDioProvider = Provider<Dio>((ref) {
  final client = Dio();
  ref.onDispose(() => client.close(force: true));
  return client;
});

final _converterStateProvider =
    StateNotifierProvider.autoDispose<_ConverterNotifier, _ConverterState>(
      (ref) => _ConverterNotifier(ref.watch(converterDioProvider)),
    );

class _ConverterState {
  final String text;
  final List<ParsedProxy> results;
  final String? error;
  final bool importing;

  const _ConverterState({
    this.text = '',
    this.results = const [],
    this.error,
    this.importing = false,
  });

  _ConverterState copyWith({
    String? text,
    List<ParsedProxy>? results,
    String? error,
    bool? importing,
  }) => _ConverterState(
    text: text ?? this.text,
    results: results ?? this.results,
    error: error,
    importing: importing ?? this.importing,
  );
}

class _ConverterNotifier extends StateNotifier<_ConverterState> {
  final Dio _dio;
  int _generation = 0;
  CancelToken? _request;
  String? _responseUrl, _responseBody;
  Map<String, List<String>> _responseHeaders = const {};
  (String, Map<String, List<String>>)? responseFor(String url) =>
      _responseUrl == url && _responseBody != null
        ? (_responseBody!, _responseHeaders) : null;
  _ConverterNotifier(this._dio)
    : super(const _ConverterState()); // ignore: deprecated_member_use

  static const _dispatcher = LinkDispatcher();
  static const _subParser = SubscriptionParser();

  void updateText(String text) {
    if (!mounted) return;
    _invalidateRequest();
    state = state.copyWith(
      text: text,
      importing: false,
      error: null,
      results: [],
    );
  }

  Future<void> parse() async {
    if (!mounted) return;
    _invalidateRequest();
    final generation = _generation;
    final text = state.text.replaceAll('\x00', '').trim();
    if (text.isEmpty) return;

    // If it's an HTTP(S) URL — fetch it first
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final request = CancelToken();
      _request = request;
      state = state.copyWith(importing: true, error: null, results: []);
      try {
        // In web mode route through CORS proxy to avoid browser restrictions
        const proxyBase = '/proxy/?url=';
        final fetchUrl = kIsWeb
            ? '$proxyBase${Uri.encodeComponent(text)}'
            : text;
        final resp = await _dio.get<String>(
          fetchUrl,
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 15),
          ),
          cancelToken: request,
        );
        if (!_isCurrent(generation)) return;
        final body = resp.data ?? '';
        var proxyBody = body;
        try {
          proxyBody = const ProviderRoutingParser().parse(subscriptionId: 1,
            body: body, headers: resp.headers.map).proxyBody;
        } on ProviderRoutingParseException { /* Proxy preview remains independent. */ }
        final subs = _subParser.parse(proxyBody);
        if (subs.isEmpty) {
          state = state.copyWith(
            importing: false,
            error: 'subscription_empty',
            results: [],
          );
        } else {
          _responseUrl = normalizeSubscriptionUrl(text);
          _responseBody = body;
          _responseHeaders = Map.unmodifiable({for (final e in resp.headers.map.entries)
            e.key: List<String>.unmodifiable(e.value)});
          state = state.copyWith(importing: false, results: subs, error: null);
        }
      } catch (e) {
        if (!_isCurrent(generation)) return;
        state = state.copyWith(
          importing: false,
          error: e is UnsupportedConfigurationException
              ? 'unsupported_configuration'
              : e is ParseException
              ? 'parse_failed'
              : 'download_failed',
          results: [],
        );
      } finally {
        if (_generation == generation) _request = null;
      }
      return;
    }

    try {
      // Try single proxy link
      if (_dispatcher.canParse(text)) {
        final result = _dispatcher.dispatch(text);
        state = state.copyWith(results: [result], error: null);
        return;
      }
      // Try as subscription content (base64 / YAML / JSON)
      final subs = _subParser.parse(text);
      if (subs.isEmpty) {
        state = state.copyWith(error: 'no_links', results: []);
      } else {
        state = state.copyWith(results: subs, error: null);
      }
    } on UnsupportedConfigurationException {
      state = state.copyWith(error: 'unsupported_configuration', results: []);
    } on ParseException {
      state = state.copyWith(error: 'parse_failed', results: []);
    } on UnsupportedProtocolException {
      state = state.copyWith(error: 'unsupported_protocol', results: []);
    } catch (e) {
      state = state.copyWith(error: 'parse_failed', results: []);
    }
  }

  Future<String?> pasteFromClipboard() async {
    if (!mounted) return null;
    _invalidateRequest();
    final generation = _generation;
    state = state.copyWith(importing: false, error: null, results: []);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!_isCurrent(generation)) return null;
      if (data?.text?.isNotEmpty == true) {
        updateText(data!.text!);
        await parse();
        return null; // success
      }
      return 'clipboard_empty';
    } catch (_) {
      if (!_isCurrent(generation)) return null;
      // Web browsers require focus / explicit permission for clipboard read
      return 'clipboard_denied';
    }
  }

  void setInitialText(String text) {
    if (mounted && text.isNotEmpty) {
      updateText(text);
    }
  }

  bool _isCurrent(int generation) => mounted && _generation == generation;

  void _invalidateRequest() {
    _responseUrl = null;
    _responseBody = null;
    _responseHeaders = const {};

    _generation++;
    _request?.cancel('Import request replaced');
    _request = null;
  }

  @override
  void dispose() {
    _invalidateRequest();
    super.dispose();
  }
}

class ConverterScreen extends ConsumerStatefulWidget {
  final String? initialText; // from URL scheme / deep link
  final String? importActivation;
  const ConverterScreen({super.key, this.initialText, this.importActivation});

  @override
  ConsumerState<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends ConsumerState<ConverterScreen> {
  late final TextEditingController _ctrl;
  int _prefillGeneration = 0;
  final _inputFocus = FocusNode();
  bool _saving = false;
  ParsedProxy? _savingProxy;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    // Handle URL scheme / deep link pre-fill
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _applyInitialText(widget.initialText!);
    } else {
      // Check URL query param ?import=... (web deep link)
      _checkUrlScheme();
    }
  }

  @override
  void didUpdateWidget(covariant ConverterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.initialText;
    if (text == oldWidget.initialText &&
        widget.importActivation == oldWidget.importActivation)
      return;
    _prefillGeneration++;
    if (text != null && text.isNotEmpty) {
      _applyInitialText(text);
    }
  }

  void _applyInitialText(String text) {
    final generation = ++_prefillGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A later link/navigation can replace this frame's queued prefill.
      if (!mounted || generation != _prefillGeneration) return;
      final notifier = ref.read(_converterStateProvider.notifier);
      notifier.setInitialText(text);
      _ctrl.text = text;
      unawaited(notifier.parse());
    });
  }

  void _checkUrlScheme() {
    if (!kIsWeb) return;
    try {
      final importParam = Uri.base.queryParameters['import'];
      if (importParam != null && importParam.isNotEmpty) {
        _applyInitialText(importParam);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(_converterStateProvider);
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    final notifier = ref.read(_converterStateProvider.notifier);

    // Sync controller when state changes externally
    if (_ctrl.text != s.text) {
      _ctrl.text = s.text;
      _ctrl.selection = TextSelection.collapsed(offset: s.text.length);
    }

    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final canContinue = s.text.trim().isNotEmpty && !s.importing && !_saving;
    void continueImport() {
      if (canContinue) {
        _inputFocus.unfocus();
        unawaited(notifier.parse());
      }
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            continueImport,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            continueImport,
      },
      child: Scaffold(
        appBar: AppBar(
          title: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 648),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(strings.importScreenTitle),
              ),
            ),
          ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _ImportInputPanel(
                  controller: _ctrl,
                  focusNode: _inputFocus,
                  strings: strings,
                  hasText: s.text.isNotEmpty,
                  saving: _saving,
                  loading: s.importing,
                  hasPreview: s.results.isNotEmpty,
                  canContinue: canContinue,
                  onChanged: notifier.updateText,
                  onContinue: continueImport,
                  onClear: () {
                    notifier.updateText('');
                    _ctrl.clear();
                    _inputFocus.requestFocus();
                  },
                  onPaste: () => _pasteInput(notifier, ru),
                  onScan: !kIsWeb && (Platform.isAndroid || Platform.isIOS)
                      ? () => _scanInput(notifier)
                      : null,
                ),
                if (s.error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            CupertinoIcons.exclamationmark_circle,
                            color: cs.error,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _importError(s.error!, ru),
                              style: TextStyle(
                                color: cs.onErrorContainer,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (s.results.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        runAlignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              strings.importResultsCount(s.results.length),
                              style: textTheme.labelLarge?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0,
                                height: 1.3,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (s.results.length > 1)
                            IconButton.filled(
                              key: const ValueKey('import-add-all-action'),
                              onPressed: _saving
                                  ? null
                                  : () => _importAll(context, ref, s.results),
                              tooltip: strings.importAllButton,
                              icon: _saving && _savingProxy == null
                                  ? CupertinoActivityIndicator(
                                      radius: 7,
                                      color: cs.onSurfaceVariant,
                                    )
                                  : const Icon(CupertinoIcons.plus, size: 18),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                maximumSize: const Size(44, 44),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.standard,
                                padding: const EdgeInsets.all(10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...s.results.map(
                    (p) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ParsedResultCard(
                        proxy: p,
                        enabled: !_saving,
                        primaryAction: s.results.length == 1,
                        importing: _saving && identical(_savingProxy, p),
                        onImport: () => _importOne(context, ref, p),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteInput(_ConverterNotifier notifier, bool ru) async {
    final err = await notifier.pasteFromClipboard();
    if (err != null && mounted) {
      AppToast.show(context, _importError(err, ru));
    }
  }

  Future<void> _scanInput(_ConverterNotifier notifier) async {
    _inputFocus.unfocus();
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const QrScanDialog(),
    );
    if (!mounted || result == null || result.isEmpty) return;
    notifier.updateText(result);
    _ctrl.text = result;
    unawaited(notifier.parse());
  }

  Future<void> _importOne(
    BuildContext ctx,
    WidgetRef ref,
    ParsedProxy p,
  ) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _savingProxy = p;
    });
    final ru = ref.read(stringsProvider).locale == 'ru';
    final text = normalizeSubscriptionUrl(
      ref.read(_converterStateProvider).text,
    );
    try {
      if (text.startsWith('http://') || text.startsWith('https://')) {
        final response = ref.read(_converterStateProvider.notifier).responseFor(text);
        final subscriptions = ref.read(subscriptionsProvider.notifier);
        await subscriptions.importProxies(text, [p]);
        if (response != null) {
          await subscriptions.adoptProviderResponse(text, response.$1, response.$2);
        }
      } else {
        await ref.read(serversNotifierProvider.notifier).addFromProxy(p);
      }
      if (!ctx.mounted) return;
      AppToast.show(
        ctx,
        ru ? '${p.displayName} добавлен' : '${p.displayName} added',
        actionLabel: ru ? 'Серверы' : 'Servers',
        onAction: () => GoRouter.of(ctx).go('/'),
      );
    } catch (_) {
      if (ctx.mounted)
        AppToast.show(
          ctx,
          ru ? 'Не удалось сохранить сервер' : 'Could not save server',
        );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _savingProxy = null;
        });
      }
    }
  }

  Future<void> _importAll(
    BuildContext ctx,
    WidgetRef ref,
    List<ParsedProxy> proxies,
  ) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _savingProxy = null;
    });
    final ru = ref.read(stringsProvider).locale == 'ru';
    final text = normalizeSubscriptionUrl(
      ref.read(_converterStateProvider).text,
    );
    final subId = (text.startsWith('http://') || text.startsWith('https://'))
        ? text
        : '';
    try {
      int count;
      if (subId.isNotEmpty) {
        final response = ref.read(_converterStateProvider.notifier).responseFor(subId);
        count = await ref
            .read(subscriptionsProvider.notifier)
            .importProxies(subId, proxies);
        if (response != null) {
          await ref.read(subscriptionsProvider.notifier)
            .adoptProviderResponse(subId, response.$1, response.$2);
        }
      } else {
        await ref
            .read(serversNotifierProvider.notifier)
            .addFromProxies(proxies);
        count = subscriptionProxies('', proxies).length;
      }
      if (!ctx.mounted) return;
      AppToast.show(
        ctx,
        ru
            ? 'Импортировано серверов: $count'
            : '$count server${count == 1 ? '' : 's'} imported',
        actionLabel: ru ? 'Серверы' : 'Servers',
        onAction: () => GoRouter.of(ctx).go('/'),
      );
    } catch (_) {
      if (ctx.mounted)
        AppToast.show(
          ctx,
          ru ? 'Не удалось сохранить серверы' : 'Could not save servers',
        );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _savingProxy = null;
        });
      }
    }
  }
}

class _ImportInputPanel extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final S strings;
  final bool hasText;
  final bool saving;
  final bool loading;
  final bool hasPreview;
  final bool canContinue;
  final ValueChanged<String> onChanged;
  final VoidCallback onContinue;
  final VoidCallback onClear;
  final VoidCallback onPaste;
  final VoidCallback? onScan;

  const _ImportInputPanel({
    required this.controller,
    required this.focusNode,
    required this.strings,
    required this.hasText,
    required this.saving,
    required this.loading,
    required this.hasPreview,
    required this.canContinue,
    required this.onChanged,
    required this.onContinue,
    required this.onClear,
    required this.onPaste,
    this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final inputStyle = textTheme.bodyMedium!.copyWith(
      fontSize: 13,
      letterSpacing: 0,
      height: 1.4,
      leadingDistribution: TextLeadingDistribution.even,
      color: cs.onSurface,
    );
    final neutralButtonStyle = TextButton.styleFrom(
      foregroundColor: cs.onSurfaceVariant,
      minimumSize: const Size(44, 44),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      textStyle: textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.3,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    final sources = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        TextButton(
          onPressed: saving ? null : onPaste,
          style: neutralButtonStyle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox.square(
                dimension: 18,
                child: Opacity(
                  opacity: 0.8,
                  child: Icon(CupertinoIcons.doc, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              Text(strings.importPasteButton),
            ],
          ),
        ),
        if (onScan != null)
          IconButton(
            onPressed: saving ? null : onScan,
            tooltip: strings.importScanButton,
            icon: const Icon(CupertinoIcons.qrcode_viewfinder, size: 19),
            style: IconButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.all(10),
            ),
          ),
      ],
    );
    final actionIcon = loading
        ? CupertinoActivityIndicator(radius: 7, color: cs.onSurfaceVariant)
        : Icon(
            hasPreview
                ? CupertinoIcons.arrow_clockwise
                : CupertinoIcons.arrow_right,
            size: 16,
          );
    const actionKey = ValueKey('import-preview-action');
    final continueButton = hasPreview
        ? IconButton(
            key: actionKey,
            onPressed: canContinue ? onContinue : null,
            tooltip: strings.importRecheckButton,
            icon: actionIcon,
            style: IconButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              minimumSize: const Size(44, 44),
              maximumSize: const Size(44, 44),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.standard,
              padding: const EdgeInsets.all(10),
            ),
          )
        : Semantics(
            liveRegion: loading,
            child: IconButton.filled(
              key: actionKey,
              onPressed: canContinue ? onContinue : null,
              tooltip: loading ? strings.importLoading : strings.parseButton,
              icon: actionIcon,
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                maximumSize: const Size(44, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                padding: const EdgeInsets.all(10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  strings.importInputLabel,
                  style: textTheme.labelMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    height: 1.3,
                    leadingDistribution: TextLeadingDistribution.even,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                onPressed: hasText && !saving ? onClear : null,
                tooltip: strings.importClearButton,
                icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 17),
                style: IconButton.styleFrom(
                  foregroundColor: cs.onSurfaceVariant,
                  disabledForegroundColor: cs.onSurfaceVariant.withValues(
                    alpha: 0.25,
                  ),
                  minimumSize: const Size(44, 44),
                  maximumSize: const Size(44, 44),
                  padding: const EdgeInsets.all(10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.standard,
                ),
              ),
            ],
          ),
          TextField(
            controller: controller,
            focusNode: focusNode,
            readOnly: saving,
            minLines: 3,
            maxLines: 5,
            onChanged: onChanged,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            textAlignVertical: TextAlignVertical.top,
            style: inputStyle,
            strutStyle: StrutStyle.fromTextStyle(inputStyle),
            decoration: InputDecoration(
              hintText: strings.importHint,
              hintMaxLines: 3,
              hintStyle: inputStyle.copyWith(
                color: cs.onSurfaceVariant.withValues(alpha: 0.72),
              ),
              isDense: true,
              filled: false,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
              final requiredWidth = 110 * scale + (onScan != null ? 96 : 52);
              final stacked = constraints.maxWidth < requiredWidth;
              return stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(alignment: Alignment.centerLeft, child: sources),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: continueButton,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: sources),
                        const SizedBox(width: 8),
                        continueButton,
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }
}

String _importError(String code, bool ru) => switch (code) {
  'subscription_empty' || 'no_links' =>
    ru
        ? 'Серверы не найдены. Проверьте ссылку и формат подписки.'
        : 'No servers found. Check the link and subscription format.',
  'download_failed' =>
    ru
        ? 'Не удалось загрузить подписку. Проверьте ссылку и подключение к интернету.'
        : 'Could not download the subscription. Check the link and internet connection.',
  'unsupported_protocol' =>
    ru ? 'Протокол не поддерживается' : 'Unsupported protocol',
  'unsupported_configuration' =>
    ru
        ? 'Профиль содержит параметры, которые эта версия не поддерживает.'
        : 'The profile contains parameters this release does not support.',
  'clipboard_empty' => ru ? 'Буфер обмена пуст' : 'Clipboard is empty',
  'clipboard_denied' =>
    ru
        ? 'Буфер обмена недоступен. Вставьте текст вручную.'
        : 'Clipboard is unavailable. Paste the text manually.',
  _ =>
    ru
        ? 'Не удалось разобрать конфигурацию. Проверьте формат ссылки.'
        : 'Could not parse the configuration. Check the link format.',
};
