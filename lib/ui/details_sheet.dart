import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import 'format.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

/// Slides up a panel with everything known about the torrent [id]. It follows
/// the torrent live and closes by itself once the torrent is gone.
Future<void> showDetailsSheet(
  BuildContext context, {
  required AppController controller,
  required String id,
  required void Function(Torrent) onOpenFolder,
  required void Function(Torrent) onRemove,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 680),
  builder: (_) => _DetailsSheet(
    controller: controller,
    id: id,
    onOpenFolder: onOpenFolder,
    onRemove: onRemove,
  ),
);

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({
    required this.controller,
    required this.id,
    required this.onOpenFolder,
    required this.onRemove,
  });

  final AppController controller;
  final String id;
  final void Function(Torrent) onOpenFolder;
  final void Function(Torrent) onRemove;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final torrent = controller.torrents.where((t) => t.id == id).firstOrNull;
      if (torrent == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) Navigator.maybePop(context);
        });
        return const SizedBox(height: 120);
      }
      return TorrentDetails(
        torrent: torrent,
        onToggle: () => controller.toggle(torrent),
        onOpenFolder: () => onOpenFolder(torrent),
        onRemove: () => onRemove(torrent),
      );
    },
  );
}

/// The content of the details panel.
class TorrentDetails extends StatelessWidget {
  const TorrentDetails({
    super.key,
    required this.torrent,
    required this.onToggle,
    required this.onOpenFolder,
    required this.onRemove,
  });

  final Torrent torrent;
  final VoidCallback onToggle;
  final VoidCallback onOpenFolder;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = torrent;
    final accent = stateColor(scheme, t.shownState);
    final resumable = t.isPaused || t.state == TorrentState.error;
    final facts = <(String, String)>[
      (s.size, t.size > 0 ? formatBytes(t.size, s) : '—'),
      (s.downloaded, formatBytes(t.done, s)),
      (s.download, formatRate(t.downloadRate, s)),
      (s.upload, formatRate(t.uploadRate, s)),
      (s.uploaded, formatBytes(t.uploaded, s)),
      (s.ratio, t.done > 0 ? formatRatio(t.uploaded / t.done, s) : '—'),
      (s.timeLeft, t.eta == null ? '—' : formatDuration(t.eta!, s)),
      ('${s.peersLabel} / ${s.seedsLabel}', '${t.peers} / ${t.seeds}'),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.state == TorrentState.error
                ? '${s.failed}: ${t.error}'
                : '${_stateName(s)}  ·  ${formatPercent(t.progress, s)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: accent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: t.state == TorrentState.metadata ? null : t.progress,
            minHeight: 6,
            color: accent,
            backgroundColor: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
            // ignore: deprecated_member_use
            year2023: false,
            stopIndicatorColor: Colors.transparent,
            trackGap: 0,
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 520 ? 4 : 2;
              final width = constraints.maxWidth / columns;
              return Wrap(
                runSpacing: 18,
                children: [
                  for (final (label, value) in facts)
                    SizedBox(
                      width: width,
                      child: _Fact(label: label, value: value),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          _Line(
            label: s.folder,
            value: t.savePath,
            icon: Icons.folder_open_rounded,
            tooltip: s.openFolder,
            onPressed: onOpenFolder,
          ),
          const SizedBox(height: 14),
          _Line(
            label: s.hash,
            value: t.id,
            icon: Icons.copy_rounded,
            tooltip: s.copy,
            onPressed: () => Clipboard.setData(ClipboardData(text: t.id)),
          ),
          const SizedBox(height: 14),
          _Fact(
            label: s.addedOn,
            value: t.added > 0
                ? formatDate(
                    DateTime.fromMillisecondsSinceEpoch(t.added * 1000),
                    s,
                  )
                : '—',
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                onPressed: onToggle,
                icon: Icon(
                  resumable ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 20,
                ),
                label: Text(resumable ? s.resume : s.pause),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onRemove,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(s.remove),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _stateName(AppLocalizations s) => switch (torrent.shownState) {
    TorrentState.paused => s.paused,
    TorrentState.checking => s.checking,
    TorrentState.metadata => s.metadata,
    TorrentState.downloading => s.downloading,
    TorrentState.seeding => torrent.isPaused ? s.done : s.seeding,
    TorrentState.error => s.failed,
  };
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// A long value on its own line with one action next to it.
class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String value;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                value,
                maxLines: 1,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
        ),
      ],
    );
  }
}
