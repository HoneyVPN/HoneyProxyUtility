import '../models/subscription_model.dart';

/// All server surfaces follow the persisted subscription list. Manual profiles
/// stay first, and groups whose metadata is still loading keep their input order.
List<String> orderedSubscriptionGroups(
  Iterable<String> groups,
  List<SubscriptionModel> subscriptions,
) {
  final remaining = groups.toSet();
  return [
    if (remaining.remove('')) '',
    for (final subscription in subscriptions)
      if (remaining.remove(subscription.url)) subscription.url,
    ...remaining,
  ];
}

/// A drag carries an ID/URL pair, never stale subscription metadata. IDs may
/// be reused after deletion; matching the URL keeps a late drag on its feed.
List<SubscriptionModel> moveSubscription(
  List<SubscriptionModel> current,
  int id, {
  required String expectedUrl,
  int? beforeId,
  String? expectedBeforeUrl,
}) {
  if (id == beforeId && expectedUrl == expectedBeforeUrl) return current;
  final moved = current
      .where(
        (subscription) =>
            subscription.id == id && subscription.url == expectedUrl,
      )
      .firstOrNull;
  if (moved == null) return current;
  final result = current
      .where(
        (subscription) =>
            subscription.id != id || subscription.url != expectedUrl,
      )
      .toList();
  final anchor = result.indexWhere(
    (subscription) =>
        subscription.id == beforeId && subscription.url == expectedBeforeUrl,
  );
  result.insert(anchor < 0 ? result.length : anchor, moved);
  return result;
}
