import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

enum LegalDocument {
  terms('Terms and Conditions', 'https://tiehere.com/terms'),
  privacy('Privacy Policy', 'https://tiehere.com/privacy');

  const LegalDocument(this.title, this.webUrl);

  final String title;

  /// The public page, for when the server has no text to show.
  final String webUrl;
}

/// Opens [document] on a page of its own.
void openLegalDocument(BuildContext context, LegalDocument document) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: ScreenNames.legalDocument),
      builder: (_) => LegalDocumentPage(document: document),
    ),
  );
}

/// Reads the terms or the privacy policy inside the app, from the server's
/// current text.
class LegalDocumentPage extends ConsumerWidget {
  const LegalDocumentPage({super.key, required this.document, this.open});

  final LegalDocument document;

  /// Opens the website; replaced in tests.
  final Future<void> Function(Uri uri)? open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = ref.watch(legalDocumentsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: Text(document.title)),
      body: AppBackground(
        child: SafeArea(
          child: documents.when(
            loading: () => const Center(child: BrandLoader(size: 44)),
            error: (_, _) => _Failed(
              onRetry: () => ref.invalidate(legalDocumentsProvider),
              onOpenWebsite: () {
                final launch =
                    open ??
                    (Uri u) =>
                        launchUrl(u, mode: LaunchMode.externalApplication);
                launch(Uri.parse(document.webUrl));
              },
            ),
            data: (docs) => _Text(
              markdown: document == LegalDocument.terms
                  ? docs.terms
                  : docs.privacy,
            ),
          ),
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry, required this.onOpenWebsite});

  final VoidCallback onRetry;
  final VoidCallback onOpenWebsite;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'We couldn’t load this here. You can read it on our website.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Read on tiehere.com',
              onPressed: onOpenWebsite,
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Try again',
              icon: AppIcons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// The small part of Markdown these documents use: headings, bullets, tables
/// as plain rows, and bold. Nothing here is a link.
class _Text extends StatelessWidget {
  const _Text({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final blocks = [
      for (final line in markdown.split('\n'))
        if (line.trim().isNotEmpty && !_isRule(line)) line.trim(),
    ];
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        itemCount: blocks.length,
        itemBuilder: (context, index) => _block(blocks[index]),
      ),
    );
  }

  static bool _isRule(String line) =>
      RegExp(r'^\s*(---+|\|[\s:|-]+\|)\s*$').hasMatch(line);

  Widget _block(String line) {
    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(
          line.substring(2),
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
      );
    }
    if (line.startsWith('#')) {
      return Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          line.replaceFirst(RegExp(r'^#+\s*'), ''),
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final bullet = line.startsWith('- ') || line.startsWith('* ');
    final row = line.startsWith('|');
    final text = row
        ? line
              .split('|')
              .map((c) => c.trim())
              .where((c) => c.isNotEmpty)
              .join(': ')
        : (bullet ? line.substring(2) : line);
    final body = Text.rich(
      TextSpan(children: _spans(text)),
      style: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 15,
        height: 1.5,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: bullet || row
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '•  ',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }

  List<TextSpan> _spans(String text) {
    final parts = text.split('**');
    return [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: parts[i],
          style: i.isOdd
              ? TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                )
              : null,
        ),
    ];
  }
}
