import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/deadline_http_client.dart';

/// GET /v1/app-config (plan 29 §2): the flags evaluated for this caller,
/// the oldest supported build, and the billing catalog version.
class RemoteAppConfig {
  const RemoteAppConfig({
    this.flags = const {},
    this.values = const {},
    this.forceUpdate = ForceUpdate.none,
    this.minSupportedAppVersion = '',
    this.billingCatalogVersion = 0,
  });

  /// What an unreachable server reads as: every flag off.
  static const defaults = RemoteAppConfig();

  final Map<String, bool> flags;

  /// Flags' non-boolean payloads (`analytics.sample_rate`: 100).
  final Map<String, num> values;
  final String minSupportedAppVersion;
  final int billingCatalogVersion;

  /// The operator's forced update, from the `app.force_update` flag.
  final ForceUpdate forceUpdate;

  /// Whether signed-in users must agree to the current terms.
  bool get legalAcceptanceRequired => flag('legal.acceptance.required');

  /// An unknown flag is off.
  bool flag(String key) => flags[key] ?? false;

  /// Subscription plans are the one part of billing behind a flag.
  bool get plansVisible => flag('billing.plans.visible');

  /// The server's analytics kill switch (plan 29 D8: on by default). Absent
  /// (an older server, or no answer) reads as on: an unreachable server
  /// must not decide the user's analytics.
  bool get analyticsEnabled => flags['analytics.enabled'] ?? true;

  /// The share of installs that send analytics, 0 to 100 (default 100).
  int get analyticsSampleRate =>
      (values['analytics.sample_rate'] ?? 100).round().clamp(0, 100);

  factory RemoteAppConfig.fromJson(Map<String, dynamic> json) =>
      RemoteAppConfig(
        forceUpdate: ForceUpdate.fromConfig(json),
        flags: {
          for (final e
              in (json['flags'] as Map<String, dynamic>? ?? const {}).entries)
            if (e.value is bool) e.key: e.value as bool,
        },
        values: {
          for (final e
              in (json['values'] as Map<String, dynamic>? ?? const {}).entries)
            if (e.value is num) e.key: e.value as num,
        },
        minSupportedAppVersion:
            json['min_supported_app_version'] as String? ?? '',
        billingCatalogVersion:
            (json['billing_catalog_version'] as num?)?.toInt() ?? 0,
      );
}

/// A forced update, set by the operator without a release (runbook). Off means
/// nobody is blocked. Each platform has its own minimum, because the stores
/// approve builds at different speeds.
class ForceUpdate {
  const ForceUpdate({
    this.enabled = false,
    this.minVersions = const {},
    this.message = '',
    this.storeUrls = const {},
  });

  static const none = ForceUpdate();

  factory ForceUpdate.fromConfig(Map<String, dynamic> json) {
    final flags = json['flags'] as Map<String, dynamic>? ?? const {};
    final values = json['values'] as Map<String, dynamic>? ?? const {};
    final value = values['app.force_update'];
    if (flags['app.force_update'] != true || value is! Map<String, dynamic>) {
      return none;
    }
    Map<String, String> strings(Object? map) => {
      if (map is Map<String, dynamic>)
        for (final e in map.entries)
          if (e.value is String) e.key: e.value as String,
    };
    return ForceUpdate(
      enabled: true,
      minVersions: strings(value['min_version']),
      message: value['message'] as String? ?? '',
      storeUrls: strings(value['store_url']),
    );
  }

  final bool enabled;

  /// By platform: `ios`, `android`.
  final Map<String, String> minVersions;
  final String message;
  final Map<String, String> storeUrls;
}

abstract interface class AppConfigService {
  /// Never throws: anything but a 200 is [RemoteAppConfig.defaults]. A
  /// config fetch must not stop the app, and a provider that threw would
  /// retry it in a loop.
  Future<RemoteAppConfig> fetch();
}

class HttpAppConfigService implements AppConfigService {
  HttpAppConfigService({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
  }) : _httpClient = DeadlineHttpClient(
         ClientInfoHttpClient(httpClient ?? http.Client()),
       ),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null);

  final http.Client _httpClient;
  final String _baseUrl;
  final Future<String?> Function() _getAccessToken;

  @override
  Future<RemoteAppConfig> fetch() async {
    try {
      // Signed in or not; a signed-in caller gets their allowlists.
      String? token;
      try {
        token = await _getAccessToken();
      } catch (_) {
        token = null;
      }
      final r = await _httpClient.get(
        Uri.parse('$_baseUrl/v1/app-config'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
      if (r.statusCode != 200) return RemoteAppConfig.defaults;
      return RemoteAppConfig.fromJson(
        jsonDecode(r.body) as Map<String, dynamic>,
      );
    } on AuthNetworkException {
      return RemoteAppConfig.defaults;
    } on FormatException {
      return RemoteAppConfig.defaults;
    }
  }
}
