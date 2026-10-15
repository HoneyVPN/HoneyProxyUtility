import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/subscriptions/data/models/subscription_model.dart';
import '../../../lib/features/subscriptions/data/services/subscription_order.dart';

void main() {
  const first = SubscriptionModel(
    id: 1,
    url: 'https://first.test/subscription',
    name: 'Same provider',
  );
  const second = SubscriptionModel(
    id: 2,
    url: 'https://second.test/subscription',
    name: 'Same provider',
  );

  test('manual profiles stay first while feeds follow the saved URL order', () {
    expect(
      orderedSubscriptionGroups(
        [
          first.url,
          'https://unknown-b.test/subscription',
          '',
          second.url,
          'https://unknown-a.test/subscription',
        ],
        [second, first],
      ),
      [
        '',
        second.url,
        first.url,
        'https://unknown-b.test/subscription',
        'https://unknown-a.test/subscription',
      ],
    );
  });

  test(
    'same-named feeds remain separate and empty feeds add no server group',
    () {
      expect(
        orderedSubscriptionGroups(
          [first.url, second.url],
          [
            second,
            const SubscriptionModel(
              id: 3,
              url: 'https://empty.test/subscription',
              name: 'Same provider',
            ),
            first,
          ],
        ),
        [second.url, first.url],
      );
    },
  );

  test('before metadata loads, unknown groups retain their original order', () {
    expect(
      orderedSubscriptionGroups([second.url, '', first.url, second.url], []),
      ['', second.url, first.url],
    );
  });
}
