/// Environment-aware app configuration, switched via `--dart-define` at
/// build/run time — never a hardcoded value in a service implementation.
/// For anything beyond a one-off override, copy `.env.example` to `.env`
/// (gitignored) and run with `--dart-define-from-file=.env` instead of
/// typing out `--dart-define=KEY=value` per key; a same-key `--dart-define`
/// still takes precedence over `.env` if both are passed.
///
/// `GATEWAY_BASE_URL` must be set per run target (`backend/README.md`'s
/// documented gotcha): `http://localhost:8080` for the iOS simulator,
/// `http://10.0.2.2:8080` for the Android emulator (the emulator's alias
/// for the host machine's localhost). Defaults to the iOS-simulator value
/// so a plain `flutter run` still works for the common case; pass
/// `--dart-define=GATEWAY_BASE_URL=http://10.0.2.2:8080` when targeting an
/// Android emulator.
abstract final class AppConfig {
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// LinkedIn's public OAuth client ID (not a secret — only
  /// `LINKEDIN_CLIENT_SECRET`, held solely by `services/auth`, is). Matches
  /// `backend/.env`'s `LINKEDIN_CLIENT_ID`; overridable via
  /// `--dart-define=LINKEDIN_CLIENT_ID=...` if that ever changes without a
  /// rebuild of this default.
  static const String linkedInClientId = String.fromEnvironment(
    'LINKEDIN_CLIENT_ID',
    defaultValue: '8656gg5a3148tc',
  );

  /// LinkedIn requires an absolute `https://` redirect URL — it will not
  /// accept a custom URL scheme directly (`frontend/PLAN.md` Step 0.2).
  /// This is `auth-bridge/`'s deployed URL: a zero-server-logic page that
  /// forwards LinkedIn's query string to [appRedirectScheme]. Sent as
  /// `redirect_uri` in both the LinkedIn authorization request and the
  /// `/v1/auth/linkedin/callback` POST — OAuth requires the identical value
  /// at both steps. Matches `backend/.env`'s `LINKEDIN_REDIRECT_URI`.
  /// Doesn't change between local/production backend environments since
  /// this bridge page never talks to the backend at all — not
  /// env-switched, changing it means redeploying `auth-bridge/` and
  /// re-registering with LinkedIn together, not just a build flag.
  static const String linkedInRedirectUri =
      'https://professional-meetups-976d2.web.app';

  /// The custom URL scheme `auth-bridge/` forwards to, and that `app_links`
  /// listens for. LinkedIn itself never sees this value — only the bridge
  /// page and the app do. Registered on both platforms in Step 2.
  static const String appRedirectScheme = 'professionalconnections';

  /// Stadia Maps API key for the Schedule flow's map/location-picker step
  /// (frontend/meetup-scheduling-PLAN.md's 2026-08-18 testing addendum —
  /// see TESTING-NOTES.md). **Provisional testing provider, not the
  /// production decision** (ADR-013 §4's second correction) — the eventual
  /// choice is still open between Google Maps and Mapbox. Unlike Twilio/
  /// Resend's empty-means-fallback pattern, this is a real, working key:
  /// if it's empty the map widget shows a "not configured" state rather
  /// than silently failing. Pass the real value via
  /// `--dart-define=STADIA_MAPS_API_KEY=...` at run time — never written
  /// into source.
  static const String stadiaMapsApiKey = String.fromEnvironment(
    'STADIA_MAPS_API_KEY',
    defaultValue: '',
  );

  /// `google_sign_in`'s `serverClientId` — must be the separate **Web**
  /// OAuth client ID, not the Android client's own ID (a common real
  /// gotcha, `frontend/level0-federated-identity-PLAN.md` Step 1). This is
  /// what makes the returned id_token's `aud` claim match what the
  /// backend's `internal/identity.GoogleProvider` verifies against
  /// (`GOOGLE_CLIENT_ID`). Empty by default (real credentials not yet
  /// issued, Action Tracker §1) — [HttpAuthService.signInWithGoogle] fails
  /// with a clear error rather than silently misconfiguring itself when
  /// this is unset.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );
}
