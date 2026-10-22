import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/utils/debug_log.dart';
import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/deadline_http_client.dart';
import 'package:professional_connections_platform/core/services/oauth_state.dart';
import 'package:professional_connections_platform/core/services/sign_in_nonce.dart';

part 'http_auth/sign_in.dart';
part 'http_auth/verification.dart';
part 'http_auth/account.dart';
part 'http_auth/safety.dart';

/// Backstop only — how long to wait for the LinkedIn redirect before giving
/// up, on the rare chance the app-resume-based detection below
/// ([_AppResumedSignal]) doesn't fire (e.g. some Android OEM skins deliver
/// lifecycle callbacks unreliably). In the common case (the user completes
/// sign-in, or closes the browser without finishing), [_resumeGracePeriod]
/// is what actually ends the wait, in a couple of seconds either way — this
/// is just the ceiling.
const Duration _redirectTimeout = Duration(minutes: 5);

/// How long to wait, after this app returns to the foreground, for the
/// LinkedIn redirect to actually arrive before concluding the user closed
/// the browser without completing sign-in. There's no direct OS signal for
/// "the user dismissed the external browser" — [AppLifecycleState.resumed]
/// is the closest proxy (this app regains focus either way: on a
/// successful redirect back into the app, or on the user manually
/// closing/backgrounding the browser) — so this window has to be long
/// enough for a genuine redirect to be delivered by `app_links` after
/// resume (typically near-instant, well under a second) without being so
/// long that a real cancellation still feels like a hang.
const Duration _resumeGracePeriod = Duration(seconds: 2);

/// Real [AuthService] wired to the gateway (`backend/PLAN.md` Step 5's REST
/// contract) and LinkedIn's OAuth authorization endpoint directly
/// (`client_id` is public — no backend round trip needed just to start the
/// flow, per `backend/PLAN.md` Step 4).
class HttpAuthService extends _HttpAuthBase
    with _SignInMethods, _VerificationMethods, _AccountMethods, _SafetyMethods {
  HttpAuthService({
    http.Client? httpClient,
    AppLinks? appLinks,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
    // EVERY request this service makes goes through the deadline
    // wrapper (#78), including one injected by a test — a test client
    // with no timeout would prove the production path works when it
    // does not.
  }) : super._(
         DeadlineHttpClient(httpClient ?? http.Client()),
         appLinks ?? AppLinks(),
         baseUrl ?? AppConfig.gatewayBaseUrl,
         getAccessToken ?? (() async => null),
       );

  /// Apple's one-time out-of-band name, as a single string — the two parts
  /// joined with a space, with either missing or blank part simply left out,
  /// and `''` when Apple gave neither (the common case on every
  /// authorization after the user's first). Never throws and never guesses:
  /// an empty result means "no name", which the server treats as "no hint".
  @visibleForTesting
  static String appleFullNameHint(AuthorizationCredentialAppleID credential) {
    return [credential.givenName, credential.familyName]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' ');
  }
}

/// The state and the HTTP plumbing every group of [HttpAuthService]
/// methods shares. The methods themselves live in one mixin per concern,
/// in `http_auth/`: split by file so each reads on its own, without
/// changing the class, its constructor, or a single call site. Part files
/// rather than separate libraries because the mixins need these private
/// helpers, and Dart privacy is per library.
abstract class _HttpAuthBase implements AuthService {
  _HttpAuthBase._(
    this._httpClient,
    this._appLinks,
    this._baseUrl,
    this._getAccessToken,
  );

  final http.Client _httpClient;
  final AppLinks _appLinks;
  final String _baseUrl;

  /// Supplies the current access token for the `/v1/verification/*` and
  /// `/v1/users/me` calls below, which the gateway's new auth middleware
  /// requires (backend/PLAN.md's Level 2/3 addendum, Step F). Reads from
  /// wherever the caller's session state actually lives (wired in
  /// `app_providers.dart` to secure storage) rather than this service
  /// holding its own copy — [HttpAuthService] otherwise has no session
  /// state of its own, and this keeps it that way.
  final Future<String?> Function() _getAccessToken;

  Future<int> _startVerification(
    String path,
    Map<String, String> body, {
    // A 400 on a Start call means something else entirely from a 400 on a
    // Verify call (there's no code yet to be "invalid") — generic by
    // default; StartCorporateEmailVerification overrides this with the one
    // Start-call-specific case that needs its own exception type.
    AuthException Function(String message) on400 = AuthNetworkException.new,
  }) async {
    final response = await _authenticatedPost(path, body);
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['resend_after_seconds'] as int? ?? 0;
    }
    throw _mapVerificationError(response, on400: on400, isResend: true);
  }

  Future<AuthSession> _verifyCode(String path, Map<String, String> body) async {
    final response = await _authenticatedPost(path, body);
    return _parseVerificationSession(response);
  }

  AuthSession _parseVerificationSession(http.Response response) {
    if (response.statusCode == 200) {
      return AuthSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(
      response,
      on400: InvalidVerificationCodeException.new,
    );
  }

  /// Shared status-code mapping for every `/v1/verification/*` and
  /// `/v1/users/me` call. [on400] is the one thing that genuinely differs
  /// per endpoint (a domain-rejection vs. a wrong/expired code) — every
  /// other status means the same thing regardless of which of these
  /// endpoints produced it.
  AuthException _mapVerificationError(
    http.Response response, {
    required AuthException Function(String message) on400,
    // Only a Start call's 429 is a resend cooldown. Anywhere else (a
    // verify, a contact, an SOS, a profile write) it is plain rate
    // limiting, and "wait before requesting another code" would be a
    // wrong thing to tell someone who never asked for one.
    bool isResend = false,
  }) {
    final message = _errorMessage(response.body);
    switch (response.statusCode) {
      case 400:
        return on400(message);
      case 401:
        // The access token itself was missing/invalid/expired — the
        // gateway's auth middleware rejected the request before it ever
        // reached the auth service. Same "treat the session as gone"
        // handling as a rejected refresh token.
        return SessionExpiredException(message);
      case 429:
        return isResend
            ? const ResendCooldownException()
            : const RateLimitedException();
      default:
        return AuthNetworkException(message);
    }
  }

  Future<http.Response> _authenticatedPost(
    String path,
    // dynamic values (not just String) — the SOS/location routes send
    // doubles (latitude/longitude), unlike every prior caller here, which
    // only ever sent strings.
    Map<String, dynamic> body,
  ) async {
    final headers = await _authHeaders();
    return _httpClient.post(
      Uri.parse('$_baseUrl$path'),
      headers: headers,
      body: jsonEncode(body),
    );
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    // No token means the session is gone from storage entirely — not
    // merely stale, which getValidSession() would have refreshed before
    // returning. Sending the request without an Authorization header buys
    // a guaranteed 401 that no refresh can repair (there is no refresh
    // token left to send), and a provider that retries would keep doing it
    // forever. Fail here with the same exception a real 401 maps to, so
    // AppShell's session-expired listener lands the user on LandingPage.
    if (token == null) {
      throw const SessionExpiredException(
        'Your session has expired. Please sign in again.',
      );
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  /// Waits for the deep-link redirect from the LinkedIn browser flow —
  /// checking a cold-start link first (the OS may have relaunched the app),
  /// then the live stream. [expectedState] scopes this to *this* sign-in
  /// attempt: [AppLinks.getInitialLink] reflects the most recent deep link
  /// the OS has delivered, not the one for this specific attempt — on
  /// Android's singleTop launch mode in particular, it keeps returning a
  /// prior attempt's already-consumed redirect until a genuinely new one
  /// arrives, so a retry right after a failed attempt would otherwise be
  /// "completed" by that stale leftover instead of the user's fresh browser
  /// round trip. See [resolveAuthRedirect] for the actual filtering logic.
  ///
  /// Registers an [_AppResumedSignal] for the duration of the wait so a
  /// user closing the external browser without finishing sign-in is
  /// detected in ~[_resumeGracePeriod], not the full [_redirectTimeout] —
  /// see [resolveAuthRedirect]'s `appResumedEvents` doc comment.
  Future<Uri> _awaitRedirect(String expectedState) async {
    final resumedSignal = _AppResumedSignal()..start();
    try {
      return await resolveAuthRedirect(
        initialLink: _appLinks.getInitialLink(),
        redirectStream: _appLinks.uriLinkStream,
        expectedState: expectedState,
        timeout: _redirectTimeout,
        appResumedEvents: resumedSignal.onResumed,
        resumeGracePeriod: _resumeGracePeriod,
      );
    } finally {
      resumedSignal.stop();
    }
  }

  AuthSession _parseSessionResponse(
    http.Response response, {
    bool isRefresh = false,
    // Every session-issuing route means something different by a 400/401 —
    // LinkedIn/federated/email-signup's 400 is "invalid grant/code," but
    // email-signup's OTP 400 is "wrong/expired code" instead
    // ([InvalidVerificationCodeException]); refresh's 401 is "your session
    // died," but email/login's 401 is "wrong credentials, no session ever
    // existed" ([InvalidCredentialsException]) — defaults match the
    // original LinkedIn/refresh-token behavior, callers override only the
    // one code that genuinely differs for their route.
    AuthException Function(String message) on400 = InvalidGrantException.new,
    AuthException Function(String message) on401 = SessionExpiredException.new,
  }) {
    if (response.statusCode == 200) {
      return AuthSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }

    final message = _errorMessage(response.body);
    // THE ONE 409 THESE ROUTES CAN PRODUCE, and the reason this check lives
    // here rather than at the three signup call sites: Apple, Google and
    // LinkedIn all funnel through this method, and a rule kept in three
    // places is a rule that is wrong in at least one of them.
    //
    // Matched on `code`, never on the sentence: the app opens a whole
    // screen on this, and matching prose would break the first time the
    // wording improved. A 409 without the code, or without a ticket, falls
    // through to the generic path below with the server's own sentence,
    // which is the right outcome for a client that cannot act on it.
    if (response.statusCode == 409) {
      final claim = _accountClaimRequired(response.body, message);
      if (claim != null) throw claim;
    }
    switch (response.statusCode) {
      case 400:
        throw on400(message);
      case 429:
        throw const RateLimitedException();
      case 401:
        throw on401(message);
      default:
        throw AuthNetworkException(message);
    }
  }

  /// Reads the claim detail out of a 409 body, or null when it is not one.
  ///
  /// Tolerant by construction: a body that is not JSON, is missing the code
  /// or has no ticket returns null rather than throwing, because a parse
  /// failure here would replace a usable error message with a crash during
  /// sign-in.
  AccountClaimRequiredException? _accountClaimRequired(
    String body,
    String message,
  ) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['code'] != 'account_claim_required') return null;
      final ticket = decoded['ticket'] as String? ?? '';
      if (ticket.isEmpty) return null;
      return AccountClaimRequiredException(
        ticket: ticket,
        email: decoded['email'] as String? ?? '',
        resendAfterSeconds: decoded['resend_after_seconds'] as int? ?? 0,
        message: message,
      );
    } catch (_) {
      return null;
    }
  }

  String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // fall through to the generic message below
    }
    return 'Something went wrong. Please try again.';
  }
}

/// Maps a [SignInWithAppleException] to a clean [AuthException] for display.
///
/// Every subtype's `message`/`description` is raw native platform detail
/// (e.g. `The operation couldn't be completed.
/// (com.apple.AuthenticationServices.AuthorizationError error 1000.)`) —
/// never fit for a user-facing toast. This is logged via [debugPrint] (so
/// it's still visible in dev/crash logs) and replaced with a static,
/// friendly message; a genuine user-initiated cancellation is distinguished
/// and mapped to [SignInCancelledException] instead, which callers render
/// with a softer, non-alarming toast style.
///
/// Extracted as a pure top-level function so this mapping is unit-testable
/// without invoking the real (platform-only) Sign in with Apple SDK.
@visibleForTesting
AuthException mapAppleSignInError(SignInWithAppleException error) {
  if (error is SignInWithAppleAuthorizationException &&
      error.code == AuthorizationErrorCode.canceled) {
    return const SignInCancelledException();
  }
  // Type and code only, never the object, AND only in debug builds
  // (#94): a platform exception's toString() can carry more than a log
  // should (same rule as every other catch in this codebase).
  debugLog(
    'Sign in with Apple failed: ${error.runtimeType}'
    '${error is SignInWithAppleAuthorizationException ? ' ${error.code}' : ''}',
  );
  return const AuthNetworkException(
    'Sign in with Apple isn’t available right now. Please try again or '
    'use another option.',
  );
}

/// Maps a [GoogleSignInException] to a clean [AuthException] for display —
/// same rationale and shape as [mapAppleSignInError]; [error.description]
/// is raw platform detail that must never reach a user-facing toast.
@visibleForTesting
AuthException mapGoogleSignInError(GoogleSignInException error) {
  if (error.code == GoogleSignInExceptionCode.canceled) {
    return const SignInCancelledException();
  }
  debugLog('Google Sign-In failed: ${error.code} ${error.description}');
  return const AuthNetworkException(
    'Google Sign-In isn’t available right now. Please try again or '
    'use another option.',
  );
}

/// Picks the deep-link redirect that actually belongs to the sign-in
/// attempt identified by [expectedState], preferring [initialLink] if it's
/// a match and otherwise waiting on [redirectStream] for one that is.
///
/// Extracted from [HttpAuthService] so this filtering — the fix for a
/// retry-after-failure bug where a stale `getInitialLink()` value from a
/// prior attempt was accepted as the current attempt's response — is
/// testable without the real `app_links` plugin, which is a platform-backed
/// singleton that can't be faked in `flutter test`.
///
/// [appResumedEvents], if provided, is a stream of "this app returned to
/// the foreground" events (see [_AppResumedSignal]) — the first such event
/// starts a [resumeGracePeriod] timer, and if no matching redirect has
/// arrived by the time it fires, this throws [SignInCancelledException]
/// immediately rather than waiting out the full [timeout]. This is what
/// makes closing the external browser without completing sign-in feel
/// instant instead of leaving the caller's "signing in..." state spinning
/// for minutes. Optional (defaults to `null`, i.e. [timeout] alone decides)
/// so existing callers/tests that don't care about this fast path are
/// unaffected.
@visibleForTesting
Future<Uri> resolveAuthRedirect({
  required Future<Uri?> initialLink,
  required Stream<Uri> redirectStream,
  required String expectedState,
  required Duration timeout,
  Stream<void>? appResumedEvents,
  Duration resumeGracePeriod = const Duration(seconds: 2),
}) async {
  final initial = await initialLink;
  if (initial != null && _isAuthRedirectFor(initial, expectedState)) {
    return initial;
  }

  final redirectCompleter = Completer<Uri>();
  final redirectSub = redirectStream
      .where((uri) => _isAuthRedirectFor(uri, expectedState))
      .listen((uri) {
        if (!redirectCompleter.isCompleted) redirectCompleter.complete(uri);
      });

  // Only the first resume matters — cancel this subscription as soon as it
  // fires so a later, unrelated resume (e.g. backgrounding the app again
  // after a successful sign-in already completed) can't do anything.
  StreamSubscription<void>? resumeSub;
  Timer? graceTimer;
  resumeSub = appResumedEvents?.listen((_) {
    resumeSub?.cancel();
    graceTimer = Timer(resumeGracePeriod, () {
      if (!redirectCompleter.isCompleted) {
        redirectCompleter.completeError(const SignInCancelledException());
      }
    });
  });

  try {
    return await redirectCompleter.future.timeout(
      timeout,
      onTimeout: () => throw const SignInCancelledException(),
    );
  } finally {
    unawaited(redirectSub.cancel());
    unawaited(resumeSub?.cancel());
    graceTimer?.cancel();
  }
}

bool _isAuthRedirectFor(Uri uri, String expectedState) =>
    uri.scheme == AppConfig.appRedirectScheme &&
    uri.queryParameters['state'] == expectedState;

/// A broadcast signal of [AppLifecycleState.resumed] events — the closest
/// available proxy for "the user closed/backgrounded an externally-launched
/// browser and control returned to this app," since there's no direct OS
/// callback for that. Registered only for the duration of a single sign-in
/// attempt ([HttpAuthService._awaitRedirect]), not for the app's whole
/// lifetime.
class _AppResumedSignal extends WidgetsBindingObserver {
  final _controller = StreamController<void>.broadcast();

  Stream<void> get onResumed => _controller.stream;

  void start() => WidgetsBinding.instance.addObserver(this);

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller.add(null);
  }
}
