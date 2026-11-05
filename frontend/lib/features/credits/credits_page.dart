import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/empty_section.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/credits/buy_credits_page.dart';
import 'package:professional_connections_platform/features/credits/credits_format.dart';

/// The Credits page (plan 29C), opened from Profile: the balance, welcome
/// credits about to decay, a way to buy more, and the history.
///
/// Every figure is the server's. Consumables cannot be restored (the store
/// keeps no record of them to restore), so unlike Premium there is no
/// restore button here.
class CreditsPage extends ConsumerStatefulWidget {
  const CreditsPage({super.key});

  @override
  ConsumerState<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends ConsumerState<CreditsPage> {
  final List<LedgerEntry> _entries = [];
  String? _cursor;
  bool _loadedFirst = false;
  bool _loadingMore = false;
  Object? _historyError;

  /// How many pages one "load" may read to find a line worth showing: a
  /// page can hold only holds and releases, which the history skips.
  static const _maxPagesPerLoad = 3;

  @override
  void initState() {
    super.initState();
    _loadHistory(first: true);
  }

  Future<void> _loadHistory({bool first = false}) async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _historyError = null;
      if (first) {
        _entries.clear();
        _cursor = null;
        _loadedFirst = false;
      }
    });
    try {
      final service = ref.read(creditServiceProvider);
      var cursor = first ? null : _cursor;
      var shown = 0;
      for (var i = 0; i < _maxPagesPerLoad; i++) {
        final page = await service.ledger(cursor: cursor);
        final visible = page.entries.where((e) => e.visible).toList();
        _entries.addAll(visible);
        shown += visible.length;
        cursor = page.nextCursor;
        if (shown > 0 || cursor == null) break;
      }
      if (!mounted) return;
      setState(() {
        _cursor = cursor;
        _loadedFirst = true;
      });
    } on CreditSessionExpiredException {
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
    } catch (e) {
      if (mounted) setState(() => _historyError = e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(walletProvider);
    await _loadHistory(first: true);
  }

  Future<void> _openBuy() async {
    track(Cta.buyCredits);
    final bought = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: ScreenNames.buyCredits),
        builder: (context) => const BuyCreditsPage(),
      ),
    );
    if (bought == true && mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Credits')),
      body: AppBackground(
        child: SafeArea(
          child: BrandRefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                // An error shows as an error even while Riverpod retries it
                // (a retry is "loading with an error"), not as a skeleton
                // that never resolves.
                if (walletAsync.hasValue)
                  _BalanceCard(wallet: walletAsync.requireValue)
                else if (walletAsync.hasError)
                  LoadFailedState(
                    compact: true,
                    failure: LoadFailure.of(walletAsync.error),
                    onRetry: () => ref.invalidate(walletProvider),
                  )
                else
                  const SkeletonLoader(
                    key: Key('creditsBalanceLoading'),
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 132,
                      radius: 20,
                    ),
                  ),
                const SizedBox(height: 14),
                PrimaryButton(
                  key: const Key('creditsBuy'),
                  label: 'Buy credits',
                  onPressed: _openBuy,
                ),
                const SizedBox(height: 26),
                const SectionHeading('History'),
                const SizedBox(height: 12),
                ..._history(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _history() {
    if (!_loadedFirst && _historyError == null) {
      return [
        for (var i = 0; i < 3; i++) ...[
          const SkeletonLoader(
            child: SkeletonBox(width: double.infinity, height: 52, radius: 14),
          ),
          const SizedBox(height: 8),
        ],
      ];
    }
    if (_historyError != null && _entries.isEmpty) {
      return [
        LoadFailedState(
          key: const Key('creditsHistoryError'),
          compact: true,
          failure: LoadFailure.of(_historyError),
          onRetry: () => _loadHistory(first: true),
        ),
      ];
    }
    if (_entries.isEmpty) {
      return const [
        EmptySection(
          key: Key('creditsHistoryEmpty'),
          icon: AppIcons.history,
          title: 'No credit history yet',
          message: 'Credits you get and spend show up here.',
          compact: true,
        ),
      ];
    }
    return [
      FlatCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          children: [
            for (var i = 0; i < _entries.length; i++) ...[
              if (i > 0) Container(height: 1, color: AppPalette.hairline),
              _HistoryRow(entry: _entries[i]),
            ],
          ],
        ),
      ),
      if (_historyError != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            LoadFailure.of(_historyError).message,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppPalette.danger, fontSize: 12),
          ),
        ),
      if (_cursor != null) ...[
        const SizedBox(height: 12),
        SecondaryButton(
          key: const Key('creditsLoadMore'),
          label: _loadingMore ? 'Loading…' : 'Show more',
          onPressed: _loadingMore ? null : () => _loadHistory(),
        ),
      ],
    ];
  }
}

/// The balance, with what is held and what is owed when there is any, and
/// the welcome credits about to decay.
class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet});

  final Wallet wallet;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatCreditNumber(wallet.available),
                key: const Key('creditsAvailable'),
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  wallet.available == 1 ? 'credit' : 'credits',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          if (wallet.held > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${formatCredits(wallet.held)} held for a meetup being created',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
            ),
          ],
          if (wallet.debt > 0) ...[
            const SizedBox(height: 10),
            Text(
              'You owe ${formatCredits(wallet.debt)} from a refunded purchase. '
              'Your next credits pay this first, and you can host again once it is paid.',
              key: const Key('creditsDebt'),
              style: TextStyle(
                color: AppPalette.danger,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
          for (final e in wallet.expiringSoon) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: AppPalette.hairline),
            const SizedBox(height: 12),
            _ExpiringRow(expiring: e),
          ],
        ],
      ),
    );
  }
}

class _ExpiringRow extends StatelessWidget {
  const _ExpiringRow({required this.expiring});

  final ExpiringCredits expiring;

  @override
  Widget build(BuildContext context) {
    final what = expiring.kind == 'welcome' ? 'welcome credits' : 'credits';
    final when = expiring.nextDecayAt != null && expiring.nextDecayCredits > 0
        ? '${formatCredits(expiring.nextDecayCredits)} expire on ${formatDay(expiring.nextDecayAt!)}'
        : expiring.expiresAt != null
        ? 'They expire on ${formatDay(expiring.expiresAt!)}'
        : null;
    return Row(
      key: const Key('creditsExpiring'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: AppIcon(AppIcons.hourglass, size: 17, color: AppPalette.gold),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${expiring.remaining} $what',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (when != null) ...[
                const SizedBox(height: 2),
                Text(
                  when,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final gain = entry.delta > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatDay(entry.createdAt),
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${gain ? '+' : '−'}${formatCreditNumber(entry.delta.abs())}',
            style: TextStyle(
              color: gain ? AppPalette.brandGreen : AppPalette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
