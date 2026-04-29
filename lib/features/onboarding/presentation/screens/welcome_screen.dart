import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    if ('welcome_screen' == 'splash_screen') {
      Future.delayed(const Duration(seconds: 2), () {
        if (context.mounted) context.go('/');
      });
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.public, size: 72, color: Color(0xFF3B82F6)),
              SizedBox(height: 16),
              Text('NexProxy', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('NexProxy')),
      body: Center(
        child: FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('Get Started'),
        ),
      ),
    );
  }
}
