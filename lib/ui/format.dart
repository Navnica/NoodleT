import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// "1,4 ГБ". Binary units, as file managers on the desktop show them.
String formatBytes(int bytes, AppLocalizations l) {
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < 4) {
    value /= 1024;
    unit++;
  }
  final number = _number(value, unit == 0 || value >= 100 ? 0 : 1, l);
  return switch (unit) {
    0 => l.sizeB(number),
    1 => l.sizeKb(number),
    2 => l.sizeMb(number),
    3 => l.sizeGb(number),
    _ => l.sizeTb(number),
  };
}

String formatRate(int bytesPerSecond, AppLocalizations l) =>
    l.rate(formatBytes(bytesPerSecond, l));

/// "42,5%", without the fraction at the ends of the scale.
String formatPercent(double progress, AppLocalizations l) {
  final percent = (progress * 100).clamp(0, 100).toDouble();
  if (percent == 0 || percent == 100) return l.percent(_number(percent, 0, l));
  // Never round up to "100%" before the download is really complete.
  return l.percent(_number((percent * 10).floor() / 10, 1, l));
}

/// "2 ч 5 мин": the two most significant units.
String formatDuration(Duration d, AppLocalizations l) {
  if (d.inDays > 0) return l.durationDaysHours(d.inDays, d.inHours % 24);
  if (d.inHours > 0) return l.durationHoursMinutes(d.inHours, d.inMinutes % 60);
  if (d.inMinutes > 0) return l.durationMinutes(d.inMinutes);
  return l.durationSeconds(d.inSeconds < 1 ? 1 : d.inSeconds);
}

/// Upload to download ratio, "0,35".
String formatRatio(double ratio, AppLocalizations l) => _number(ratio, 2, l);

/// "13.10.2026 22:41" in the conventions of the language.
String formatDate(DateTime date, AppLocalizations l) =>
    DateFormat.yMd(l.localeName).add_Hm().format(date);

/// A number with exactly [digits] decimals and the decimal separator of the
/// language, without grouping.
String _number(double value, int digits, AppLocalizations l) =>
    (NumberFormat.decimalPatternDigits(
      locale: l.localeName,
      decimalDigits: digits,
    )..turnOffGrouping()).format(value);
