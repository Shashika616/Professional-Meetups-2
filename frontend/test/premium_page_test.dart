import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';

/// The one Premium screen (Plan 20 Fix 3): three tiers fetched in one
/// call, each rendered from the store's own ProductDetails, degrading to
/// whatever subset the store actually returns; the entitled state marks the
/// held tier and disables buying.
class _FakeSubscriptionService implements SubscriptionService {
  _FakeSubscriptionService({this.products = const [], this.error});

  final List<ProductDetails> products;
  final Object? error;
  List<String>? requestedIds;

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async {
    requestedIds = productIds;
    if (error != null) throw error!;
    return products;
  }

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async => throw UnimplementedError();
}

ProductDetails _product(String id, String price, {String title = ''}) =>
    ProductDetails(
      id: id,
      title: title.isEmpty ? 'Premium $id' : title,
      description: 'All of TieHere Premium',
      price: price,
      rawPrice: 1,
      currencyCode: 'LKR',
    );

final _weekly = _product(premiumWeeklyProductId, 'Rs 390.00');
final _monthly = _product(premiumMonthlyProductId, 'Rs 1,490.00');
final _yearly = _product(premiumYearlyProductId, 'Rs 12,900.00');

Widget _app(
  _FakeSubscriptionService service, {
  SubscriptionStatus status = const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  ),
}) => ProviderScope(
  overrides: [
    subscriptionServiceProvider.overrideWithValue(service),
    subscriptionStatusProvider.overrideWith((ref) async => status),
  ],
  child: const MaterialApp(home: PremiumPage()),
);

void main() {
  testWidgets('asks the store for all three products in one call', (
    tester,
  ) async {
    final service = _FakeSubscriptionService(
      products: [_weekly, _monthly, _yearly],
    );
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(service.requestedIds, [
      premiumWeeklyProductId,
      premiumMonthlyProductId,
      premiumYearlyProductId,
    ]);
  });

  testWidgets('all three tiers render with the store prices, yearly '
      'featured and pre-selected, and SUBSCRIBE is live', (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(
      products: [_weekly, _monthly, _yearly],
    );
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    for (final tier in PremiumTier.values) {
      expect(find.byKey(Key('tier-${tier.productId}')), findsOneWidget);
    }
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    // The store's strings, verbatim: the yearly price appears on its row and
    // again on the featured card.
    expect(find.text('Rs 390.00'), findsOneWidget);
    expect(find.text('Rs 1,490.00'), findsOneWidget);
    expect(find.textContaining('Rs 12,900.00'), findsNWidgets(2));
    expect(find.text('Popular'), findsOneWidget);

    final button = tester.widget<PrimaryButton>(
      find.byKey(const Key('premiumSubscribe')),
    );
    expect(button.label, 'SUBSCRIBE');
    expect(button.onPressed, isNotNull);
  });

  testWidgets('with only monthly on sale, the screen offers monthly alone '
      'and features it rather than failing', (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(products: [_monthly]);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('tier-$premiumMonthlyProductId')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tier-$premiumWeeklyProductId')), findsNothing);
    expect(find.byKey(const Key('tier-$premiumYearlyProductId')), findsNothing);
    expect(find.textContaining('Rs 1,490.00'), findsNWidgets(2));
    expect(find.textContaining("isn't available"), findsNothing);
    expect(
      tester
          .widget<PrimaryButton>(find.byKey(const Key('premiumSubscribe')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('with two of three on sale, only the two render', (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(products: [_weekly, _yearly]);
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('tier-$premiumWeeklyProductId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tier-$premiumYearlyProductId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tier-$premiumMonthlyProductId')),
      findsNothing,
    );
  });

  testWidgets('with nothing on sale the screen says so and has no buy button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(find.textContaining("isn't available"), findsOneWidget);
    expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
    // The perks card is still there: what Premium gets you does not depend
    // on the store; only prices do, and none is shown.
    expect(find.text('This plan gets'), findsOneWidget);
    expect(find.text('TieHere Premium'), findsOneWidget);
    expect(find.textContaining('/year'), findsNothing);
    // Restore stays reachable regardless.
    expect(find.text('Restore Purchases'), findsOneWidget);
  });

  testWidgets('a store failure shows the load error, not a crash', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(error: Exception('store down'));
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load'), findsOneWidget);
    expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
    expect(find.text('This plan gets'), findsOneWidget);
  });

  testWidgets('an entitled account sees CURRENT PLAN on its own tier and '
      'cannot buy again', (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(
      products: [_weekly, _monthly, _yearly],
    );
    await tester.pumpWidget(
      _app(
        service,
        status: const SubscriptionStatus(
          tier: SubscriptionTier.premium,
          status: SubscriptionLifecycleStatus.active,
          productId: premiumMonthlyProductId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PREMIUM'), findsWidgets);
    expect(find.textContaining('Monthly plan'), findsOneWidget);
    // The badge sits on the monthly row (the featured card shows yearly,
    // which is not the held tier).
    final monthlyRow = find.byKey(const Key('tier-$premiumMonthlyProductId'));
    expect(
      find.descendant(of: monthlyRow, matching: find.text('CURRENT PLAN')),
      findsOneWidget,
    );
    final button = tester.widget<PrimaryButton>(
      find.byKey(const Key('premiumSubscribe')),
    );
    expect(button.label, 'CURRENT PLAN');
    expect(button.onPressed, isNull);
  });

  testWidgets('an entitled account whose product the backend does not name '
      'is still not sold a second subscription', (tester) async {
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final service = _FakeSubscriptionService(products: [_monthly, _yearly]);
    await tester.pumpWidget(
      _app(
        service,
        status: const SubscriptionStatus(
          tier: SubscriptionTier.premium,
          status: SubscriptionLifecycleStatus.active,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CURRENT PLAN'), findsOneWidget); // the button only
    expect(
      tester
          .widget<PrimaryButton>(find.byKey(const Key('premiumSubscribe')))
          .onPressed,
      isNull,
    );
  });

  test('SubscriptionStatus reads product_id off the wire when present', () {
    final withId = SubscriptionStatus.fromJson({
      'tier': 'premium',
      'status': 'active',
      'product_id': premiumYearlyProductId,
    });
    expect(withId.productId, premiumYearlyProductId);
    expect(PremiumTier.forProductId(withId.productId), PremiumTier.yearly);

    final without = SubscriptionStatus.fromJson({
      'tier': 'premium',
      'status': 'active',
    });
    expect(without.productId, isNull);
    expect(PremiumTier.forProductId(without.productId), isNull);
  });
}
