import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'format.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

enum _MenuAction { openFolder, remove }

/// One torrent in the list: a progress ring, the name with a status line, the
/// current speed and the actions. A click anywhere else opens the details.
class TorrentRow extends StatelessWidget {
  const TorrentRow({
    super.key,
    required this.torrent,
    required this.onTap,
    required this.onToggle,
    required this.onOpenFolder,
    required this.onRemove,
    this.selected = false,
    this.onContextMenu,
  });

  final Torrent torrent;

  /// Its details are open next to the list.
  final bool selected;

  /// A right click, at the pointer.
  final ValueChanged<Offset>? onContextMenu;

  /// Opens the details of the torrent.
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onOpenFolder;
  final VoidCallback onRemove;

  bool get _resumable =>
      torrent.isPaused || torrent.state == TorrentState.error;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = stateColor(scheme, torrent.shownState);
    const figures = [FontFeature.tabularFigures()];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 520;
        final side = _side(s);
        return _StateCard(
          color: accent,
          selected: selected,
          onTap: onTap,
          onSecondaryTap: onContextMenu,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 2, 9),
            child: Row(
              children: [
                _Ring(
                  progress: torrent.shownState == TorrentState.metadata
                      ? null
                      : torrent.progress,
                  color: accent,
                  track: scheme.surfaceContainerHighest,
                  child: _ringContent(theme, accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        torrent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // The second line never comes and goes, so the card
                      // keeps its height whatever the state. A narrow card
                      // has no room at the side: the speed ends this line.
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _status(s, wide).join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: torrent.state == TorrentState.error
                                    ? scheme.error
                                    : scheme.onSurfaceVariant,
                                fontFeatures: figures,
                              ),
                            ),
                          ),
                          if (!wide && side.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              side.first,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accent,
                                fontWeight: FontWeight.w600,
                                fontFeatures: figures,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (wide && side.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        side.first,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w600,
                          fontFeatures: figures,
                        ),
                      ),
                      if (side.length > 1) ...[
                        const SizedBox(height: 3),
                        Text(
                          side[1],
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: figures,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 22,
                  tooltip: _resumable ? s.resume : s.pause,
                  onPressed: onToggle,
                  icon: Icon(
                    _resumable ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  ),
                ),
                PopupMenuButton<_MenuAction>(
                  tooltip: '',
                  iconSize: 22,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (action) => switch (action) {
                    _MenuAction.openFolder => onOpenFolder(),
                    _MenuAction.remove => onRemove(),
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _MenuAction.openFolder,
                      child: _MenuRow(Icons.folder_open_rounded, s.openFolder),
                    ),
                    PopupMenuItem(
                      value: _MenuAction.remove,
                      child: _MenuRow(
                        Icons.delete_outline_rounded,
                        s.remove,
                        color: scheme.error,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A download shows its percentage inside the ring, every other state an
  /// icon.
  Widget _ringContent(ThemeData theme, Color accent) {
    final icon = switch (torrent.shownState) {
      TorrentState.paused => Icons.pause_rounded,
      TorrentState.checking => Icons.sync_rounded,
      TorrentState.metadata => Icons.link_rounded,
      // A tick once it is stopped, an arrow while it is still seeding.
      TorrentState.seeding =>
        torrent.isPaused ? Icons.check_rounded : Icons.arrow_upward_rounded,
      TorrentState.error => Icons.priority_high_rounded,
      TorrentState.downloading => null,
    };
    if (icon != null) return Icon(icon, size: 17, color: accent);
    return Text(
      '${(torrent.progress * 100).floor()}',
      style: theme.textTheme.labelMedium?.copyWith(
        color: accent,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  /// The line under the name. A narrow card also tells the time left here.
  List<String> _status(AppLocalizations s, bool wide) {
    final amount = torrent.size > 0
        ? s.amountOf(formatBytes(torrent.done, s), formatBytes(torrent.size, s))
        : null;
    return switch (torrent.shownState) {
      TorrentState.error => [torrent.error],
      TorrentState.metadata => [s.metadata, s.peersCount(torrent.peers)],
      TorrentState.checking => [
        '${s.checking} ${formatPercent(torrent.progress, s)}',
      ],
      TorrentState.paused => [s.paused, ?amount],
      TorrentState.seeding => [
        torrent.isPaused ? s.done : s.seeding,
        formatBytes(torrent.size, s),
      ],
      TorrentState.downloading => [
        ?amount,
        if (wide)
          s.peersCount(torrent.peers)
        else if (torrent.eta case final eta?)
          formatDuration(eta, s),
      ],
    };
  }

  /// The speed and, under it, the time left.
  List<String> _side(AppLocalizations s) => switch (torrent.state) {
    TorrentState.downloading => [
      '↓ ${formatRate(torrent.downloadRate, s)}',
      if (torrent.eta case final eta?) formatDuration(eta, s),
    ],
    TorrentState.seeding => ['↑ ${formatRate(torrent.uploadRate, s)}'],
    _ => const [],
  };
}

/// A card of its own for every torrent, tinted with the colour of its state.
class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.color,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTap,
    required this.child,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onSecondaryTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Color.alphaBlend(
      color.withValues(alpha: 0.09),
      scheme.surfaceContainerLow,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, t, _) => Material(
        // A little more of the state's colour while chosen.
        color: Color.lerp(
          base,
          Color.alphaBlend(color.withValues(alpha: 0.16), base),
          t,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.7 * t), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapUp: onSecondaryTap == null
              ? null
              : (details) => onSecondaryTap!(details.globalPosition),
          child: child,
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.progress,
    required this.color,
    required this.track,
    required this.child,
  });

  /// null draws a spinning ring.
  final double? progress;
  final Color color;
  final Color track;
  final Widget child;

  static const _size = 36.0;

  @override
  Widget build(BuildContext context) {
    final target = progress;
    return SizedBox.square(
      dimension: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: target == null
                ? _ring(null)
                : TweenAnimationBuilder<double>(
                    tween: Tween(end: target.clamp(0, 1)),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOut,
                    builder: (context, shown, _) => _ring(shown),
                  ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _ring(double? shown) => CircularProgressIndicator(
    value: shown,
    strokeWidth: 3,
    strokeCap: StrokeCap.round,
    color: color,
    backgroundColor: track,
    constraints: const BoxConstraints.tightFor(width: _size, height: _size),
    padding: EdgeInsets.zero,
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: color)),
    ],
  );
}
