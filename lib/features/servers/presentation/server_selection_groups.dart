import '../data/models/server_profile_model.dart';
import '../../subscriptions/data/models/subscription_model.dart';
import '../../subscriptions/data/services/subscription_order.dart';

/// A null subscription identifies the presentation-only favorites group.
/// Every profile appears once; its saved subscription and order stay intact.
class ServerSelectionGroup {
  const ServerSelectionGroup({
    required this.subscriptionId,
    required this.servers,
  });

  final String? subscriptionId;
  final List<ServerProfileModel> servers;
}

List<ServerSelectionGroup> serverSelectionGroups(
  List<ServerProfileModel> profiles,
  List<SubscriptionModel> subscriptions,
) {
  final grouped = <String, List<ServerProfileModel>>{};
  for (final profile in profiles) {
    (grouped[profile.subscriptionId] ??= []).add(profile);
  }
  final keys = orderedSubscriptionGroups(grouped.keys, subscriptions);
  final favorites = [
    for (final key in keys)
      ...grouped[key]!.where((profile) => profile.isFavorite),
  ];
  return [
    if (favorites.isNotEmpty)
      ServerSelectionGroup(subscriptionId: null, servers: favorites),
    for (final key in keys)
      if (grouped[key]!.any((profile) => !profile.isFavorite))
        ServerSelectionGroup(
          subscriptionId: key,
          servers: grouped[key]!
              .where((profile) => !profile.isFavorite)
              .toList(),
        ),
  ];
}
