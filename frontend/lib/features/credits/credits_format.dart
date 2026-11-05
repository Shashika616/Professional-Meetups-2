/// Small display helpers shared by the credits screens. Display only:
/// every number they format came from the server.
library;

String formatCredits(int n) =>
    n == 1 ? '1 credit' : '${formatCreditNumber(n)} credits';

/// "1,000": credits run into the thousands.
String formatCreditNumber(int n) {
  final digits = n.abs().toString();
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+$)'),
    (_) => ',',
  );
  return n < 0 ? '-$grouped' : grouped;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Nov", or "12 Nov 2027" outside the current year.
String formatDay(DateTime d, {DateTime? now}) {
  final local = d.toLocal();
  final year = (now ?? DateTime.now()).year;
  final base = '${local.day} ${_months[local.month - 1]}';
  return local.year == year ? base : '$base ${local.year}';
}
