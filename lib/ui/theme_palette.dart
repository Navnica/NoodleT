import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../settings.dart';
import 'theme.dart';

/// Every theme colour as a round swatch; the name shows on hover.
class ThemePalette extends StatelessWidget {
  const ThemePalette({
    super.key,
    required this.selected,
    required this.onChanged,
    this.size = 36,
    this.spacing = 10,
  });

  final AppAccent selected;
  final ValueChanged<AppAccent> onChanged;

  /// The diameter of a swatch, its ring included.
  final double size;
  final double spacing;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: spacing,
    runSpacing: spacing,
    children: [
      for (final accent in AppAccent.values)
        _Swatch(
          accent: accent,
          size: size,
          selected: accent == selected,
          onTap: () => onChanged(accent),
        ),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.accent,
    required this.size,
    required this.selected,
    required this.onTap,
  });

  final AppAccent accent;
  final double size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accentColor(accent);
    // A tick that reads on light and dark colours alike.
    final tick = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Tooltip(
      message: AppLocalizations.of(context).accentName(accent.name),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size / 12),
          // A ring around the chosen one.
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: selected
                ? Icon(Icons.check_rounded, size: size / 2, color: tick)
                : null,
          ),
        ),
      ),
    );
  }
}
