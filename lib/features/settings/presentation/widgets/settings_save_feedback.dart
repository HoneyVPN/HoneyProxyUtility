import 'package:flutter/material.dart';

import '../notifiers/settings_notifier.dart';

/// Await settings writes even when a widget's callback has a void signature.
Future<void> saveSettingsWithFeedback(
  BuildContext context,
  Future<void> Function() save,
  String failureMessage,
) async {
  try {
    await save();
  } on SettingsPersistenceException {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(failureMessage)));
  }
}
