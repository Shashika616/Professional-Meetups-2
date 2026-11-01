import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';

import 'support/fake_credit_service.dart';

/// The Premium page renders whatever the server's catalog offers (plan
/// 29C), at the prices the store returns.
class _FakeSubscriptionService implements SubscriptionService {
  _FakeSubscriptionService({this.products = const [], this.error});

  final List<ProductDetails> products;
  final Object? error;
  final List<List<String>> requests = [];

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async {
    requests.add(productIds);
    if (error != null) throw error!;
    return [
      for (final p in products)
        if (productIds.contains(p.id)) p,
    ];
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

class _SignedIn extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    profile: UserProfile(
      id: '00000000-0000-4000-8000-000000000040',
      fullName: 'Ada',
      trustLevel: 3,
    ),
  );
}

ProductDetails _product(String id, String price) => ProductDetails(
  id: id,
  title: id,
  description: '',
  price: price,
  rawPrice: 1,
  currencyCode: 'LKR',
);

final _monthly = _product('premium_monthly', 'Rs 1,490.00');
final _yearly = _product('premium_yearly', 'Rs 12,900.00');

/// The catalog the server sends, as JSON, so the page is tested against
/// the wire shape. A stray `price` is there on purpose: the app must never
/// show one from the server.
Catalog _catalog({required bool visible}) => Catalog.fromJson({
  'catalog_version': 1,
  'credit_packs': [],
  'plans_visible': visible,
  'plans': visible
      ? [
          {
            'code': 'pro',
            'product_ids': {
              'ios': 'premium_monthly',
              'android': 'premium_monthly',
            },
            'period': 'month',
            'title': 'TieHere Pro',
            'perks': [
              '10 meetups a month included',
              'Up to 30 people per meetup',
            ],
            'featured': false,
            'price': r'$999',
          },
          {
            'code': 'pro',
            'product_ids': {
              'ios': 'premium_yearly',
              'android': 'premium_yearly',
            },
            'period': 'year',
            'title': 'TieHere Pro',
            'perks': [
              '10 meetups a month included',
              'Up to 30 people per meetup',
            ],
            'featured': true,
          },
        ]
      : [],
  'legal': {
    'terms_url': 'https://example.com/terms',
    'privacy_url': 'https://example.com/privacy',
  },
});

class _Harness {
  _Harness({
    required bool visible,
    List<ProductDetails>? products,
    Object? storeError,
    this.status,
  }) : credits = FakeCreditService(catalogResult: _catalog(visible: visible)),
       store = _FakeSubscriptionService(
         products: products ?? [_monthly, _yearly],
         error: storeError,
       );

  final FakeCreditService credits;
  final _FakeSubscriptionService store;
  final SubscriptionStatus? status;
  final List<PurchaseParam> bought = [];
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      authSessionProvider.overrideWith(_SignedIn.new),
      creditServiceProvider.overrideWithValue(credits),
      subscriptionServiceProvider.overrideWithValue(store),
      appConfigProvider.overrideWith((ref) async => RemoteAppConfig.defaults),
      subscriptionStatusProvider.overrideWith(
        (ref) async =>
            status ??
            const SubscriptionStatus(
              tier: SubscriptionTier.free,
              status: SubscriptionLifecycleStatus.none,
            ),
      ),
    ],
  );

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: PremiumPage(
        platform: 'ios',
        purchaseUpdates: const Stream.empty(),
        buyNonConsumable: (p) async {
          bought.add(p);
          return true;
        },
        completePurchase: (_) async {},
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  addTearDown(h.container.dispose);
  await tester.pumpWidget(h.app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'with plans hidden there are no plans, no buy button, and the store is not asked',
    (tester) async {
      final h = _Harness(visible: false);
      await _pump(tester, h);
      expect(find.byKey(const Key('premiumHidden')), findsOneWidget);
      expect(find.byKey(const Key('tier-premium_monthly')), findsNothing);
      expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
      expect(h.store.requests, isEmpty);
      expect(find.text('Restore purchases'), findsOneWidget);
    },
  );

  testWidgets(
    'the same running page shows the plans once the server turns them on',
    (tester) async {
      final h = _Harness(visible: false);
      await _pump(tester, h);
      expect(find.byKey(const Key('tier-premium_yearly')), findsNothing);

      // The flag turns on server-side; the app asks again (resume, reopen).
      h.credits.catalogResult = _catalog(visible: true);
      h.container.invalidate(catalogProvider);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('premiumHidden')), findsNothing);
      expect(find.byKey(const Key('tier-premium_monthly')), findsOneWidget);
      expect(find.byKey(const Key('tier-premium_yearly')), findsOneWidget);
      expect(h.store.requests.last, ['premium_monthly', 'premium_yearly']);
      // Titles, perks, featured and legal links are the catalog's.
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Yearly'), findsOneWidget);
      expect(find.text('10 meetups a month included'), findsOneWidget);
      expect(find.text('Popular'), findsOneWidget);
      expect(find.byKey(const Key('premiumTerms')), findsOneWidget);
      expect(find.byKey(const Key('premiumPrivacy')), findsOneWidget);
      // Weekly is gone because the catalog does not list it.
      expect(find.text('Weekly'), findsNothing);
    },
  );

  testWidgets('prices are the store\'s, never the server\'s', (tester) async {
    final h = _Harness(visible: true);
    await _pump(tester, h);
    expect(find.text('Rs 1,490.00'), findsOneWidget);
    expect(find.text('Rs 12,900.00'), findsOneWidget);
    expect(find.textContaining(r'$999'), findsNothing);
  });

  testWidgets('a product the store does not return is skipped', (tester) async {
    final h = _Harness(visible: true, products: [_monthly]);
    await _pump(tester, h);
    expect(find.byKey(const Key('tier-premium_monthly')), findsOneWidget);
    expect(find.byKey(const Key('tier-premium_yearly')), findsNothing);
    final button = tester.widget<PrimaryButton>(
      find.byKey(const Key('premiumSubscribe')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('nothing on sale says so and offers no buy button', (
    tester,
  ) async {
    final h = _Harness(visible: true, products: const []);
    await _pump(tester, h);
    expect(find.textContaining("isn't available"), findsOneWidget);
    expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
  });

  testWidgets('a store failure shows the load error', (tester) async {
    final h = _Harness(visible: true, storeError: Exception('store down'));
    await _pump(tester, h);
    expect(find.textContaining('Could not load'), findsOneWidget);
    expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
  });

  testWidgets('a catalog that cannot load offers a retry', (tester) async {
    final h = _Harness(visible: true)..credits.catalogError = Exception('down');
    await _pump(tester, h);
    expect(find.text('Try again'), findsOneWidget);
    h.credits.catalogError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tier-premium_yearly')), findsOneWidget);
  });

  testWidgets('subscribing buys the featured plan with the account token', (
    tester,
  ) async {
    final h = _Harness(visible: true);
    await _pump(tester, h);
    await tester.tap(find.byKey(const Key('premiumSubscribe')));
    await tester.pump();
    expect(h.bought, hasLength(1));
    expect(h.bought.single.productDetails.id, 'premium_yearly');
    expect(
      h.bought.single.applicationUserName,
      accountToken('00000000-0000-4000-8000-000000000040'),
    );
  });

  testWidgets('an entitled account sees its plan marked and cannot buy again', (
    tester,
  ) async {
    final h = _Harness(
      visible: true,
      status: SubscriptionStatus.fromJson({
        'status': 'active',
        'plan_code': 'pro',
        'product_id': 'premium_monthly',
        'auto_renew': true,
        'entitled': true,
        'current_period_end_unix_seconds': 1893456000,
      }),
    );
    await _pump(tester, h);
    final monthly = find.byKey(const Key('tier-premium_monthly'));
    expect(
      find.descendant(of: monthly, matching: find.text('Current plan')),
      findsOneWidget,
    );
    expect(find.textContaining('Monthly plan'), findsOneWidget);
    final button = tester.widget<PrimaryButton>(
      find.byKey(const Key('premiumSubscribe')),
    );
    expect(button.label, 'Current plan');
    expect(button.onPressed, isNull);
  });

  testWidgets('plans listed under plans_visible false are still not shown', (
    tester,
  ) async {
    final h = _Harness(visible: true);
    final listed = _catalog(visible: true);
    h.credits.catalogResult = Catalog(
      version: listed.version,
      creditPacks: listed.creditPacks,
      plansVisible: false,
      plans: listed.plans,
    );
    await _pump(tester, h);
    expect(find.byKey(const Key('tier-premium_yearly')), findsNothing);
    expect(find.byKey(const Key('premiumSubscribe')), findsNothing);
    expect(h.store.requests, isEmpty);
  });
}
