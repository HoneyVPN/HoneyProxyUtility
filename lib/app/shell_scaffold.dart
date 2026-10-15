import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'l10n/strings.dart';
import 'honey_mark.dart';

class NavigateSectionIntent extends Intent {
  final int index;
  const NavigateSectionIntent(this.index);
}

class ToggleSidebarIntent extends Intent {
  const ToggleSidebarIntent();
}

class ShellScaffold extends ConsumerStatefulWidget {
  final Widget child;
  const ShellScaffold({super.key, required this.child});
  @override
  ConsumerState<ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends ConsumerState<ShellScaffold> {
  var _expanded = true;
  static int _index(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    if (path.startsWith('/converter')) return 1;
    if (path.startsWith('/marketplace')) return 2;
    if (path.startsWith('/settings')) return 3;
    return 0;
  }

  void _navigate(int index) =>
      context.go(['/', '/converter', '/marketplace', '/settings'][index]);

  @override
  Widget build(BuildContext context) {
    final index = _index(context);
    final s = ref.watch(stringsProvider);
    final cs = Theme.of(context).colorScheme;
    final labels = [
      s.homeTitle,
      s.importScreenTitle,
      s.marketTitle,
      s.settingsTitle,
    ];
    const icons = [
      Icons.shield_outlined,
      CupertinoIcons.tray_arrow_down,
      Icons.storefront_outlined,
      Icons.tune_outlined,
    ];
    const selectedIcons = [
      Icons.shield_rounded,
      CupertinoIcons.tray_arrow_down_fill,
      Icons.storefront_rounded,
      Icons.tune_rounded,
    ];
    final apple =
        Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final bindings = <ShortcutActivator, Intent>{
      for (final modifier in [false, true]) ...{
        for (var i = 0; i < 4; i++)
          SingleActivator(
            [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
            ][i],
            meta: modifier,
            control: !modifier,
          ): NavigateSectionIntent(
            i,
          ),
        SingleActivator(
          LogicalKeyboardKey.keyN,
          meta: modifier,
          control: !modifier,
        ): const NavigateSectionIntent(
          1,
        ),
        SingleActivator(
          LogicalKeyboardKey.comma,
          meta: modifier,
          control: !modifier,
        ): const NavigateSectionIntent(
          3,
        ),
        SingleActivator(
          LogicalKeyboardKey.keyS,
          meta: modifier,
          control: !modifier,
          shift: true,
        ): const ToggleSidebarIntent(),
      },
    };
    return Shortcuts(
      shortcuts: bindings,
      child: Actions(
        actions: {
          NavigateSectionIntent: CallbackAction<NavigateSectionIntent>(
            onInvoke: (intent) {
              _navigate(intent.index);
              return null;
            },
          ),
          ToggleSidebarIntent: CallbackAction<ToggleSidebarIntent>(
            onInvoke: (_) {
              setState(() => _expanded = !_expanded);
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= (apple ? 760 : 900);
              // GoRouter owns its Navigator key. Mount exactly one copy.
              // A nested route's ModalBarrier blocks earlier-painted semantics.
              // Keep it inside its own container so the desktop sidebar remains
              // reachable; root modal dialogs still block the whole shell.
              final content = Semantics(
                container: true,
                explicitChildNodes: true,
                child: ClipRect(child: widget.child),
              );
              return Scaffold(
                body: desktop
                    ? Row(
                        children: [
                          _sidebar(
                            cs,
                            s,
                            labels,
                            icons,
                            selectedIcons,
                            index,
                            apple,
                            textScale,
                          ),
                          Expanded(child: content),
                        ],
                      )
                    : content,
                bottomNavigationBar: desktop
                    ? null
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surface,
                          border: Border(
                            top: BorderSide(
                              color: cs.outlineVariant,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: NavigationBar(
                            selectedIndex: index,
                            height: 56,
                            labelBehavior:
                                NavigationDestinationLabelBehavior.alwaysHide,
                            onDestinationSelected: _navigate,
                            destinations: [
                              for (var i = 0; i < labels.length; i++)
                                NavigationDestination(
                                  icon: i == 0
                                      ? const HoneyMark(size: 20)
                                      : Icon(icons[i], size: 20),
                                  selectedIcon: i == 0
                                      ? const HoneyMark(size: 20)
                                      : Icon(selectedIcons[i], size: 20),
                                  label: labels[i],
                                ),
                            ],
                          ),
                        ),
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sidebar(
    ColorScheme cs,
    S s,
    List<String> labels,
    List<IconData> icons,
    List<IconData> selectedIcons,
    int index,
    bool apple,
    double textScale,
  ) => Container(
    key: const ValueKey('desktop-sidebar'),
    width: _expanded ? (textScale > 1.4 ? 240 : 200) : 60,
    decoration: BoxDecoration(
      color: cs.surfaceContainer,
      border: Border(right: BorderSide(color: cs.outlineVariant, width: 0.5)),
    ),
    child: SafeArea(
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
            child: Row(
              children: [
                if (_expanded) ...[
                  HoneyMark(color: cs.primary, size: 19),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Honey',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  tooltip: _expanded ? s.hideSidebar : s.showSidebar,
                  icon: Icon(
                    _expanded
                        ? Icons.view_sidebar_outlined
                        : Icons.menu_rounded,
                    size: 16,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
          ),
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: Semantics(
                button: true,
                selected: i == index,
                label: labels[i],
                hint: s.navigationShortcut('${apple ? '⌘' : 'Ctrl+'}${i + 1}'),
                onTap: () => _navigate(i),
                child: ExcludeSemantics(
                  child: Material(
                    color: i == index ? cs.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    clipBehavior: Clip.antiAlias,
                    child: Tooltip(
                      excludeFromSemantics: true,
                      message:
                          '${labels[i]} (${apple ? '⌘' : 'Ctrl+'}${i + 1})',
                      child: InkWell(
                        onTap: () => _navigate(i),
                        focusColor: cs.primary.withValues(alpha: 0.16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 36),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                if (i == 0)
                                  HoneyMark(
                                    color: i == index
                                        ? cs.primary
                                        : cs.onSurfaceVariant,
                                    size: 18,
                                  )
                                else
                                  Icon(
                                    i == index ? selectedIcons[i] : icons[i],
                                    color: i == index
                                        ? cs.primary
                                        : cs.onSurfaceVariant,
                                    size: 18,
                                  ),
                                if (_expanded) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      labels[i],
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: i == index
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${apple ? '⌘' : 'Ctrl+'}${i + 1}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
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
