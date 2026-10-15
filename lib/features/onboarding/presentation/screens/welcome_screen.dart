import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/l10n/strings.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public, size: 72, color: Color(0xFF3B82F6)),
            const SizedBox(height: 16),
            const Text(
              'HoneyProxyUtility',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => context.go('/'),
              child: Text(strings.getStarted),
            ),
          ],
        ),
      ),
    );
  }
}
