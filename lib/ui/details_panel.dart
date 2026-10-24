import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import 'dialogs.dart';
import 'file_list.dart';
import 'format.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

/// The panel next to the list with everything known about the torrent [id].
/// It follows the torrent live and closes by itself once the torrent is gone.
class DetailsPanel extends StatelessWidget {
  const DetailsPanel({
    super.key,
    required this.controller,
    required this.id,
    required this.onOpenFolder,
    required this.onRemove,
    required this.onClose,
  });

  final AppController controller;
  final String id;
  final void Function(Torrent) onOpenFolder;
  final void Function(Torrent) onRemove;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final torrent = controller.torrents.where((t) => t.id == id).firstOrNull;
    if (torrent == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onClose());
      return const SizedBox.shrink();
    }
    return TorrentDetails(
      torrent: torrent,
      onClose: onClose,
      files: controller.files(torrent.id),
      onToggle: () => controller.toggle(torrent),
      onOpenFolder: () => onOpenFolder(torrent),
      onRemove: () => onRemove(torrent),
      onFilesWanted: (indexes, wanted) =>
          controller.setFilesWanted(torrent, indexes, wanted: wanted),
      onSequential: (sequential) =>
          controller.setSequential(torrent, sequential: sequential),
      onMove: () async {
        final folder = await pickFolder(torrent.savePath);
        if (folder != null) controller.move(torrent, folder);
      },
      trackers: () => controller.trackers(torrent),
      onAddTrackers: (text) => controller.addTrackers(torrent, text),
      peers: () => controller.peers(torrent),
    );
  }
}

/// The content of the details panel.
class TorrentDetails extends StatelessWidget {
  const TorrentDetails({
    super.key,
    required this.torrent,
    required this.onToggle,
    required this.onOpenFolder,
    required this.onRemove,
    this.onClose,
    this.files = const [],
    this.onFilesWanted,
    this.onSequential,
    this.onMove,
    this.trackers,
    this.onAddTrackers,
    this.peers,
  });

  final Torrent torrent;
  final VoidCallback onToggle;
  final VoidCallback onOpenFolder;
  final VoidCallback onRemove;

  /// Closes the panel; no button without it.
  final VoidCallback? onClose;

  /// Listed with a checkbox each when there are several.
  final List<TorrentFile> files;
  final void Function(Iterable<int> indexes, bool wanted)? onFilesWanted;

  /// Switches the download in order; the switch is hidden without it.
  final ValueChanged<bool>? onSequential;

  /// Moves the files elsewhere; no button without it.
  final VoidCallback? onMove;

  /// Read only while their section is open, since they cost a call into
  /// the engine each.
  final List<String> Function()? trackers;
  final List<Peer> Function()? peers;

  /// Adds the trackers in the text, one per line.
  final ValueChanged<String>? onAddTrackers;

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

    // The actions stay at the top while the rest scrolls under them.
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          FilledButton.tonalIcon(
            onPressed: onToggle,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            icon: Icon(
              resumable ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 18,
            ),
            label: Text(resumable ? s.resume : s.pause),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onRemove,
            style: TextButton.styleFrom(
              foregroundColor: scheme.error,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(s.remove),
          ),
          const Spacer(),
          IconButton(
            tooltip: s.openFolder,
            onPressed: onOpenFolder,
            iconSize: 20,
            icon: const Icon(Icons.folder_open_rounded),
          ),
          if (onClose case final close?)
            IconButton(
              tooltip: '${s.hideDetails} (Esc)',
              onPressed: close,
              iconSize: 20,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );

    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
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
          if (files.length > 1) ...[
            const SizedBox(height: 22),
            FileList(files: files, onWanted: onFilesWanted),
          ],
          if (onSequential case final onChanged?) ...[
            const SizedBox(height: 12),
            SwitchListTile(
              value: t.sequential,
              onChanged: onChanged,
              title: Text(s.sequential),
              subtitle: Text(
                s.sequentialHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
          if (trackers case final read?)
            _Section(
              title: s.trackers,
              builder: (context) =>
                  _Trackers(trackers: read(), onAdd: onAddTrackers),
            ),
          if (peers case final read?)
            _Section(
              title: '${s.peersLabel} (${t.peers})',
              builder: (context) => _Peers(peers: read()),
            ),
          const SizedBox(height: 22),
          _Line(
            label: s.folder,
            value: t.savePath,
            icon: Icons.folder_open_rounded,
            tooltip: s.openFolder,
            onPressed: onOpenFolder,
            secondIcon: onMove == null ? null : Icons.drive_file_move_outline,
            secondTooltip: s.move,
            onSecondPressed: onMove,
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
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        const Divider(height: 1),
        Expanded(child: content),
      ],
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

/// A section that opens on a click and builds its content only while open.
class _Section extends StatefulWidget {
  const _Section({required this.title, required this.builder});

  final String title;
  final WidgetBuilder builder;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleSmall),
                ),
                Icon(
                  _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (_open) widget.builder(context),
      ],
    );
  }
}

class _Trackers extends StatefulWidget {
  const _Trackers({required this.trackers, this.onAdd});

  final List<String> trackers;
  final ValueChanged<String>? onAdd;

  @override
  State<_Trackers> createState() => _TrackersState();
}

class _TrackersState extends State<_Trackers> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    if (_field.text.trim().isEmpty) return;
    widget.onAdd?.call(_field.text);
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.trackers.isEmpty)
          Text(s.noTrackers, style: muted)
        else
          for (final url in widget.trackers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                url,
                maxLines: 1,
                style: theme.textTheme.bodySmall,
              ),
            ),
        if (widget.onAdd != null) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _field,
            minLines: 1,
            maxLines: 4,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: s.trackersHint,
              suffixIcon: IconButton(
                tooltip: s.addTrackers,
                onPressed: _add,
                icon: const Icon(Icons.add_rounded, size: 20),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Peers extends StatelessWidget {
  const _Peers({required this.peers});

  final List<Peer> peers;

  /// More would only make the panel long; the fastest come first.
  static const _shown = 30;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final figures = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (peers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s.noPeers, style: muted),
      );
    }
    return Column(
      children: [
        for (final peer in peers.take(_shown))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    peer.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: figures,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    peer.client,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
                SizedBox(
                  width: 170,
                  child: Text(
                    '↓ ${formatRate(peer.downloadRate, s)}  '
                    '↑ ${formatRate(peer.uploadRate, s)}',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    style: figures,
                  ),
                ),
              ],
            ),
          ),
        if (peers.length > _shown)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(s.trayMore(peers.length - _shown), style: muted),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A long value on its own line with an action or two next to it.
class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.secondIcon,
    this.secondTooltip = '',
    this.onSecondPressed,
  });

  final String label;
  final String value;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final IconData? secondIcon;
  final String secondTooltip;
  final VoidCallback? onSecondPressed;

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
        if (secondIcon case final second?)
          IconButton(
            tooltip: secondTooltip,
            onPressed: onSecondPressed,
            icon: Icon(second, size: 20),
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
