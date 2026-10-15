import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/l10n/strings.dart';
import '../data/diagnostic_report.dart';
import '../data/diagnostic_upload.dart';

Future<void> showDiagnosticSendSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _DiagnosticSendSheet(),
    );

class _DiagnosticSendSheet extends ConsumerStatefulWidget {
  const _DiagnosticSendSheet();
  @override
  ConsumerState<_DiagnosticSendSheet> createState() =>
      _DiagnosticSendSheetState();
}

class _DiagnosticSendSheetState extends ConsumerState<_DiagnosticSendSheet> {
  final _description = TextEditingController();
  DiagnosticReport? _report;
  DiagnosticReport? _sendAttempt;
  String? _sendDescription;
  String? _reportId, _error;
  bool _preparing = true, _sending = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final report = await buildDiagnosticReport(
        ref,
        description: _description.text,
      );
      if (mounted)
        setState(() {
          _report = report;
          _preparing = false;
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _preparing = false;
          _error = 'prepare';
        });
    }
  }

  Future<void> _send() async {
    if (_sending || _report == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      // A lost receipt must retry the same request ID and bytes. Editing the
      // note starts a new attempt rather than changing an accepted request.
      final description = _description.text;
      if (_sendAttempt == null || _sendDescription != description) {
        _sendAttempt = await buildDiagnosticReport(
          ref,
          description: description,
        );
        _sendDescription = description;
      }
      final report = _sendAttempt!;
      _report = report;
      final id = await ref.read(diagnosticUploaderProvider).send(report);
      if (mounted)
        setState(() {
          _report = report;
          _reportId = id;
        });
    } on DiagnosticUploadException catch (e) {
      if (mounted) setState(() => _error = e.failure.name);
    } catch (_) {
      if (mounted) setState(() => _error = 'prepare');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ru = ref.watch(stringsProvider).locale == 'ru';
    final cs = Theme.of(context).colorScheme;
    final report = _report;
    final id = _reportId;
    return PopScope(
      canPop: !_sending,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ru ? 'Отправить диагностику' : 'Send diagnostics',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _sending ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: ru ? 'Закрыть' : 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (id != null) ...[
                Text(
                  id == 'DEMO-LOCAL'
                      ? (ru
                            ? 'Демо: отчёт не отправлен.'
                            : 'Demo: no report was sent.')
                      : (ru
                            ? 'Отчёт принят. Передайте этот номер поддержке.'
                            : 'Report received. Give this ID to support.'),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  id,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: id)),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(ru ? 'Копировать номер' : 'Copy ID'),
                ),
              ] else ...[
                Text(
                  ru
                      ? 'Журнал Honey и доступные события ядра помогут разобраться с ошибкой.'
                      : 'Honey logs and available core events help us investigate errors.',
                ),
                const SizedBox(height: 8),
                Text(
                  ru
                      ? 'В отчёте: версия приложения, состояние VPN, настройки сети и результаты обновления подписок. Адреса, ссылки, имена и ключи доступа скрыты.'
                      : 'Includes app version, VPN state, network settings and subscription update results. Addresses, links, names and access keys are removed.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  ru
                      ? 'Только последние события. Журнал установщика и полный вывод ядра Windows не включены. Ничего не отправляется автоматически.'
                      : 'Recent events only. Installer logs and raw Windows core output are not included. Nothing is sent automatically.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 16),
                if (_preparing)
                  const Center(child: CircularProgressIndicator())
                else if (report != null)
                  Text(
                    ru
                        ? '${(report.data['events'] as List).length} событий · ${report.errorCount} ошибок · ${(report.bytes.length / 1024).ceil()} КБ'
                        : '${(report.data['events'] as List).length} events · ${report.errorCount} errors · ${(report.bytes.length / 1024).ceil()} KB',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _description,
                  enabled: !_sending,
                  maxLength: 1000,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: ru
                        ? 'Что произошло? Необязательно'
                        : 'What happened? Optional',
                    hintText: ru
                        ? 'Например: подключился, но страницы не открываются.'
                        : 'For example: connected, but pages do not load.',
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error == 'timeout'
                          ? (ru
                                ? 'Сервер не ответил вовремя. Попробуйте позже.'
                                : 'The server did not respond in time. Try again later.')
                          : _error == 'prepare'
                          ? (ru
                                ? 'Не удалось подготовить отчёт.'
                                : 'Could not prepare the report.')
                          : (ru
                                ? 'Отчёт не отправлен. Попробуйте позже.'
                                : 'Report was not sent. Try again later.'),
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _sending || _preparing || report == null
                        ? null
                        : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_outlined),
                    label: Text(
                      _sending
                          ? (ru ? 'Отправляется…' : 'Sending…')
                          : (ru ? 'Отправить в поддержку' : 'Send to support'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
