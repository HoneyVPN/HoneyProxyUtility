import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../../data/log_provider.dart';
import '../../../diagnostics/presentation/diagnostic_send_sheet.dart';

class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key});
  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  final _scrollCtrl = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _copyAll(List<LogEntry> entries) async {
    final text = entries
        .map((e) {
          final t = e.time;
          final ts =
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
          return '$ts  ${e.message}';
        })
        .join('\n');
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      copied = true;
    } on PlatformException {
      // Clipboard failures may contain private platform details.
    } on MissingPluginException {
      // A platform without clipboard support has the same safe feedback.
    }
    if (!mounted) return;
    final strings = ref.read(stringsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(copied ? strings.copied : strings.copyFailed),
        duration: Duration(seconds: copied ? 1 : 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';

    ref.listen(logProvider, (_, __) {
      if (_autoScroll && _scrollCtrl.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });

    final entries = ref.watch(logProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.logsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_outlined),
            tooltip: ru ? 'Отправить диагностику' : 'Send diagnostics',
            onPressed: () => showDiagnosticSendSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: ru ? 'Копировать' : 'Copy',
            onPressed: entries.isEmpty ? null : () => _copyAll(entries),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: ru ? 'Очистить' : 'Clear',
            onPressed: entries.isEmpty
                ? null
                : () => ref.read(logProvider.notifier).clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (entries.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.terminal_outlined,
                      size: 28,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      ru ? 'Журнал пуст' : 'No events yet',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ru
                          ? 'Здесь появятся события подключения.'
                          : 'Connection events will appear here.',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is UserScrollNotification) {
                    final atBottom =
                        _scrollCtrl.position.pixels >=
                        _scrollCtrl.position.maxScrollExtent - 20;
                    if (_autoScroll != atBottom) {
                      setState(() => _autoScroll = atBottom);
                    }
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (_, i) => _LogLine(entry: entries[i]),
                ),
              ),
            ),

          if (!_autoScroll)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton(
                  onPressed: () {
                    setState(() => _autoScroll = true);
                    _scrollCtrl.animateTo(
                      _scrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  },
                  child: Text(ru ? 'К последнему событию' : 'Latest event'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final LogEntry entry;
  const _LogLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = entry.time;
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ts,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: entry.isError ? NexColors.error : cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
