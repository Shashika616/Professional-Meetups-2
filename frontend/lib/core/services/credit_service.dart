import 'package:professional_connections_platform/core/models/credits.dart';

/// Credits and the billing catalog (plan 29C, docs/api/billing.md). Same
/// `abstract interface class` + HTTP implementation pattern as
/// [MeetupService]; tests use `test/support/fake_credit_service.dart`.
///
/// The server decides everything with money in it. This service only
/// carries what the user chose (a capacity, a start time, a store
/// purchase) and returns what the server answered.
abstract interface class CreditService {
  /// The caller's balance. A 503 is [Wallet.empty], not an error: a
  /// provider that threw would retry it in a loop.
  Future<Wallet> wallet();

  /// One page of history, newest first. [cursor] is the previous page's
  /// [LedgerPage.nextCursor].
  Future<LedgerPage> ledger({String? cursor});

  /// What creating this meetup would cost now. No safe default: an
  /// unreachable server is [CreditUnavailableException].
  Future<CreditQuote> quote({
    required int capacity,
    required DateTime windowStart,
  });

  /// The caller's plan and limits. A 503 is [Entitlements.fallback].
  Future<Entitlements> entitlements();

  /// What the app may offer this caller. A 503 is [Catalog.empty].
  Future<Catalog> catalog();

  /// Sends a credit pack purchase to the server. The store transaction may
  /// be completed only after this returns.
  Future<PurchaseGrant> verifyPurchase({
    required String platform,
    required String productId,
    required String token,
  });
}

/// Typed errors a [CreditService] throws.
sealed class CreditException implements Exception {
  const CreditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The request never reached the server (no connection, a timeout).
class CreditOfflineException extends CreditException {
  const CreditOfflineException([
    super.message = 'No connection. Check your network and try again.',
  ]);
}

/// 401: the session is gone.
class CreditSessionExpiredException extends CreditException {
  const CreditSessionExpiredException([
    super.message = 'Your session has expired. Please sign in again.',
  ]);
}

/// 503: billing cannot be reached, or the store cannot be verified right
/// now. A purchase that gets this stays pending and is tried again.
class CreditUnavailableException extends CreditException {
  const CreditUnavailableException([
    super.message =
        'Credits are not available right now. Please try again in a moment.',
  ]);
}

/// 400, 403 or 409: the server refused this, with a sentence that says why
/// (a purchase it could not verify, one for another account, one still
/// pending with the store).
class CreditRejectedException extends CreditException {
  const CreditRejectedException(super.message, {required this.statusCode});

  final int statusCode;
}

/// 426: this build is too old for this (N1-D4). The client also raises
/// [UpdateRequired], which brings up the update screen.
class CreditUpdateRequiredException extends CreditException {
  const CreditUpdateRequiredException([
    super.message = 'Update TieHere to continue.',
  ]);
}

/// Anything else: a 5xx, an unreadable answer.
class CreditServerException extends CreditException {
  const CreditServerException([
    super.message = 'Something went wrong. Please try again.',
  ]);
}
