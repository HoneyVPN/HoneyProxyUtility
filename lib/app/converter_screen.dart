import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';

import '../../data/parsers/base_parser.dart';
import '../../data/parsers/link_dispatcher.dart';
import '../../data/parsers/subscription_parser.dart';
import '../../domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
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
    final text = state.text.trim();
    if (text.isEmpty) return;

    // If it's an HTTP(S) URL — fetch it first
    if (text.startsWith('http://') || text.startsWith('https://')) {
      state = state.copyWith(importing: true, error: null, results: []);
      try {
        final resp = await Dio().get<String>(
          text,
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

  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text?.isNotEmpty == true) {
      state = state.copyWith(text: data!.text!);
      await parse();
    }
  }
}

class ConverterScreen extends ConsumerStatefulWidget {
  const ConverterScreen({super.key});

  @override
  ConsumerState<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends ConsumerState<ConverterScreen> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
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

    if (_ctrl.text != s.text) {
      _ctrl.value = TextEditingValue(
        text: s.text,
        selection: TextSelection.collapsed(offset: s.text.length),
      );
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
                    onChanged: notifier.updateText,
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: 'vmess:// or vless:// or ss:// or subscription URL...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: notifier.pasteFromClipboard,
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
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('${p.displayName} added'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'Servers', onPressed: () => ctx.go('/servers')),
      ),
    );
  }

  void _importAll(BuildContext ctx, WidgetRef ref, List<ParsedProxy> proxies) {
    ref.read(serversNotifierProvider.notifier).addFromProxies(proxies);
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('${proxies.length} servers added'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'Servers', onPressed: () => ctx.go('/servers')),
      ),
    );
  }
}
