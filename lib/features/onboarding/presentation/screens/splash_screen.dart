import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../app/honey_mark.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Future.delayed(const Duration(seconds: 2), () {
      if (context.mounted) context.go('/');
    });
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HoneyMark(size: 72, color: Color(0xFFC8A96E)),
            SizedBox(height: 16),
            Text(
              'Honey',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
