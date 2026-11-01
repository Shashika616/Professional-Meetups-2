import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';

import 'support/fake_credit_service.dart';

/// A session a test can switch between accounts.
class _Switchable extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState();

  void signIn(String id) => state = AsyncData(
    AuthSessionState(
      profile: UserProfile(id: id, fullName: id, trustLevel: 3),
    ),
  );
}

class _CountingConfig implements AppConfigService {
  int calls = 0;
  @override
  Future<RemoteAppConfig> fetch() async {
    calls++;
    return RemoteAppConfig.defaults;
  }
}

// Found on the emulator (29C): the wallet and app config were read once and
// kept across sign-out and sign-in, so a fresh sign-in showed the previous
// session's failed balance, and a second account would have seen the first
// account's credits.
void main() {
  test(
    'account-scoped reads are fetched again when the signed-in user changes',
    () async {
      final credits = FakeCreditService();
      final config = _CountingConfig();
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(_Switchable.new),
          creditServiceProvider.overrideWithValue(credits),
          appConfigServiceProvider.overrideWithValue(config),
        ],
      );
      addTearDown(container.dispose);
      container.listen(walletProvider, (_, _) {});
      container.listen(appConfigProvider, (_, _) {});
      await container.read(authSessionProvider.future);

      final notifier =
          container.read(authSessionProvider.notifier) as _Switchable;
      notifier.signIn('alice');
      credits.walletResult = const Wallet(
        balance: 10,
        held: 0,
        available: 10,
        debt: 0,
      );
      expect((await container.read(walletProvider.future)).available, 10);
      final callsForAlice = (credits.walletCalls, config.calls);

      notifier.signIn('bob');
      credits.walletResult = const Wallet(
        balance: 99,
        held: 0,
        available: 99,
        debt: 0,
      );
      expect(
        (await container.read(walletProvider.future)).available,
        99,
        reason: 'bob must not see alice\'s balance',
      );
      expect(credits.walletCalls, greaterThan(callsForAlice.$1));
      await container.read(appConfigProvider.future);
      expect(
        config.calls,
        greaterThan(callsForAlice.$2),
        reason: 'flags are per account (allowlists)',
      );
    },
  );
}
