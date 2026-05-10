import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class ShellScaffold extends StatefulWidget {
  final Widget child;
  const ShellScaffold({super.key, required this.child});

  @override
  State<ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends State<ShellScaffold> {
  int _prevIndex = 0;
  bool _forward = true;

  static const _versionUrl = 'https://api.honeyvpn.ru/app/api/version';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final resp = await Dio().get<Map<String, dynamic>>(
        _versionUrl,
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          responseType: ResponseType.json,
        ),
      );
      final data = resp.data;
      if (data == null) return;

      final remote = (data['version'] as String? ?? '').trim();
      if (remote.isEmpty || !_isNewer(remote, current)) return;

      final url = (Platform.isAndroid
              ? data['download_android']
              : data['download_windows']) as String? ??
          '';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          content: Text(
            'Вышла новая версия $remote',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          actions: [
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).clearMaterialBanners();
                if (url.isNotEmpty) launchUrl(Uri.parse(url));
              },
              child: const Text('Обновить'),
            ),
            TextButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context).clearMaterialBanners(),
              child: const Text('Позже'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  static bool _isNewer(String remote, String current) {
    List<int> parse(String v) =>
        v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final r = parse(remote);
    final c = parse(current);
    for (var i = 0; i < r.length && i < c.length; i++) {
      if (r[i] > c[i]) return true;
      if (r[i] < c[i]) return false;
    }
    return r.length > c.length;
  }

  static int _computeIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    if (location.startsWith('/converter')) return 1;
    if (location.startsWith('/marketplace')) return 2;
    if (location.startsWith('/settings')) return 3;
    return 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newIndex = _computeIndex(context);
    if (newIndex != _prevIndex) {
      _forward = newIndex > _prevIndex;
      _prevIndex = newIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _computeIndex(context);

    return Scaffold(
      body: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          transitionBuilder: (child, animation) {
            final isNew = child.key == ValueKey(index);
            final begin = isNew
                ? Offset(_forward ? 1.0 : -1.0, 0.0)
                : Offset(_forward ? -1.0 : 1.0, 0.0);
            return SlideTransition(
              position: Tween<Offset>(begin: begin, end: Offset.zero)
                  .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
              child: child,
            );
          },
          layoutBuilder: (currentChild, previousChildren) => Stack(
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          child: KeyedSubtree(key: ValueKey(index), child: widget.child),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: NavigationBar(
            selectedIndex: index,
            height: 64,
            onDestinationSelected: (i) {
              switch (i) {
                case 0: context.go('/'); break;
                case 1: context.go('/converter'); break;
                case 2: context.go('/marketplace'); break;
                case 3: context.go('/settings'); break;
              }
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined, size: 22),
                selectedIcon: Icon(Icons.home_rounded, size: 22),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.add_link_outlined, size: 22),
                selectedIcon: Icon(Icons.add_link, size: 22),
                label: 'Import',
              ),
              NavigationDestination(
                icon: Icon(Icons.storefront_outlined, size: 22),
                selectedIcon: Icon(Icons.storefront_rounded, size: 22),
                label: 'Market',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined, size: 22),
                selectedIcon: Icon(Icons.tune_rounded, size: 22),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
