import 'package:professional_connections_platform/core/config/app_config.dart';

/// How the app loads a user's photo, which needs the signed-in user's token
/// (plan 2.1). A static holder because avatars are drawn deep inside plain
/// widgets, on every screen, and [SessionStorage] is the one place every
/// session passes through.
abstract final class PhotoAuth {
  static String? _accessToken;

  static set accessToken(String? token) => _accessToken = token;

  /// The token goes to this gateway only: [url] answers for nothing but our
  /// own `/v1/` paths, so it can never reach another host.
  static Map<String, String> get headers => {
    if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
  };

  /// The absolute address of a photo path from a payload, or null for an
  /// empty value or anything that is not our own path.
  static String? url(String? path) {
    if (path == null || !path.startsWith('/v1/')) return null;
    return '${AppConfig.gatewayBaseUrl}$path';
  }
}
