import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/l10n/strings.dart';
import '../../data/services/subscriptions_notifier.dart';

/// One progress state for manual, automatic and already-running refreshes.
/// The local lock also covers the gap before the notifier publishes its flag.
class SubscriptionRefreshAction extends ConsumerStatefulWidget {
  const SubscriptionRefreshAction({
    super.key,
    this.subscriptionId,
    this.size = 18,
  });
  final int? subscriptionId;
  final double size;
  @override
  ConsumerState<SubscriptionRefreshAction> createState() => _State();
}

class _State extends ConsumerState<SubscriptionRefreshAction> {
  bool _requested = false;
  bool _busy(SubscriptionsState? state) => widget.subscriptionId == null
      ? state?.refreshing.isNotEmpty == true
      : state?.isRefreshing(widget.subscriptionId!) == true;
  Future<void> _refresh() async {
    if (_requested || _busy(ref.read(subscriptionsProvider).value)) return;
    setState(() => _requested = true);
    try {
      final notifier = ref.read(subscriptionsProvider.notifier);
      final id = widget.subscriptionId;
      if (id == null) {
        await notifier.refreshAll();
      } else {
        await notifier.refresh(id);
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.read(stringsProvider).subscriptionUpdateFailed),
          ),
        );
    } finally {
      if (mounted) setState(() => _requested = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(subscriptionsProvider).value;
    final strings = ref.watch(stringsProvider);
    final running = _requested || _busy(state);
    final available = widget.subscriptionId == null
        ? state?.subs.isNotEmpty == true
        : state?.subs.any((sub) => sub.id == widget.subscriptionId) == true;
    return Semantics(
      liveRegion: running,
      value: running ? strings.refreshing : null,
      child: IconButton(
        tooltip: running
            ? strings.refreshing
            : widget.subscriptionId == null
            ? strings.refreshSubsTooltip
            : strings.locale == 'ru'
            ? 'Обновить'
            : 'Refresh',
        onPressed: available && !running ? _refresh : null,
        icon: RefreshingSyncIcon(running: running, size: widget.size),
      ),
    );
  }
}

class RefreshingSyncIcon extends StatefulWidget {
  const RefreshingSyncIcon({required this.running, required this.size});
  final bool running;
  final double size;
  @override
  State<RefreshingSyncIcon> createState() => _RefreshIconState();
}

class _RefreshIconState extends State<RefreshingSyncIcon>
    with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  void _sync() {
    final motion = MediaQuery.maybeOf(context);
    // A screen reader also enables accessibleNavigation on Flutter Web.
    // Keep progress visible unless the user specifically requests less motion.
    if (widget.running && motion?.disableAnimations != true) {
      if (!_turns.isAnimating) _turns.repeat();
    } else {
      _turns.stop();
      _turns.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant RefreshingSyncIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turns,
    child: Icon(
      Icons.sync_rounded,
      size: widget.size,
      color: widget.running ? Theme.of(context).colorScheme.primary : null,
    ),
  );
}
