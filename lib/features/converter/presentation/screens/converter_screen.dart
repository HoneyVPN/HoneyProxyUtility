import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../widgets/qr_scan_dialog.dart';

import '../../data/parsers/base_parser.dart';
import '../../data/parsers/link_dispatcher.dart';
import '../../data/parsers/subscription_parser.dart';
import '../../domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../subscriptions/presentation/screens/subscriptions_screen.dart';
import '../../../../app/app_theme.dart';
import '../widgets/parsed_result_card.dart';

final _converterStateProvider = StateNotifierProvider.autoDispose<_ConverterNotifier, _ConverterState>(
  (_) => _ConverterNotifier(),
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

  _ConverterState copyWith({String? text, List<ParsedProxy>? results, String? error, bool? importing}) =>
      _ConverterState(
        text: text ?? this.text,
        results: results ?? this.results,
        error: error,
        importing: importing ?? this.importing,
      );
}

class _ConverterNotifier extends StateNotifier<_ConverterState> {
  _ConverterNotifier() : super(const _ConverterState()); // ignore: deprecated_member_use

  static const _dispatcher = LinkDispatcher();
  static const _subParser = SubscriptionParser();

  void updateText(String text) {
    state = state.copyWith(text: text, error: null, results: []);
  }

  Future<void> parse() async {
    final text = state.text.replaceAll('\x00', '').trim();
    if (text.isEmpty) return;

    // If it's an HTTP(S) URL — fetch it first
    if (text.startsWith('http://') || text.startsWith('https://')) {
      state = state.copyWith(importing: true, error: null, results: []);
      try {
        // In web mode route through CORS proxy to avoid browser restrictions
        const proxyBase = '/proxy/?url=';
        final fetchUrl = kIsWeb ? '$proxyBase${Uri.encodeComponent(text)}' : text;
        final resp = await Dio().get<String>(
          fetchUrl,
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        final body = resp.data ?? '';
        final subs = _subParser.parse(body);
        if (subs.isEmpty) {
          state = state.copyWith(importing: false, error: 'Subscription is empty or unrecognised format', results: []);
        } else {
          state = state.copyWith(importing: false, results: subs, error: null);
        }
      } catch (e) {
        state = state.copyWith(
          importing: false,
          error: 'Failed to fetch URL: $e',
          results: [],
        );
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
        state = state.copyWith(error: 'No recognizable proxy links found', results: []);
      } else {
        state = state.copyWith(results: subs, error: null);
      }
    } on ParseException catch (e) {
      state = state.copyWith(error: e.message, results: []);
    } on UnsupportedProtocolException {
      state = state.copyWith(error: 'Unsupported protocol', results: []);
    } catch (e) {
      state = state.copyWith(error: e.toString(), results: []);
    }
  }

  Future<String?> pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text?.isNotEmpty == true) {
        state = state.copyWith(text: data!.text!);
        await parse();
        return null; // success
      }
      return 'Clipboard is empty';
    } catch (_) {
      // Web browsers require focus / explicit permission for clipboard read
      return 'clipboard_denied';
    }
  }

  void setInitialText(String text) {
    if (text.isNotEmpty && state.text.isEmpty) {
      state = state.copyWith(text: text);
    }
  }
}

class ConverterScreen extends ConsumerStatefulWidget {
  final String? initialText; // from URL scheme / deep link
  const ConverterScreen({super.key, this.initialText});

  @override
  ConsumerState<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends ConsumerState<ConverterScreen> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    // Handle URL scheme / deep link pre-fill
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final notifier = ref.read(_converterStateProvider.notifier);
        notifier.setInitialText(widget.initialText!);
        _ctrl.text = widget.initialText!;
        notifier.parse();
      });
    } else {
      // Check URL query param ?import=... (web deep link)
      _checkUrlScheme();
    }
  }

  void _checkUrlScheme() {
    if (!kIsWeb) return;
    try {
      final importParam = Uri.base.queryParameters['import'];
      if (importParam != null && importParam.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final notifier = ref.read(_converterStateProvider.notifier);
          notifier.setInitialText(importParam);
          _ctrl.text = importParam;
          notifier.parse();
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(_converterStateProvider);
    final notifier = ref.read(_converterStateProvider.notifier);

    // Sync controller when state changes externally
    if (_ctrl.text != s.text) {
      _ctrl.text = s.text;
      _ctrl.selection = TextSelection.collapsed(offset: s.text.length);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Input card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Paste proxy link or subscription', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  TextField(
                    maxLines: 5,
                    minLines: 3,
                    controller: _ctrl,
                    onChanged: notifier.updateText,
                    decoration: const InputDecoration(
                      hintText: 'vmess:// or vless:// or ss:// or subscription URL...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final result = await showModalBottomSheet<String?>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => const QrScanDialog(),
                              );
                              if (result != null && result.isNotEmpty) {
                                notifier.updateText(result);
                                _ctrl.text = result;
                                notifier.parse();
                              }
                            },
                            icon: const Icon(Icons.qr_code_scanner, size: 16),
                            label: const Text('Scan'),
                          ),
                        ),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final err = await notifier.pasteFromClipboard();
                            if (err == 'clipboard_denied' && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('Clipboard blocked by browser. Use Ctrl+V in the text field.'),
                                behavior: SnackBarBehavior.floating,
                                duration: Duration(seconds: 4),
                              ));
                            }
                          },
                          icon: const Icon(Icons.paste, size: 16),
                          label: const Text('Paste'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: s.importing ? null : notifier.parse,
                          icon: s.importing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.link, size: 16),
                          label: Text(s.importing ? 'Loading...' : 'Parse'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Error
          if (s.error != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NexColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: NexColors.error, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.error!, style: const TextStyle(color: NexColors.error, fontSize: 13))),
                ],
              ),
            ),
          ],

          // Results header
          if (s.results.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(
                    '${s.results.length} server${s.results.length == 1 ? '' : 's'} found',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => _importAll(context, ref, s.results),
                    icon: const Icon(Icons.download, size: 16),
                    label: Text('Import all (${s.results.length})'),
                  ),
                ],
              ),
            ),
            ...s.results.map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ParsedResultCard(
                proxy: p,
                onImport: () => _importOne(context, ref, p),
              ),
            )),
          ],
        ],
      ),
    );
  }

  void _importOne(BuildContext ctx, WidgetRef ref, ParsedProxy p) {
    ref.read(serversNotifierProvider.notifier).addFromProxy(p);
    final router = GoRouter.of(ctx);
    final messenger = ScaffoldMessenger.of(ctx);
    messenger.showSnackBar(
      SnackBar(
        content: Text('${p.displayName} added'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Servers',
          onPressed: () {
            messenger.hideCurrentSnackBar();
            router.go('/');
          },
        ),
      ),
    );
  }

  void _importAll(BuildContext ctx, WidgetRef ref, List<ParsedProxy> proxies) {
    final text = ref.read(_converterStateProvider).text.trim();
    final subId = (text.startsWith('http://') || text.startsWith('https://')) ? text : '';
    ref.read(serversNotifierProvider.notifier).addFromProxies(proxies, subscriptionId: subId);
    if (subId.isNotEmpty) {
      ref.read(subscriptionsProvider.notifier).register(subId, serverCount: proxies.length);
    }
    final router = GoRouter.of(ctx);
    final messenger = ScaffoldMessenger.of(ctx);
    messenger.showSnackBar(
      SnackBar(
        content: Text('${proxies.length} servers added'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Servers',
          onPressed: () {
            messenger.hideCurrentSnackBar();
            router.go('/');
          },
        ),
      ),
    );
  }
}
