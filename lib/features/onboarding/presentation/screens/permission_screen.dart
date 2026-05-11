import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class PermissionScreen extends StatelessWidget {
  const PermissionScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public, size: 72, color: Color(0xFF3B82F6)),
            const SizedBox(height: 16),
            const Text('HoneyProxyUtility', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('Get Started'),
            ),
          ],
        ),
      ),
    );
  }
}
