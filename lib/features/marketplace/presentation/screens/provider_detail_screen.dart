import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/vpn_provider.dart';
import '../../../../app/app_theme.dart';

class ProviderDetailScreen extends StatelessWidget {
  final String id;
  const ProviderDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final provider = ProviderCatalog.all.where((p) => p.id == id).firstOrNull;
    if (provider == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Provider')),
        body: const Center(child: Text('Provider not found')),
      );
    }
    if (provider.id == 'alphavpn') {
      return _AlphaVpnDetailScreen(provider: provider);
    }
    return _ProviderDetailView(provider: provider);
  }
}

// ─── AlphaVPN custom detail screen ──────────────────────────────────────────

class _AlphaVpnDetailScreen extends StatefulWidget {
  final VpnProvider provider;
  const _AlphaVpnDetailScreen({required this.provider});

  @override
  State<_AlphaVpnDetailScreen> createState() => _AlphaVpnDetailScreenState();
}

class _AlphaVpnDetailScreenState extends State<_AlphaVpnDetailScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  static const _bg         = Color(0xFF080808);
  static const _surface    = Color(0xFF111111);
  static const _surface2   = Color(0xFF181818);
  static const _border     = Color(0xFF222222);
  static const _textMain   = Color(0xFFF0F0F0);
  static const _textMuted  = Color(0xFF666666);
  static const _purple     = Color(0xFF9333EA);
  static const _magenta    = Color(0xFFD946EF);
  static const _orange     = Color(0xFFF5A623);
  static const _yellow     = Color(0xFFFBBF24);
  static const _green      = Color(0xFF22C55E);

  static const _gradientColors = [_purple, _magenta, _orange, _yellow, _purple];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          foregroundColor: _textMain,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 20,
            color: _textMain,
          ),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              return ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) => LinearGradient(
                  colors: _gradientColors,
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  transform: _ShiftTransform(_ctrl.value),
                ).createShader(bounds),
                child: const Text(
                  'AlphaVPN',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
                ),
              );
            },
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 18, color: _textMuted),
            onPressed: () => context.pop(),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ── Hero card ─────────────────────────────────────────────────
            _AlphaCard(
              child: Column(
                children: [
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      widget.provider.logoAsset,
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 14),
                  AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, __) => ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (b) => LinearGradient(
                        colors: _gradientColors,
                        transform: _ShiftTransform(_ctrl.value),
                      ).createShader(b),
                      child: const Text(
                        'AlphaVPN',
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'AmneziaWG · обфусцированный WireGuard',
                    style: TextStyle(fontSize: 13, color: _textMuted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  // Protocol badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _purple.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _purple.withOpacity(0.35)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield_rounded, size: 14, color: _purple),
                        SizedBox(width: 6),
                        Text('AmneziaWG', style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700, color: _purple,
                        )),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Trial banner ──────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_orange.withOpacity(0.15), _yellow.withOpacity(0.05)],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _orange.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _orange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(child: Text('🎁', style: TextStyle(fontSize: 22))),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('3 дня бесплатно',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: _orange)),
                        SizedBox(height: 2),
                        Text('Полный доступ без ограничений',
                            style: TextStyle(fontSize: 12, color: _textMuted)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('FREE',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _orange)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Servers ───────────────────────────────────────────────────
            _AlphaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Серверы', style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _textMain,
                  )),
                  const SizedBox(height: 12),
                  _ServerRow(flag: '🇫🇷', country: 'Франция', label: 'France · EU'),
                  const SizedBox(height: 1),
                  _ServerRow(flag: '🇩🇪', country: 'Германия', label: 'Germany · EU'),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Description ───────────────────────────────────────────────
            _AlphaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('О сервисе', style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _textMain,
                  )),
                  const SizedBox(height: 8),
                  Text(
                    widget.provider.shortDescription,
                    style: const TextStyle(fontSize: 13, height: 1.6, color: _textMuted),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Features ──────────────────────────────────────────────────
            _AlphaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Возможности', style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _textMain,
                  )),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.provider.features
                        .map((f) => _AlphaChip(label: f))
                        .toList(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Pricing ───────────────────────────────────────────────────
            _AlphaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Тарифы', style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _textMain,
                  )),
                  SizedBox(height: 12),
                  _PriceRow(label: '1 устройство · 1 месяц', price: '150₽'),
                  SizedBox(height: 8),
                  _PriceRow(label: '1 устройство · 3 месяца', price: '390₽'),
                  SizedBox(height: 8),
                  _PriceRow(label: '3 устройства · 1 месяц', price: '250₽'),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── CTA ───────────────────────────────────────────────────────
            GestureDetector(
              onTap: () => launchUrl(
                Uri.parse(widget.provider.referralUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _gradientColors,
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      transform: _ShiftTransform(_ctrl.value),
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('🎁', style: TextStyle(fontSize: 20)),
                      SizedBox(width: 10),
                      Text(
                        '3 дня бесплатно',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(widget.provider.websiteUrl),
                mode: LaunchMode.externalApplication,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textMuted,
                side: const BorderSide(color: _border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Открыть Telegram-бот', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── AlphaVPN sub-widgets ─────────────────────────────────────────────────────

class _AlphaCard extends StatelessWidget {
  final Widget child;
  const _AlphaCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: child,
    );
  }
}

class _ServerRow extends StatelessWidget {
  final String flag;
  final String country;
  final String label;
  const _ServerRow({required this.flag, required this.country, required this.label});

  static const _green = Color(0xFF22C55E);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF222222)),
      ),
      child: Row(
        children: [
          Text(flag, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(country, style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFF0F0F0),
                )),
                Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _green,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: _green.withOpacity(0.6), blurRadius: 6)],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlphaChip extends StatelessWidget {
  final String label;
  const _AlphaChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Text(label, style: const TextStyle(
        fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFF0F0F0),
      )),
    );
  }
}

class _PriceRow extends StatelessWidget {
  final String label;
  final String price;
  const _PriceRow({required this.label, required this.price});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF888888))),
        ),
        Text(price, style: const TextStyle(
          fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFF5A623),
        )),
      ],
    );
  }
}

// Shifts gradient horizontally for animation
class _ShiftTransform extends GradientTransform {
  final double t;
  const _ShiftTransform(this.t);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(-bounds.width * t * 2, 0, 0);
  }
}

// ─── Standard provider detail view ──────────────────────────────────────────

class _ProviderDetailView extends StatelessWidget {
  final VpnProvider provider;
  const _ProviderDetailView({required this.provider});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(provider.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // "Our service" banner
          if (provider.isOwn) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [NexPalette.accent.withOpacity(0.18), NexPalette.accent.withOpacity(0.06)],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexPalette.accent.withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_rounded, color: NexPalette.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.tagline,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: NexPalette.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Header card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: provider.logoAsset.isNotEmpty
                        ? Image.asset(
                            provider.logoAsset,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 80,
                            height: 80,
                            color: provider.isOwn
                                ? NexPalette.accent.withOpacity(0.15)
                                : cs.surfaceContainerHighest,
                            child: Center(
                              child: Text(
                                provider.name.substring(0, 1).toUpperCase(),
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                  color: provider.isOwn ? NexPalette.accent : cs.primary,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  Text(provider.name,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    provider.pricing.priceLabel ?? '90₽ / мес',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Description
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('О сервисе',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(provider.shortDescription,
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Features
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Возможности',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: provider.features
                        .map((f) => Chip(
                          label: Text(f, style: TextStyle(fontSize: 12, color: cs.onSurface)),
                          backgroundColor: cs.surfaceContainerHighest,
                          side: BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
                        ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Protocols
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Протоколы',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: provider.protocols
                        .map((p) => Chip(
                              label: Text(p, style: TextStyle(fontSize: 12, color: cs.onSurface)),
                              backgroundColor: cs.surfaceContainerHighest,
                              side: BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Trial period banner
          if (provider.pricing.trialDescription != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [const Color(0xFFFFB300).withOpacity(0.15), const Color(0xFFFFB300).withOpacity(0.05)],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(child: Text('🎁', style: TextStyle(fontSize: 22))),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Пробный период',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFFFFB300)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '3 дня бесплатного доступа',
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65)),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '3 дня',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFFFB300)),
                    ),
                  ),
                ],
              ),
            ),

          // CTA — try free via Telegram bot
          FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(provider.referralUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Text('🎁', style: TextStyle(fontSize: 18)),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('3 дня бесплатно', style: TextStyle(fontSize: 16)),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
