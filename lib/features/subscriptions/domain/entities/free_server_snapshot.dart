/// A lease for one free-feed mutation. Removing, restoring, or refreshing its
/// profile invalidates older requests before they can publish fetched data.
class FreeServerSnapshot {
  const FreeServerSnapshot({
    required this.revision,
    required this.removed,
    required this.present,
  });

  final int revision;
  final bool removed;
  final bool present;
}

class SubscriptionReplacement {
  const SubscriptionReplacement({required this.count, required this.applied});

  final int count;
  final bool applied;
}
