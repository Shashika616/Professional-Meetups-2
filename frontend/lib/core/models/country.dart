/// The dial codes the phone-verification field offers.
///
/// # WHY THERE IS A PICKER NOW
///
/// The phone screen used to hard-code `+94` with a comment reasoning that
/// "the launch market is Sri Lanka only, so a full multi-country picker
/// isn't justified". That holds right up until the first member who is
/// Sri Lankan but lives in Dubai, or the first visiting professional —
/// neither of whom can verify at all, because the field silently prefixes
/// a country code they cannot change. The cost of being wrong is a user
/// who cannot finish onboarding; the cost of the picker is this file.
///
/// Sri Lanka is still the default ([kDefaultCountry]), so the common case
/// is unchanged: open the screen, type a local number, send.
///
/// The list is ordered with the markets this app actually sees first, then
/// roughly by region, because a picker that opens on Afghanistan because
/// the list is alphabetical makes the common case slower.
library;

/// One dialable country.
class Country {
  const Country(this.iso, this.name, this.dialCode);

  /// ISO 3166-1 alpha-2, uppercase. Also what [flag] is derived from.
  final String iso;
  final String name;

  /// E.164 prefix, including the leading `+`.
  final String dialCode;

  /// The country's flag, built from the ISO code rather than stored: a
  /// regional-indicator pair is exactly what a flag emoji is, so there is
  /// no second list to keep in sync with the first.
  ///
  /// This is a flag, not an icon standing in for one — it is the country's
  /// own mark, which is why every phone field in every app shows it. The
  /// ISO code is rendered beside it for anyone whose platform draws the
  /// pair as letters instead (older Windows, some Android builds), so the
  /// row is never ambiguous.
  String get flag =>
      String.fromCharCodes(iso.codeUnits.map((c) => 0x1F1E6 + (c - 0x41)));

  /// True when [query] matches the name, the ISO code or the dial code —
  /// so "sri", "lk", "94" and "+94" all find Sri Lanka.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        iso.toLowerCase().startsWith(q) ||
        dialCode.contains(q) ||
        dialCode.substring(1).startsWith(q);
  }
}

/// What the phone field starts on, and what an unrecognised stored number
/// falls back to.
const Country kDefaultCountry = Country('LK', 'Sri Lanka', '+94');

const List<Country> kCountries = <Country>[
  Country('LK', 'Sri Lanka', '+94'),
  Country('IN', 'India', '+91'),
  Country('GB', 'United Kingdom', '+44'),
  Country('US', 'United States', '+1'),
  Country('AU', 'Australia', '+61'),
  Country('CA', 'Canada', '+1'),
  Country('AE', 'United Arab Emirates', '+971'),
  Country('SG', 'Singapore', '+65'),
  Country('MY', 'Malaysia', '+60'),
  Country('NZ', 'New Zealand', '+64'),
  Country('DE', 'Germany', '+49'),
  Country('FR', 'France', '+33'),
  Country('NL', 'Netherlands', '+31'),
  Country('IE', 'Ireland', '+353'),
  Country('IT', 'Italy', '+39'),
  Country('ES', 'Spain', '+34'),
  Country('PT', 'Portugal', '+351'),
  Country('SE', 'Sweden', '+46'),
  Country('NO', 'Norway', '+47'),
  Country('DK', 'Denmark', '+45'),
  Country('FI', 'Finland', '+358'),
  Country('CH', 'Switzerland', '+41'),
  Country('AT', 'Austria', '+43'),
  Country('BE', 'Belgium', '+32'),
  Country('PL', 'Poland', '+48'),
  Country('CZ', 'Czechia', '+420'),
  Country('RO', 'Romania', '+40'),
  Country('GR', 'Greece', '+30'),
  Country('HU', 'Hungary', '+36'),
  Country('UA', 'Ukraine', '+380'),
  Country('TR', 'Turkey', '+90'),
  Country('RU', 'Russia', '+7'),
  Country('IL', 'Israel', '+972'),
  Country('SA', 'Saudi Arabia', '+966'),
  Country('QA', 'Qatar', '+974'),
  Country('KW', 'Kuwait', '+965'),
  Country('BH', 'Bahrain', '+973'),
  Country('OM', 'Oman', '+968'),
  Country('JO', 'Jordan', '+962'),
  Country('LB', 'Lebanon', '+961'),
  Country('EG', 'Egypt', '+20'),
  Country('ZA', 'South Africa', '+27'),
  Country('NG', 'Nigeria', '+234'),
  Country('KE', 'Kenya', '+254'),
  Country('GH', 'Ghana', '+233'),
  Country('TZ', 'Tanzania', '+255'),
  Country('UG', 'Uganda', '+256'),
  Country('MA', 'Morocco', '+212'),
  Country('DZ', 'Algeria', '+213'),
  Country('TN', 'Tunisia', '+216'),
  Country('ET', 'Ethiopia', '+251'),
  Country('PK', 'Pakistan', '+92'),
  Country('BD', 'Bangladesh', '+880'),
  Country('NP', 'Nepal', '+977'),
  Country('MV', 'Maldives', '+960'),
  Country('BT', 'Bhutan', '+975'),
  Country('AF', 'Afghanistan', '+93'),
  Country('CN', 'China', '+86'),
  Country('HK', 'Hong Kong', '+852'),
  Country('TW', 'Taiwan', '+886'),
  Country('JP', 'Japan', '+81'),
  Country('KR', 'South Korea', '+82'),
  Country('TH', 'Thailand', '+66'),
  Country('VN', 'Vietnam', '+84'),
  Country('PH', 'Philippines', '+63'),
  Country('ID', 'Indonesia', '+62'),
  Country('MM', 'Myanmar', '+95'),
  Country('KH', 'Cambodia', '+855'),
  Country('LA', 'Laos', '+856'),
  Country('BN', 'Brunei', '+673'),
  Country('MN', 'Mongolia', '+976'),
  Country('KZ', 'Kazakhstan', '+7'),
  Country('UZ', 'Uzbekistan', '+998'),
  Country('BR', 'Brazil', '+55'),
  Country('AR', 'Argentina', '+54'),
  Country('CL', 'Chile', '+56'),
  Country('CO', 'Colombia', '+57'),
  Country('PE', 'Peru', '+51'),
  Country('MX', 'Mexico', '+52'),
  Country('UY', 'Uruguay', '+598'),
  Country('EC', 'Ecuador', '+593'),
  Country('BO', 'Bolivia', '+591'),
  Country('PY', 'Paraguay', '+595'),
  Country('VE', 'Venezuela', '+58'),
  Country('CR', 'Costa Rica', '+506'),
  Country('PA', 'Panama', '+507'),
  Country('GT', 'Guatemala', '+502'),
  Country('DO', 'Dominican Republic', '+1809'),
  Country('JM', 'Jamaica', '+1876'),
  Country('TT', 'Trinidad and Tobago', '+1868'),
  Country('IS', 'Iceland', '+354'),
  Country('LU', 'Luxembourg', '+352'),
  Country('MT', 'Malta', '+356'),
  Country('CY', 'Cyprus', '+357'),
  Country('EE', 'Estonia', '+372'),
  Country('LV', 'Latvia', '+371'),
  Country('LT', 'Lithuania', '+370'),
  Country('SI', 'Slovenia', '+386'),
  Country('SK', 'Slovakia', '+421'),
  Country('HR', 'Croatia', '+385'),
  Country('RS', 'Serbia', '+381'),
  Country('BG', 'Bulgaria', '+359'),
  Country('FJ', 'Fiji', '+679'),
  Country('PG', 'Papua New Guinea', '+675'),
  Country('MU', 'Mauritius', '+230'),
  Country('SC', 'Seychelles', '+248'),
];

/// Splits an E.164 number into its country and the local part, for
/// pre-filling the field when an already-verified number is being edited.
///
/// Longest dial code wins, so `+1809…` resolves to the Dominican Republic
/// rather than to the US; an unrecognised or malformed value falls back to
/// [kDefaultCountry] with the whole string as the local part, which keeps
/// the user's digits on screen instead of quietly dropping them.
({Country country, String localNumber}) splitPhoneNumber(String? e164) {
  final value = (e164 ?? '').trim();
  if (!value.startsWith('+')) {
    return (country: kDefaultCountry, localNumber: value);
  }
  Country? best;
  for (final c in kCountries) {
    if (value.startsWith(c.dialCode)) {
      if (best == null || c.dialCode.length > best.dialCode.length) best = c;
    }
  }
  if (best == null) return (country: kDefaultCountry, localNumber: value);
  return (country: best, localNumber: value.substring(best.dialCode.length));
}
