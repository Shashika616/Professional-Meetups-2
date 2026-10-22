import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:professional_connections_platform/core/models/country.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';

/// A phone input in the shape every messaging app uses: a tappable country
/// button, a hairline, then the local number — one surface, not two
/// stacked fields.
///
/// The country button is the affordance that was missing. A fixed `+94`
/// drawn into the placeholder looked like a picker that did not work; this
/// one opens [showCountryPicker] and says so with a chevron.
class PhoneNumberField extends StatelessWidget {
  const PhoneNumberField({
    super.key,
    required this.controller,
    required this.country,
    required this.onCountryChanged,
    this.errorText,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final Country country;
  final ValueChanged<Country> onCountryChanged;

  /// Shown under the field. Null while the number is valid or untouched —
  /// a form that turns red before the user has finished typing is a form
  /// that trained them to ignore it.
  final String? errorText;

  final VoidCallback? onSubmitted;

  Future<void> _pick(BuildContext context) async {
    final picked = await showCountryPicker(context, selected: country);
    if (picked != null) onCountryChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FlatCard(
          radius: 16,
          padding: EdgeInsets.zero,
          border: errorText == null ? null : AppPalette.danger,
          // IntrinsicHeight so the divider between the country button and
          // the number runs the field's full height without a magic
          // number that breaks at a larger text scale.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  button: true,
                  label: 'Country code, ${country.name} ${country.dialCode}',
                  excludeSemantics: true,
                  child: Pressable(
                    onTap: () => _pick(context),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            country.flag,
                            style: const TextStyle(fontSize: 19),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            country.dialCode,
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 4),
                          AppIcon(
                            AppIcons.chevronDown,
                            size: 14,
                            color: AppPalette.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  indent: 10,
                  endIndent: 10,
                  color: AppPalette.hairline,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 14, 0),
                    child: TextField(
                      controller: controller,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => onSubmitted?.call(),
                      autocorrect: false,
                      // Digits and the separators people actually type;
                      // the service strips them before sending.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]')),
                      ],
                      cursorColor: AppPalette.candyBlue,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.4,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 15,
                        ),
                        hintText: 'Phone number',
                        hintStyle: TextStyle(
                          color: AppPalette.textTertiary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              errorText!,
              style: TextStyle(color: AppPalette.danger, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

/// The country sheet: a search field, then the list, scrolled so the
/// current selection is in view.
Future<Country?> showCountryPicker(
  BuildContext context, {
  required Country selected,
}) {
  return showAppSheet<Country>(
    context,
    builder: (_) => AppSheet(
      title: 'Country code',
      child: _CountryPickerBody(selected: selected),
    ),
  );
}

/// Dev-preview hook: the sheet's body on its own, so `main_phone_preview`
/// can render it without a tap the simulator cannot be scripted to make.
/// Not referenced by the app.
@visibleForTesting
class CountryPickerBodyPreview extends StatelessWidget {
  const CountryPickerBodyPreview({super.key});
  @override
  Widget build(BuildContext context) =>
      const _CountryPickerBody(selected: kDefaultCountry);
}

class _CountryPickerBody extends StatefulWidget {
  const _CountryPickerBody({required this.selected});

  final Country selected;

  @override
  State<_CountryPickerBody> createState() => _CountryPickerBodyState();
}

class _CountryPickerBodyState extends State<_CountryPickerBody> {
  /// Every row is this tall, which is what lets the list use [itemExtent]:
  /// the viewport then computes which rows are visible arithmetically
  /// instead of measuring children, and an offset for a given index is
  /// exact rather than a guess.
  static const double _rowExtent = 52;

  final _search = TextEditingController();
  late final ScrollController _scroll;
  List<Country> _results = kCountries;

  @override
  void initState() {
    super.initState();

    // Open with the current selection in view. The list is ordered by
    // market, not alphabetically, so a user whose country sits at index 60
    // would otherwise have to search to find out what is already selected.
    final index = kCountries.indexWhere((c) => c.iso == widget.selected.iso);
    _scroll = ScrollController(
      initialScrollOffset: index <= 0 ? 0 : index * _rowExtent,
    );

    _search.addListener(() {
      setState(() {
        _results = kCountries.where((c) => c.matches(_search.text)).toList();
      });
      // A filtered list is a different list: leaving it at the old offset
      // showed an empty viewport below the last result.
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Bounded, so the sheet never grows past half the screen on a long
    // list and never collapses to nothing on a one-result search.
    //
    // Measured against the height the keyboard LEAVES, not the screen.
    // AppSheet puts this inside a SingleChildScrollView; if the list were
    // capped at a fraction of the full screen, raising the keyboard would
    // make that outer view scrollable too, and a drag on the list would
    // fight the sheet. Taking the keyboard out of the figure keeps the
    // content inside the sheet, so only the list ever scrolls.
    final mq = MediaQuery.of(context);
    final maxHeight = (mq.size.height - mq.viewInsets.bottom) * 0.45;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              AppIcon(
                AppIcons.search,
                size: 17,
                color: AppPalette.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _search,
                  autocorrect: false,
                  cursorColor: AppPalette.candyBlue,
                  style: TextStyle(color: AppPalette.textPrimary, fontSize: 15),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    hintText: 'Search country or code',
                    hintStyle: TextStyle(
                      color: AppPalette.textTertiary,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: _results.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    'No country matches that.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  // Without this the list attaches itself to the modal
                  // sheet's PrimaryScrollController, and the two fight:
                  // the sheet opened showing row 10 of the list rather
                  // than the top of it.
                  primary: false,
                  shrinkWrap: true,
                  itemExtent: _rowExtent,
                  padding: EdgeInsets.zero,
                  itemCount: _results.length,
                  itemBuilder: (_, i) {
                    final c = _results[i];
                    return _CountryRow(
                      country: c,
                      selected: c.iso == widget.selected.iso,
                      onTap: () => Navigator.pop(context, c),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.country,
    required this.selected,
    required this.onTap,
  });

  final Country country;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        // Vertical space comes from the list's itemExtent, so the row only
        // centres inside it; a vertical pad here would fight that.
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Text(country.flag, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                country.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              country.dialCode,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(
              width: 26,
              child: selected
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: AppIcon(
                        AppIcons.check,
                        size: 16,
                        color: AppPalette.solid,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
