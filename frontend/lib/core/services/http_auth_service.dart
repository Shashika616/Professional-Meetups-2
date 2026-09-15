import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/oauth_state.dart';
import 'package:professional_connections_platform/core/services/sign_in_nonce.dart';

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
class HttpAuthService implements AuthService {
  HttpAuthService({
    http.Client? httpClient,
    AppLinks? appLinks,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
  }) : _httpClient = httpClient ?? http.Client(),
       _appLinks = appLinks ?? AppLinks(),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null);

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

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async {
    final code = await _runLinkedInOAuthFlow();
    return completeLinkedInOnboarding(
      authorizationCode: code,
      redirectUri: AppConfig.linkedInRedirectUri,
      ageConfirmedOver18: ageConfirmedOver18,
    );
  }

  /// Links LinkedIn to the CALLER's already-authenticated account
  /// (Profile's "Connect LinkedIn," ADR-014) — runs the identical OAuth
  /// browser/deep-link round trip as [signInWithLinkedIn], but POSTs to the
  /// authenticated `/v1/auth/identities/link` route instead of
  /// `/v1/auth/linkedin/callback`, so linking never creates a second
  /// account.
  @override
  Future<AuthSession> linkLinkedIn() async {
    final code = await _runLinkedInOAuthFlow();
    final headers = await _authHeaders();
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/identities/link'),
      headers: headers,
      body: jsonEncode({
        'provider': 'linkedin',
        'authorization_code': code,
        'redirect_uri': AppConfig.linkedInRedirectUri,
      }),
    );
    return _parseSessionResponse(response);
  }

  /// Drives the out-of-app LinkedIn OAuth browser flow through to a
  /// verified authorization code — shared by [signInWithLinkedIn] (which
  /// posts it to the account-creating callback route) and [linkLinkedIn]
  /// (which posts the identical code shape to the authenticated linking
  /// route instead). Extracting this avoids the two flows' CSRF/redirect-
  /// handling logic drifting apart from each other over time.
  Future<String> _runLinkedInOAuthFlow() async {
    final state = OAuthState.generate();

    // Deliberately no code_challenge/code_challenge_method (PKCE) here —
    // LinkedIn's Sign In with LinkedIn / OpenID Connect product rejects the
    // token exchange outright when they're present (confirmed via direct
    // testing against LinkedIn's real endpoint: identical requests succeed
    // with PKCE omitted, fail with 401 invalid_client when included).
    // Security is still sound without it: this is a confidential client —
    // the LinkedIn client_secret lives only in the backend, never in this
    // app — which is what PKCE exists to substitute for on a public client
    // that can't hold a secret.
    final authorizationUrl =
        Uri.https('www.linkedin.com', '/oauth/v2/authorization', {
          'response_type': 'code',
          'client_id': AppConfig.linkedInClientId,
          'redirect_uri': AppConfig.linkedInRedirectUri,
          'state': state,
          'scope': 'openid profile email',
        });

    // Opens the system browser, not an in-app WebView — a WebView can't be
    // trusted the same way for OAuth (backend/PLAN.md's frontend plan,
    // Step 1).
    final launched = await launchUrl(
      authorizationUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      throw const AuthNetworkException(
        'Could not open the browser to sign in.',
      );
    }

    final redirect = await _awaitRedirect(state);

    if (redirect.queryParameters.containsKey('error')) {
      throw InvalidGrantException(
        redirect.queryParameters['error_description'] ??
            redirect.queryParameters['error']!,
      );
    }

    final returnedState = redirect.queryParameters['state'];
    // CSRF protection: verify state before the authorization code is used
    // for anything else. Belt-and-suspenders — _awaitRedirect already only
    // ever returns a URI whose state matches, but the code below is about
    // to spend an authorization code, so this stays as the explicit final
    // check regardless of how the URI got here.
    if (returnedState == null || returnedState != state) {
      throw const InvalidGrantException(
        'Sign-in response did not match the request that started it.',
      );
    }

    final code = redirect.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const InvalidGrantException(
        'LinkedIn did not return an authorization code.',
      );
    }
    return code;
  }

  /// The POST-and-parse half of [signInWithLinkedIn], split out so it's
  /// unit-testable (Step 8) without driving the actual out-of-app browser
  /// and deep-link round trip, which isn't automatable in `flutter test`.
  @visibleForTesting
  Future<AuthSession> completeLinkedInOnboarding({
    required String authorizationCode,
    required String redirectUri,
    required bool ageConfirmedOver18,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/linkedin/callback'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'authorization_code': authorizationCode,
        'redirect_uri': redirectUri,
        'age_confirmed_over_18': ageConfirmedOver18,
      }),
    );
    return _parseSessionResponse(response);
  }

  /// Sign in with Apple (ADR-014) — Apple's native SDK hands this app an
  /// `identityToken` (JWT) directly; unlike LinkedIn, there's no browser
  /// round trip or backend code-exchange step, just a straight POST of the
  /// already-signed token.
  ///
  /// Apple only ever includes [AuthorizationCredentialAppleID.givenName]/
  /// `familyName` out-of-band on the native credential object, never inside
  /// the JWT itself — the backend's id_token verification
  /// (`internal/identity`) has no way to see it, so a brand-new Apple
  /// signup's `full_name` comes back empty from the server, same as any
  /// other "name not yet known" case this app already renders as "Member"
  /// (`ProfilePage`/`HomePage`'s existing fallback display, not a new gap
  /// introduced here).
  @override
  Future<AuthSession> signInWithApple({
    required bool ageConfirmedOver18,
  }) async {
    // A fresh nonce for THIS attempt. Apple gets the hash (which it embeds
    // in the id_token's `nonce` claim); the backend gets the raw pre-image
    // and hashes it to compare. See [SignInNonce] for why it has to be that
    // way round.
    final nonce = SignInNonce.generate();

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonce.hashed,
      );
    } on SignInWithAppleException catch (error) {
      // Catches every subtype (SignInWithAppleAuthorizationException,
      // SignInWithAppleNotSupportedException,
      // SignInWithAppleCredentialsException, ...) in one place — dispatch
      // on the concrete type happens inside mapAppleSignInError.
      throw mapAppleSignInError(error);
    }

    final idToken = credential.identityToken;
    if (idToken == null || idToken.isEmpty) {
      throw const AuthNetworkException(
        'Apple did not return an identity token.',
      );
    }

    return _completeFederatedSignup(
      provider: 'apple',
      idToken: idToken,
      nonce: nonce.raw,
      ageConfirmedOver18: ageConfirmedOver18,
    );
  }

  /// Google Sign-In (ADR-014) — same "native SDK hands us an id_token,
  /// straight POST, no code exchange" shape as [signInWithApple]. Requires
  /// [AppConfig.googleServerClientId] to be set (the separate Web OAuth
  /// client, not the Android app's own client) — see that field's doc
  /// comment for why.
  @override
  Future<AuthSession> signInWithGoogle({
    required bool ageConfirmedOver18,
  }) async {
    if (AppConfig.googleServerClientId.isEmpty) {
      throw const AuthNetworkException('Google Sign-In is not configured yet.');
    }

    try {
      final nonce = await _ensureGoogleSignInInitialized();
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthNetworkException(
          'Google did not return an identity token.',
        );
      }
      return await _completeFederatedSignup(
        provider: 'google',
        idToken: idToken,
        nonce: nonce.raw,
        ageConfirmedOver18: ageConfirmedOver18,
      );
    } on GoogleSignInException catch (error) {
      // Dispatch on error.code happens inside mapGoogleSignInError.
      throw mapGoogleSignInError(error);
    }
  }

  /// `GoogleSignIn.instance.initialize` "must be called on this instance
  /// exactly once" per its own doc comment — memoized so repeated
  /// [signInWithGoogle] calls (a user backing out and retrying) don't
  /// re-initialize the singleton.
  ///
  /// This memoization is also why the Google nonce is per-APP-RUN rather
  /// than per-attempt, unlike Apple's: `google_sign_in` 7.x takes the nonce
  /// on `initialize`, not on `authenticate`, and its own docs say calling
  /// `initialize` more than once "will result in undefined behavior" — so
  /// there is no supported way to rotate it per sign-in. The nonce is
  /// generated once here, alongside that single call, and reused for every
  /// Google attempt in this process.
  ///
  /// That is weaker than Apple's per-attempt nonce, and worth being precise
  /// about: it still means a submitted `id_token` must be accompanied by a
  /// pre-image that only this app instance knows and that never appears in
  /// the token, which is the property the backend check is for. What it does
  /// not do is scope that proof to one individual attempt. Revisit if
  /// `google_sign_in` ever moves the parameter to `authenticate`.
  static Future<SignInNonce>? _googleSignInInit;

  Future<SignInNonce> _ensureGoogleSignInInitialized() {
    return _googleSignInInit ??= () async {
      final nonce = SignInNonce.generate();
      await GoogleSignIn.instance.initialize(
        serverClientId: AppConfig.googleServerClientId,
        nonce: nonce.hashed,
      );
      return nonce;
    }();
  }

  /// [nonce] is the RAW pre-image, never the value handed to the provider —
  /// see [SignInNonce]. The backend rejects the call outright if it is empty.
  Future<AuthSession> _completeFederatedSignup({
    required String provider,
    required String idToken,
    required String nonce,
    required bool ageConfirmedOver18,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/federated/signup'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'provider': provider,
        'id_token': idToken,
        'nonce': nonce,
        'age_confirmed_over_18': ageConfirmedOver18,
      }),
    );
    return _parseSessionResponse(response);
  }

  @override
  Future<int> startEmailSignupOtp(String email) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/email/signup/start'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['resend_after_seconds'] as int? ?? 0;
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/email/signup'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'code': code,
        'age_confirmed_over_18': ageConfirmedOver18,
      }),
    );
    return _parseSessionResponse(
      response,
      on400: InvalidVerificationCodeException.new,
    );
  }

  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/guest/signup'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'age_confirmed_over_18': ageConfirmedOver18}),
    );
    // No on400 override: the only 400 this endpoint produces is the age
    // attestation being false, which the UI cannot reach (the age step is
    // completed before the button is shown) and which is not a bad-code
    // case, so the generic mapping is the honest one.
    return _parseSessionResponse(response);
  }

  @override
  Future<int> startEmailLoginOtp(String email) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/email/login/start'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['resend_after_seconds'] as int? ?? 0;
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/email/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'code': code}),
    );
    // 401 here means invalid email/code (CompleteEmailLogin's own
    // deliberately-identical message for "email unknown" vs "wrong code,"
    // an account-enumeration-safe design, ADR-019 §1) — distinct from a
    // refresh token's 401 (a live session having gone bad), so this must
    // NOT map to SessionExpiredException: there is no session yet to force
    // out of, this is a fresh sign-in attempt that simply failed.
    return _parseSessionResponse(
      response,
      on401: InvalidCredentialsException.new,
    );
  }

  @override
  Future<AuthSession> refreshSession(String refreshToken) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/refresh'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    return _parseSessionResponse(response, isRefresh: true);
  }

  @override
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) async {
    // The bearer is optional on this route: the server revokes the refresh
    // token either way and only uses the access token to prove whose push
    // registration fcm_token is. Sent only when there is something for it
    // to prove.
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/logout'),
      headers: {
        'Content-Type': 'application/json',
        if (accessToken != null && fcmToken != null)
          'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'refresh_token': refreshToken, 'fcm_token': ?fcmToken}),
    );
    if (response.statusCode != 200) {
      throw AuthNetworkException(_errorMessage(response.body));
    }
  }

  @override
  Future<int> startPhoneVerification(String phoneNumber) => _startVerification(
    '/v1/verification/phone/start',
    {'phone_number': phoneNumber},
  );

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) =>
      _verifyCode('/v1/verification/phone/verify', {
        'phone_number': phoneNumber,
        'code': code,
      });

  @override
  Future<int> startPersonalEmailVerification(String email) =>
      _startVerification('/v1/verification/personal-email/start', {
        'email': email,
      });

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) =>
      _verifyCode('/v1/verification/personal-email/verify', {
        'email': email,
        'code': code,
      });

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async {
    final response = await _authenticatedPost(
      '/v1/verification/personal-details',
      {'legal_name': legalName, 'address': address},
    );
    return _parseVerificationSession(response);
  }

  @override
  Future<int> startCorporateEmailVerification(String email) =>
      _startVerification('/v1/verification/corporate-email/start', {
        'email': email,
      }, on400: (message) => WorkEmailDomainRejectedException(message));

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) => _verifyCode('/v1/verification/corporate-email/verify', {
    'email': email,
    'code': code,
    'company_name': companyName,
  });

  @override
  Future<UserProfile> getProfile() async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/users/me'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return UserProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<PublicProfile> getPublicProfile(String userId) async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/users/${Uri.encodeComponent(userId)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return PublicProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    // 403 is the relationship gate: the server's sentence says why, and the
    // page shows it as a state rather than an error. Handled here rather
    // than in the shared mapper so the verification endpoints' own 403
    // behaviour is untouched.
    if (response.statusCode == 403) {
      throw ForbiddenActionException(_errorMessage(response.body));
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async {
    final response = await _authenticatedPost('/v1/auth/profile-setup', {
      'full_name': fullName,
      'company_name': ?companyName,
      'company_email': ?companyEmail,
    });
    if (response.statusCode == 200) {
      return UserProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async {
    final response = await _authenticatedPost('/v1/sos/contacts', {
      'name': name,
      'phone_number': phoneNumber,
      'email': email,
    });
    if (response.statusCode == 200) {
      return TrustedContact.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<List<TrustedContact>> listTrustedContacts() async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/sos/contacts'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final contacts = decoded['contacts'] as List<dynamic>? ?? [];
      return contacts
          .map((c) => TrustedContact.fromJson(c as Map<String, dynamic>))
          .toList();
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<void> removeTrustedContact(String contactId) async {
    final headers = await _authHeaders();
    final response = await _httpClient.delete(
      Uri.parse('$_baseUrl/v1/sos/contacts/$contactId'),
      headers: headers,
    );
    if (response.statusCode == 204) return;
    if (response.statusCode == 403) {
      throw ForbiddenActionException(_errorMessage(response.body));
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) async {
    final response = await _authenticatedPost('/v1/sos/trigger', {
      'context_message': contextMessage,
      'latitude': latitude,
      'longitude': longitude,
    });
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['contacts_notified'] as int? ?? 0;
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async {
    final response = await _authenticatedPost('/v1/users/me/location', {
      'latitude': latitude,
      'longitude': longitude,
    });
    if (response.statusCode == 204) return;
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

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
    throw _mapVerificationError(response, on400: on400);
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
        return const ResendCooldownException();
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
  // Type and code only, never the object: debugPrint survives release
  // builds, and a platform exception's toString() can carry more than a
  // log should (same rule as every other catch in this codebase).
  debugPrint(
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
  debugPrint('Google Sign-In failed: ${error.code} ${error.description}');
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
