import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    if ('splash_screen' == 'splash_screen') {
      Future.delayed(const Duration(seconds: 2), () {
        if (context.mounted) context.go('/');
      });
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 72, color: Color(0xFFC5A55A)),
              SizedBox(height: 16),
              Text('Honey', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Honey')),
      body: Center(
        child: FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('Get Started'),
        ),
      ),
    );
  }
}
