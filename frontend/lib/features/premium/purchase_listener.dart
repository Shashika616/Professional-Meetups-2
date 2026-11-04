import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

/// The app's one purchase listener (N1-D2): null while signed out, and
/// started by [AppShell] after sign-in. It belongs to the signed-in user, so
/// a change of account builds a new one. The balance and plan refresh here,
/// because a redelivered purchase can land with no page open.
final purchaseFlowProvider = Provider<PurchaseFlowController?>((ref) {
  final userId = ref.watch(
    authSessionProvider.select((s) => s.value?.session?.userId),
  );
  if (userId == null) return null;
  final credits = ref.read(creditServiceProvider);
  final controller = PurchaseFlowController(
    subscriptionService: ref.read(subscriptionServiceProvider),
    creditService: credits,
    platform: ClientInfoHttpClient.currentPlatform(),
    loadCatalog: credits.catalog,
  );
  PurchaseGrant? grant;
  SubscriptionStatus? status;
  controller.addListener(() {
    if (!identical(controller.lastGrant, grant)) {
      grant = controller.lastGrant;
      ref.invalidate(walletProvider);
    }
    if (!identical(controller.lastVerifiedStatus, status)) {
      status = controller.lastVerifiedStatus;
      ref.invalidate(subscriptionStatusProvider);
    }
  });
  ref.onDispose(controller.dispose);
  return controller;
});
