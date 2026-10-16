import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../l10n/app_localizations.dart';
import 'format.dart';

/// The files of a torrent, each with a checkbox that decides whether it is
/// downloaded, and one more on top for all of them. Shown in the details
/// panel and when a torrent of several files is added.
class FileList extends StatelessWidget {
  const FileList({
    super.key,
    required this.files,
    required this.onWanted,
    this.showProgress = true,
  });

  final List<TorrentFile> files;
  final void Function(Iterable<int> indexes, bool wanted)? onWanted;

  /// Off before anything is downloaded, where every file is at 0%.
  final bool showProgress;

  static const _rowHeight = 44.0;
  static const _maxRows = 7;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final wanted = files.where((f) => f.wanted).length;
    final all = wanted == files.length
        ? true
        : wanted == 0
        ? false
        : null;
    final root = _commonFolder(files);
    final onWanted = this.onWanted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${s.files}  ·  ${s.filesChosen(wanted, files.length)}',
                style: muted,
              ),
            ),
            Tooltip(
              message: s.selectAll,
              child: Checkbox(
                tristate: true,
                value: all,
                onChanged: onWanted == null
                    ? null
                    // A partial choice turns into all files.
                    : (_) => onWanted([
                        for (final f in files) f.index,
                      ], all != true),
              ),
            ),
          ],
        ),
        SizedBox(
          height: _rowHeight * files.length.clamp(1, _maxRows),
          child: ListView.builder(
            itemCount: files.length,
            itemExtent: _rowHeight,
            itemBuilder: (context, i) {
              final file = files[i];
              final path = file.path.substring(root.length);
              return Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: path,
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: file.wanted
                              ? null
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    showProgress
                        ? '${formatPercent(file.progress, s)}  ·  '
                              '${formatBytes(file.size, s)}'
                        : formatBytes(file.size, s),
                    style: muted,
                  ),
                  Checkbox(
                    value: file.wanted,
                    onChanged: onWanted == null
                        ? null
                        : (value) => onWanted([file.index], value ?? true),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// "Album/" when every file sits in that folder, as the files of a
  /// multi-file torrent do; it is the torrent's name and need not repeat.
  static String _commonFolder(List<TorrentFile> files) {
    if (files.isEmpty) return '';
    final first = files.first.path;
    final slash = first.indexOf('/');
    if (slash < 0) return '';
    final folder = first.substring(0, slash + 1);
    return files.every((f) => f.path.startsWith(folder)) ? folder : '';
  }
}
