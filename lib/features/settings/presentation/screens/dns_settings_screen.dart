import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../data/models/app_settings.dart';
import '../notifiers/settings_notifier.dart';
import '../widgets/settings_save_feedback.dart';

class DnsSettingsScreen extends ConsumerStatefulWidget {
  const DnsSettingsScreen({super.key});

  @override
  ConsumerState<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends ConsumerState<DnsSettingsScreen> {
  late final TextEditingController _customController;
  bool _edited = false;
  late bool _hydrated;
  bool _saving = false;
  DnsPreset? _draftPreset;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hydrated = ref.read(settingsProvider).hasValue;
    _customController = TextEditingController(
      text: ref.read(settingsProvider).value?.customDnsUrl ?? '',
    );
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final s = ref.read(stringsProvider);
    final address = _customController.text.trim();
    final error = _validateAddress(address, s);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(settingsProvider.notifier)
          .setDns(DnsPreset.custom, customUrl: address);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _edited = false;
        _draftPreset = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = s.settingsSaveFailed;
      });
    }
  }

  String? _validateAddress(String address, S s) {
    return switch (AppSettings.customDnsIssue(address)) {
      null => null,
      SettingsValidationIssue.dnsPort => s.customDnsPortUnsupported,
      SettingsValidationIssue.dnsExtras => s.customDnsExtrasUnsupported,
      SettingsValidationIssue.dnsTlsPath => s.customDnsTlsPathUnsupported,
      _ => s.invalidDnsAddress,
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, (_, next) {
      final saved = next.value?.customDnsUrl;
      if (!_hydrated && saved != null) {
        _hydrated = true;
        if (!_edited) _customController.text = saved;
      }
    });
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final selected = _draftPreset ?? settings.dnsPreset;
    return Scaffold(
      appBar: AppBar(title: Text(s.dnsTitle)),
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
                child: RadioGroup<DnsPreset>(
                  groupValue: selected,
                  onChanged: (value) {
                    if (value == null || _saving) return;
                    setState(() {
                      _draftPreset = value == DnsPreset.custom ? value : null;
                      _error = null;
                    });
                    if (value != DnsPreset.custom) {
                      saveSettingsWithFeedback(
                        context,
                        () => ref.read(settingsProvider.notifier).setDns(value),
                        s.settingsSaveFailed,
                      );
                    }
                  },
                  child: Column(
                    children: [
                      for (var i = 0; i < DnsPreset.values.length; i++) ...[
                        if (i > 0) const Divider(height: 0.5, indent: 12),
                        RadioListTile<DnsPreset>(
                          value: DnsPreset.values[i],
                          enabled: !_saving,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.trailing,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 2,
                          ),
                          title: Text(
                            s.dnsPresetLabel(DnsPreset.values[i].name),
                            style: TextStyle(color: cs.onSurface),
                          ),
                          subtitle: DnsPreset.values[i] == DnsPreset.custom
                              ? null
                              : Text(
                                  DnsPreset.values[i].serverUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (selected == DnsPreset.custom) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('custom-dns-field'),
                  controller: _customController,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {
                    _edited = true;
                    _error = null;
                  }),
                  onSubmitted: (_) => _save(),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: s.customDnsAddress,
                    hintText: 'https://example.com/dns-query',
                    errorText: _error,
                    errorMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? s.savingSettings : s.saveButton),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  s.dnsHelp,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
