part of '../http_auth_service.dart';

/// Every way into an account: LinkedIn, Apple, Google, email and guest,
/// plus refreshing, signing out and claiming an existing account.
mixin _SignInMethods on _HttpAuthBase {
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
  /// (`internal/identity`) has no way to see it. So this reads the name off
  /// the credential here and sends it as the request's `full_name_hint`
  /// (Plan 22), which the server uses ONLY to name a brand-new account when
  /// the token itself carried no name. It was previously read and discarded,
  /// which is why every Apple signup came back nameless.
  ///
  /// Apple supplies that name on a user's VERY FIRST authorization with this
  /// app and never again — so a reinstall, or any later sign-in, still sends
  /// an empty hint. That is expected, not a failure: `full_name` then comes
  /// back empty exactly as before and the app renders its existing "Member"
  /// fallback (`ProfilePage`/`HomePage`). The hint never overwrites a name an
  /// account already has; the server only ever applies it at creation.
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
      fullNameHint: HttpAuthService.appleFullNameHint(credential),
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
        // Google's id_token carries a standard OIDC `name` claim, which the
        // server verifies and prefers over any hint — there is nothing for
        // this path to add, and Plan 22 changes its behavior in no way.
        fullNameHint: '',
      );
    } on GoogleSignInException catch (error) {
      // Dispatch on error.code happens inside mapGoogleSignInError.
      throw mapGoogleSignInError(error);
    }
  }

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
  /// [fullNameHint] is the provider's out-of-band name, or `''` when there
  /// is none — always sent rather than conditionally omitted, so the body
  /// shape is the same on every call and the server has one case to handle.
  Future<AuthSession> _completeFederatedSignup({
    required String provider,
    required String idToken,
    required String nonce,
    required bool ageConfirmedOver18,
    required String fullNameHint,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/federated/signup'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'provider': provider,
        'id_token': idToken,
        'nonce': nonce,
        'age_confirmed_over_18': ageConfirmedOver18,
        'full_name_hint': fullNameHint,
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
    throw _mapVerificationError(
      response,
      on400: AuthNetworkException.new,
      isResend: true,
    );
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
    throw _mapVerificationError(
      response,
      on400: AuthNetworkException.new,
      isResend: true,
    );
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
  Future<AuthSession> completeAccountClaim({
    required String ticket,
    required String code,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/account-claim'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'ticket': ticket, 'code': code}),
    );
    // on400 is the wrong-or-expired-code case, the same as every other OTP
    // route. A 409 cannot come back from here: this endpoint never creates
    // an account, so there is nothing left to collide with.
    return _parseSessionResponse(
      response,
      on400: InvalidVerificationCodeException.new,
    );
  }

  @override
  Future<int> resendAccountClaimCode(String ticket) async {
    // Unauthenticated, like the claim itself: there is no session yet. The
    // ticket is what authorises the send.
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/v1/auth/account-claim/resend'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'ticket': ticket}),
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['resend_after_seconds'] as int? ?? 0;
    }
    throw _mapVerificationError(
      response,
      on400: AuthNetworkException.new,
      isResend: true,
    );
  }
}
