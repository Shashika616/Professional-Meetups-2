import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';

/// Contract for authentication and Level 2/3 verification (ADR-011,
/// ADR-012, `frontend/PLAN.md`'s matching addendum).
///
/// The client never decides trust. It only displays what the server
/// returns. Every verification-completing method returns a fresh
/// [AuthSession] (new access token reflecting the updated trust level) —
/// callers must save it and update session state immediately, the same way
/// a token refresh already does, rather than waiting for the next natural
/// refresh.
abstract interface class AuthService {
  /// Direct LinkedIn signup — unchanged in name/behavior from ADR-011,
  /// still a resolve-or-create call that grants Level 1 immediately
  /// (ADR-014 §1: LinkedIn is the only path to Level 1, whether chosen at
  /// signup or connected later via [linkLinkedIn]). Now also carries
  /// `age_confirmed_over_18` — LinkedIn direct signup didn't have an age
  /// gate before ADR-014 and needed one, same as the other three paths.
  Future<AuthSession> signInWithLinkedIn({required bool ageConfirmedOver18});

  /// Sign in with Apple (iOS) — creates a permanently-zero-trust Level 0
  /// account, or logs in if this Apple identity already has one (ADR-014).
  Future<AuthSession> signInWithApple({required bool ageConfirmedOver18});

  /// Google Sign-In (Android) — same Level 0 semantics as
  /// [signInWithApple], different provider.
  Future<AuthSession> signInWithGoogle({required bool ageConfirmedOver18});

  /// Completes email-OTP signup after [startEmailSignupOtp]'s code has been
  /// entered — creates a new Level 0 account, or (per
  /// `SignUpOrRecoverWithEmail`'s server-side recovery semantics) logs in
  /// to an existing account whose `personal_email` this address already
  /// verified elsewhere. No password anywhere (ADR-019 §1) — proving inbox
  /// control via OTP is the entire credential.
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  });

  /// Creates a read-only guest account and returns a real session for it
  /// (ADR-002 § 3) — no email, no phone, no LinkedIn, a server-generated
  /// display handle. Lands at trust Level 0.
  ///
  /// Takes the same 18+ attestation every other signup path does: it is an
  /// eligibility gate, not a trust step, and applies uniformly.
  ///
  /// There is no matching "upgrade" call, deliberately. A guest who later
  /// verifies anything does so through the existing verification methods on
  /// this interface, against the same account — the server clears the guest
  /// flag on its own and the next session is Level 1.
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18});

  /// Sends the OTP [loginWithEmail] verifies, as the first step of
  /// passwordless email login (ADR-019 §1) — every return visit sends a
  /// fresh code, there is no stored credential to check. Same convention
  /// as [startEmailSignupOtp]/[startPhoneVerification]: returns the
  /// server's resend cooldown, in seconds.
  Future<int> startEmailLoginOtp(String email);

  /// Email-OTP sign-in for a returning user (ADR-019 §1) — the one path
  /// that can't collapse "resolve or create" into a single tap the way the
  /// federated methods do, so it needs its own form/screen.
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  });

  /// Links LinkedIn to the CALLER's already-authenticated account
  /// (Profile's "Connect LinkedIn," ADR-014) — distinct from
  /// [signInWithLinkedIn], which creates/resolves an account rather than
  /// linking to one already signed in. Hits a different backend route
  /// (`/v1/auth/identities/link`, authenticated) than [signInWithLinkedIn]
  /// (`/v1/auth/linkedin/callback`, unauthenticated).
  Future<AuthSession> linkLinkedIn();

  /// Sends the OTP [startEmailSignupOtp] to `email`'s inbox, as the first
  /// step of [signUpWithEmail] — reuses the same OTP-start pattern already
  /// built for personal-email verification (`StartVerificationRequest`
  /// shape), just unauthenticated. Returns the server's resend cooldown, in
  /// seconds, same convention as [startPhoneVerification] etc.
  Future<int> startEmailSignupOtp(String email);

  Future<AuthSession> refreshSession(String refreshToken);
  Future<void> logout(String refreshToken);

  /// Returns the server's resend cooldown, in seconds — the client's own
  /// countdown timer is seeded from this, never hardcoded, since it's the
  /// server that actually enforces it.
  Future<int> startPhoneVerification(String phoneNumber);
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code);
  Future<int> startPersonalEmailVerification(String email);
  Future<AuthSession> verifyPersonalEmailCode(String email, String code);
  Future<AuthSession> submitPersonalDetails(String legalName, String address);
  Future<int> startCorporateEmailVerification(String email);

  /// [companyName] is ADR-019 §3's name-vs-domain cross-check against
  /// `known_companies` — required (the backend rejects an empty value),
  /// even when this is called from `ProfilePage`'s independent Level 3
  /// upgrade flow, not just from [completeProfileSetup]'s screen.
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  );

  /// Never returns a raw phone number or email address — only
  /// booleans/derived fields (backend's deliberate choice, Verification
  /// Model § 1).
  Future<UserProfile> getProfile();

  /// Another member's public profile — name, photo, level, record and the
  /// verification badges. Never their contact details; see
  /// [PublicProfile]. Throws [NotFoundException]-class errors via the
  /// usual mapping when the id is unknown.
  Future<PublicProfile> getPublicProfile(String userId);

  /// Backs ADR-019 §2's new mandatory post-auth screen, called once by
  /// every one of the four sign-up/login paths right after auth succeeds.
  /// [fullName] is always required; [companyName]/[companyEmail] are
  /// optional as a pair. Returns the updated [UserProfile] directly (not a
  /// fresh [AuthSession] — `full_name` isn't part of the JWT claims,
  /// unlike trust level, so there's no new access token to issue here).
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  });

  /// Trusted contacts + SOS (ADR-026). Trusted contacts live in auth's own
  /// database (ADR-017 DB split), not meetup's — hence these sit on
  /// [AuthService] rather than `MeetupService`, matching backend
  /// ownership. [triggerSos] takes client-supplied meetup/location context
  /// rather than the app making a second call to fetch it server-side.
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber,
    String email,
  });
  Future<List<TrustedContact>> listTrustedContacts();
  Future<void> removeTrustedContact(String contactId);

  /// Returns how many trusted contacts were actually alerted — displayed
  /// verbatim, never inferred client-side (the "client never decides, only
  /// displays" principle applies here too).
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  });

  /// The browse screen's on-demand location read (Slice D, ADR-021) — its
  /// one and only call site. No periodic timer.
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  });
}

/// Typed errors an [AuthService] can throw, so the UI can show a real
/// message instead of a generic "something went wrong" — in particular a
/// 429 must read as "you're being rate limited," not a generic failure.
sealed class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 400 from the gateway: invalid/expired authorization code, or a PKCE
/// verifier/challenge mismatch.
class InvalidGrantException extends AuthException {
  const InvalidGrantException(super.message);
}

/// 429 from the gateway — distinct from other failures so the UI can tell
/// the user to wait, specifically.
class RateLimitedException extends AuthException {
  const RateLimitedException([
    super.message =
        'You’re being rate limited. Please wait a moment and try again.',
  ]);
}

/// 401 on `/v1/auth/refresh` — the refresh token is invalid, expired, or
/// was already rotated (a possible theft signal server-side, ADR-009). The
/// client's only correct response is to treat the local session as gone.
class SessionExpiredException extends AuthException {
  const SessionExpiredException(super.message);
}

/// 401 from `POST /v1/auth/email/login` — the email doesn't exist, or the
/// code is wrong/expired. The backend deliberately returns the exact same
/// message for both cases (`CompleteEmailLogin`'s own account-enumeration-
/// safe design, ADR-019 §1) — distinct from [SessionExpiredException]
/// because there is no prior session to have expired here, just a fresh
/// sign-in attempt that failed.
class InvalidCredentialsException extends AuthException {
  const InvalidCredentialsException(super.message);
}

/// The user backed out of the LinkedIn browser flow, or it never completed
/// within the timeout — not a server error, nothing to retry against.
class SignInCancelledException extends AuthException {
  const SignInCancelledException([
    super.message = 'Sign-in was not completed.',
  ]);
}

/// A `StartXVerification` resend attempted before the server's cooldown
/// has elapsed (429, backend/PLAN.md's addendum Step G) — distinct from
/// [RateLimitedException] because the UI response differs: this isn't a
/// generic "you're being rate limited" failure to show the user, it means
/// the client's own countdown timer is out of sync with the server's and
/// should just keep counting down rather than surfacing an error.
class ResendCooldownException extends AuthException {
  const ResendCooldownException([
    super.message = 'Please wait before requesting another code.',
  ]);
}

/// `StartCorporateEmailVerification` rejected a free-mail or role-based
/// address (400) — safe to show verbatim (Verification Model § 5 — this
/// only reveals something about the domain the user themselves just typed,
/// not about any account's existence), matches the backend's exact message.
class WorkEmailDomainRejectedException extends AuthException {
  const WorkEmailDomainRejectedException(super.message);
}

/// A `VerifyXCode` call failed (400) — wrong code, expired code, or the
/// attempt cap was hit. Distinct from [InvalidGrantException], which is
/// LinkedIn-specific vocabulary.
class InvalidVerificationCodeException extends AuthException {
  const InvalidVerificationCodeException(super.message);
}

/// 403 from a trusted-contact route — the caller tried to act on a
/// contact that isn't theirs (ADR-026's "no row for this caller →
/// Forbidden" pattern). The manage-contacts screen never shows another
/// user's contact, so this should be unreachable in practice; kept as a
/// real, distinct mapping rather than falling through to
/// [AuthNetworkException]'s generic message.
class ForbiddenActionException extends AuthException {
  const ForbiddenActionException([
    super.message = 'You don’t have permission to do that.',
  ]);
}

/// Anything else: network failure, unexpected status code, malformed
/// response.
class AuthNetworkException extends AuthException {
  const AuthNetworkException([
    super.message = 'Something went wrong. Please try again.',
  ]);
}

/// Simulates server latency for widget tests (Step 8) — kept in the
/// codebase for that purpose even though [HttpAuthService] is what
/// `app_providers.dart` wires up for real use.
class MockAuthService implements AuthService {
  static const Duration latency = Duration(milliseconds: 600);

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 1,
      isNewUser: true,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-guest-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 0,
      isNewUser: true,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Guest-MockOtter1234',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> signInWithApple({
    required bool ageConfirmedOver18,
  }) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 0,
      isNewUser: true,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> signInWithGoogle({
    required bool ageConfirmedOver18,
  }) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 0,
      isNewUser: true,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 0,
      isNewUser: true,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<int> startEmailLoginOtp(String email) async {
    await Future<void>.delayed(latency);
    return 60;
  }

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token',
      refreshToken: 'mock-refresh-token',
      trustLevel: 0,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> linkLinkedIn() async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token-linked',
      refreshToken: 'mock-refresh-token-linked',
      trustLevel: 1,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<int> startEmailSignupOtp(String email) async {
    await Future<void>.delayed(latency);
    return 60;
  }

  @override
  Future<AuthSession> refreshSession(String refreshToken) async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token-2',
      refreshToken: 'mock-refresh-token-2',
      trustLevel: 1,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<void> logout(String refreshToken) async {
    await Future<void>.delayed(latency);
  }

  Future<AuthSession> _mockVerifiedSession() async {
    await Future<void>.delayed(latency);
    return AuthSession(
      userId: 'mock-user-1',
      accessToken: 'mock-access-token-verified',
      refreshToken: 'mock-refresh-token-verified',
      trustLevel: 1,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Mock User',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<int> startPhoneVerification(String phoneNumber) async {
    await Future<void>.delayed(latency);
    return 60;
  }

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) =>
      _mockVerifiedSession();

  @override
  Future<int> startPersonalEmailVerification(String email) async {
    await Future<void>.delayed(latency);
    return 60;
  }

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) =>
      _mockVerifiedSession();

  @override
  Future<AuthSession> submitPersonalDetails(String legalName, String address) =>
      _mockVerifiedSession();

  @override
  Future<int> startCorporateEmailVerification(String email) async {
    await Future<void>.delayed(latency);
    return 60;
  }

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) => _mockVerifiedSession();

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async {
    await Future<void>.delayed(latency);
    return UserProfile(id: 'mock-user-1', fullName: fullName, trustLevel: 1);
  }

  @override
  Future<PublicProfile> getPublicProfile(String userId) async {
    await Future<void>.delayed(latency);
    return PublicProfile(
      id: userId,
      fullName: 'Mock Member',
      trustLevel: 2,
      ratingAverage: 4.5,
      ratingCount: 6,
      meetupsCompleted: 8,
      linkedInConnected: true,
      phoneVerified: true,
    );
  }

  @override
  Future<UserProfile> getProfile() async {
    await Future<void>.delayed(latency);
    // trustLevel pinned explicitly (not left to UserProfile's own default)
    // so this mock's contract stays stable regardless of what that default
    // is — this mock has always represented a LinkedIn-connected user,
    // matching signInWithLinkedIn()'s own trustLevel: 1 above.
    return const UserProfile(
      id: 'mock-user-1',
      fullName: 'Mock User',
      trustLevel: 1,
    );
  }

  final List<TrustedContact> _mockTrustedContacts = [];
  int _mockContactSeq = 0;

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async {
    await Future<void>.delayed(latency);
    if (phoneNumber.isEmpty && email.isEmpty) {
      throw const AuthNetworkException(
        'Add a phone number or email for this contact.',
      );
    }
    if (_mockTrustedContacts.length >= 3) {
      throw const AuthNetworkException(
        'You can only have up to 3 trusted contacts.',
      );
    }
    final contact = TrustedContact(
      id: 'mock-contact-${_mockContactSeq++}',
      name: name,
      phoneNumber: phoneNumber,
      email: email,
    );
    _mockTrustedContacts.add(contact);
    return contact;
  }

  @override
  Future<List<TrustedContact>> listTrustedContacts() async {
    await Future<void>.delayed(latency);
    return List.unmodifiable(_mockTrustedContacts);
  }

  @override
  Future<void> removeTrustedContact(String contactId) async {
    await Future<void>.delayed(latency);
    _mockTrustedContacts.removeWhere((c) => c.id == contactId);
  }

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) async {
    await Future<void>.delayed(latency);
    if (_mockTrustedContacts.isEmpty) {
      throw const AuthNetworkException(
        'Add at least one trusted contact before triggering SOS.',
      );
    }
    return _mockTrustedContacts.length;
  }

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async {
    await Future<void>.delayed(latency);
  }
}
