import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The developer's independent brand signature at the end of Settings.
class YuNiCodeCredit extends StatefulWidget {
  const YuNiCodeCredit({
    super.key,
    required this.caption,
    this.onOpenWebsite,
    this.websiteUnavailableMessage,
  });

  final String caption;
  final Future<void> Function()? onOpenWebsite;
  final String? websiteUnavailableMessage;

  @override
  State<YuNiCodeCredit> createState() => _YuNiCodeCreditState();
}

class _YuNiCodeCreditState extends State<YuNiCodeCredit>
    with TickerProviderStateMixin {
  static const _ink = Color(0xff090909);
  static const _paper = Color(0xffeee9df);
  static const _coral = Color(0xffff5c3a);
  static const _acid = Color(0xffd9ff43);

  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1080),
  );
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 7500),
  );
  final _focusNode = FocusNode(debugLabel: 'YuNiCode developer link');
  bool _hovered = false;
  bool _keyboardFocus = false;
  bool _touchExpanded = false;
  bool _expanded = false;
  bool _animate = false;
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncAnimations();
  }

  void _updateExpansion() {
    final expanded = _hovered || _keyboardFocus || _touchExpanded;
    if (expanded == _expanded) return;
    setState(() => _expanded = expanded);
    _syncAnimations();
  }

  void _syncAnimations() {
    if (_animate) {
      if (_expanded) {
        _reveal.forward();
        if (!_sheen.isAnimating) _sheen.repeat();
      } else {
        _reveal.reverse();
        _sheen.stop();
        _sheen.value = 0;
      }
    } else {
      _reveal.stop();
      _reveal.value = _expanded ? 1 : 0;
      _sheen.stop();
      _sheen.value = 0;
    }
  }

  Future<void> _activate() async {
    if (!_expanded) {
      _touchExpanded = true;
      _updateExpansion();
      return;
    }
    await _openWebsite();
  }

  Future<void> _openWebsite() async {
    if (_opening) return;
    _opening = true;
    try {
      final open = widget.onOpenWebsite;
      if (open != null) {
        await open();
      } else {
        final opened = await launchUrl(
          Uri.parse('https://yunicode.pro/'),
          mode: LaunchMode.externalApplication,
        );
        if (!opened) _showOpenFailure();
      }
    } on PlatformException {
      _showOpenFailure();
    } on MissingPluginException {
      _showOpenFailure();
    } finally {
      _opening = false;
    }
  }

  void _showOpenFailure() {
    if (!mounted) return;
    final message =
        widget.websiteUnavailableMessage ??
        (RegExp(r'[А-Яа-яЁё]').hasMatch(widget.caption)
            ? 'Не удалось открыть сайт'
            : 'Could not open the website');
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _reveal.dispose();
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? _ink : _paper;
    final foreground = dark ? _paper : _ink;
    final caption = foreground.withValues(alpha: dark ? .46 : .56);
    return ColoredBox(
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.caption.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1.5,
                letterSpacing: 1.5,
                color: caption,
              ),
            ),
            const SizedBox(height: 8),
            FocusableActionDetector(
              focusNode: _focusNode,
              includeFocusSemantics: false,
              onFocusChange: (_) {
                if (mounted) setState(() {});
              },
              onShowFocusHighlight: (value) {
                _keyboardFocus = value;
                _updateExpansion();
              },
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.numpadEnter):
                    ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    unawaited(_activate());
                    return null;
                  },
                ),
              },
              child: Semantics(
                key: const ValueKey('yunicode-website-link'),
                container: true,
                link: true,
                focusable: true,
                focused: _focusNode.hasFocus,
                label: 'YuNiCode',
                onTap: () => unawaited(_openWebsite()),
                excludeSemantics: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (event) {
                    if (event.kind != PointerDeviceKind.mouse &&
                        event.kind != PointerDeviceKind.stylus) {
                      return;
                    }
                    _hovered = true;
                    _updateExpansion();
                  },
                  onExit: (_) {
                    _hovered = false;
                    _updateExpansion();
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(_activate()),
                    child: SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final fontSize = constraints.maxWidth < 360
                              ? 22.0
                              : 26.0;
                          final style = TextStyle(
                            fontFamily: 'YuNiCodeBrand',
                            fontWeight: FontWeight.w800,
                            fontSize: fontSize,
                            height: 1,
                            letterSpacing: -.045 * fontSize,
                            color: foreground,
                          );
                          return AnimatedBuilder(
                            animation: Listenable.merge([_reveal, _sheen]),
                            builder: (context, _) {
                              final reveal = Curves.easeOutQuint.transform(
                                _reveal.value,
                              );
                              return DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3),
                                  border: _keyboardFocus
                                      ? Border.all(color: _coral)
                                      : null,
                                ),
                                child: Center(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _bracket(reveal, foreground),
                                        SizedBox(width: 3 + reveal * 9),
                                        ClipRect(
                                          child: Align(
                                            widthFactor: reveal,
                                            child: Opacity(
                                              opacity: reveal,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.baseline,
                                                textBaseline:
                                                    TextBaseline.alphabetic,
                                                children: [
                                                  Text('Yu', style: style),
                                                  Text(
                                                    'Ni',
                                                    style: style.copyWith(
                                                      color: _coral,
                                                    ),
                                                  ),
                                                  _code(style, foreground),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: 3 + reveal * 9),
                                        Transform.flip(
                                          flipX: true,
                                          child: _bracket(reveal, foreground),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bracket(double reveal, Color foreground) => CustomPaint(
    size: const Size(13, 32),
    painter: _BrandBracketPainter(Color.lerp(foreground, _coral, reveal)!),
  );

  Widget _code(TextStyle style, Color foreground) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) {
      final value = _sheen.value;
      final position = value < .18
          ? 1.0
          : value < .52
          ? 1 - (value - .18) / .34
          : value < .68
          ? 0.0
          : (value - .68) / .32;
      final start = -bounds.width * 1.7 * position;
      return ui.Gradient.linear(
        Offset(start, -bounds.height * .2),
        Offset(start + bounds.width * 2.7, bounds.height * 1.2),
        [
          foreground,
          foreground,
          _coral,
          Color(0xffffc19e),
          _acid,
          foreground,
          foreground,
        ],
        const [0, .38, .46, .52, .57, .66, 1],
      );
    },
    child: Text('Code', style: style),
  );
}

class _BrandBracketPainter extends CustomPainter {
  const _BrandBracketPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height * .18)
      ..lineTo(size.width * .31, size.height * .5)
      ..lineTo(size.width, size.height * .82)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height * .5)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BrandBracketPainter oldDelegate) =>
      color != oldDelegate.color;
}
