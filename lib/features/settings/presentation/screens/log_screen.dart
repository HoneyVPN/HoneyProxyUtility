import 'dart:io' show Platform, File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../app/app_theme.dart';
import '../../data/log_provider.dart';

class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key});
  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  final _scrollCtrl = ScrollController();
  bool _autoScroll = true;
  String? _sbLogContent;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSingboxLog() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final tmp = await getTemporaryDirectory();
      final f = File('${tmp.path}/honeyvpn_sb.log');
      if (f.existsSync()) {
        setState(() => _sbLogContent = f.readAsStringSync());
      } else {
        setState(() => _sbLogContent = '(log file not found — start a connection first)');
      }
    } catch (e) {
      setState(() => _sbLogContent = 'Error reading log: $e');
    }
  }

  void _copyAll(List<LogEntry> entries) {
    final text = entries.map((e) {
      final t = e.time;
      final ts = '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}:${t.second.toString().padLeft(2,'0')}';
      return '$ts  ${e.message}';
    }).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(logProvider);
    final cs = Theme.of(context).colorScheme;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScroll && _scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          if (!kIsWeb && Platform.isWindows)
            IconButton(
              icon: const Icon(Icons.file_open_outlined),
              tooltip: 'Load sing-box log',
              onPressed: _loadSingboxLog,
            ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy all',
            onPressed: entries.isEmpty ? null : () => _copyAll(entries),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: entries.isEmpty
                ? null
                : () => ref.read(logProvider.notifier).clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (entries.isEmpty && _sbLogContent == null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.terminal_outlined, size: 48, color: cs.outline),
                    const SizedBox(height: 12),
                    Text('No logs yet', style: TextStyle(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Text('Connect to a server to see events here',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is UserScrollNotification) {
                    final atBottom = _scrollCtrl.position.pixels >=
                        _scrollCtrl.position.maxScrollExtent - 20;
                    if (_autoScroll != atBottom) {
                      setState(() => _autoScroll = atBottom);
                    }
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: entries.length + (_sbLogContent != null ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i < entries.length) {
                      return _LogLine(entry: entries[i]);
                    }
                    // sing-box raw log at the bottom
                    return _SingboxLogBlock(content: _sbLogContent!);
                  },
                ),
              ),
            ),

          if (!_autoScroll)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FloatingActionButton.small(
                  onPressed: () {
                    setState(() => _autoScroll = true);
                    _scrollCtrl.animateTo(
                      _scrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  },
                  child: const Icon(Icons.arrow_downward, size: 18),
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
    final ts = '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}:${t.second.toString().padLeft(2,'0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ts, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: entry.isError ? NexColors.error : cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SingboxLogBlock extends StatelessWidget {
  final String content;
  const _SingboxLogBlock({required this.content});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Text('sing-box log', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
            letterSpacing: 0.8, color: cs.primary)),
        const SizedBox(height: 6),
        SelectableText(
          content,
          style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: cs.onSurface),
        ),
      ],
    );
  }
}
