import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import '../settings.dart';
import '../l10n/app_localizations.dart';
import 'file_list.dart';
import 'format.dart';

/// Returns whether the downloaded files should be deleted too, or null when
/// cancelled.
Future<bool?> showRemoveDialog(BuildContext context, String name) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _RemoveDialog(name: name),
    );

/// Asks which of the [files] of the torrent [name] to download. Returns the
/// indexes of the chosen ones, or null when the user cancels adding it.
Future<Set<int>?> showFileChoiceDialog(
  BuildContext context, {
  required String name,
  required List<TorrentFile> files,
}) => showDialog<Set<int>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _FileChoiceDialog(name: name, files: files),
);

Future<void> showSettingsDialog(
  BuildContext context,
  AppController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _SettingsDialog(controller: controller),
);

class _RemoveDialog extends StatefulWidget {
  const _RemoveDialog({required this.name});

  final String name;

  @override
  State<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<_RemoveDialog> {
  bool _deleteFiles = false;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(s.removeTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _deleteFiles,
              onChanged: (v) => setState(() => _deleteFiles = v ?? false),
              title: Text(s.removeFiles),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, _deleteFiles),
          child: Text(s.remove),
        ),
      ],
    );
  }
}

class _FileChoiceDialog extends StatefulWidget {
  const _FileChoiceDialog({required this.name, required this.files});

  final String name;
  final List<TorrentFile> files;

  @override
  State<_FileChoiceDialog> createState() => _FileChoiceDialogState();
}

class _FileChoiceDialogState extends State<_FileChoiceDialog> {
  late final _chosen = {for (final f in widget.files) f.index};

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final files = [
      for (final f in widget.files)
        TorrentFile(
          index: f.index,
          path: f.path,
          size: f.size,
          done: f.done,
          wanted: _chosen.contains(f.index),
        ),
    ];
    final chosenSize = files
        .where((f) => f.wanted)
        .fold(0, (sum, f) => sum + f.size);
    final totalSize = files.fold(0, (sum, f) => sum + f.size);

    return AlertDialog(
      title: Text(s.chooseFilesTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            FileList(
              files: files,
              showProgress: false,
              onWanted: (indexes, wanted) => setState(() {
                wanted ? _chosen.addAll(indexes) : _chosen.removeAll(indexes);
              }),
            ),
            const SizedBox(height: 8),
            Text(
              s.chosenSize(
                formatBytes(chosenSize, s),
                formatBytes(totalSize, s),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        FilledButton(
          // Nothing to download is no torrent to add.
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, Set.of(_chosen)),
          child: Text(s.add),
        ),
      ],
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.controller});

  final AppController controller;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late String _dir = widget.controller.settings.downloadDir;
  late final _down = _limitField(widget.controller.settings.downloadLimitKb);
  late final _up = _limitField(widget.controller.settings.uploadLimitKb);
  late bool _seed = widget.controller.settings.seedAfterDownload;
  late bool _tray = widget.controller.settings.closeToTray;
  late AppLanguage _language = widget.controller.settings.language;

  static TextEditingController _limitField(int kb) =>
      TextEditingController(text: kb > 0 ? '$kb' : '');

  @override
  void dispose() {
    _down.dispose();
    _up.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final picked = await getDirectoryPath(initialDirectory: _dir);
    if (picked != null && mounted) setState(() => _dir = picked);
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    await widget.controller.updateSettings(
      widget.controller.settings.copyWith(
        downloadDir: _dir,
        downloadLimitKb: int.tryParse(_down.text) ?? 0,
        uploadLimitKb: int.tryParse(_up.text) ?? 0,
        seedAfterDownload: _seed,
        closeToTray: _tray,
        language: _language,
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = theme.textTheme.labelLarge?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: Text(s.settings),
      // Scrolls when the window is too low for all the settings.
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.downloadFolder, style: label),
              const SizedBox(height: 8),
              Material(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _pickDir,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.folder_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _dir,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(onPressed: _pickDir, child: Text(s.change)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _limit(s.downloadLimit, _down, label)),
                  const SizedBox(width: 16),
                  Expanded(child: _limit(s.uploadLimit, _up, label)),
                ],
              ),
              const SizedBox(height: 20),
              Text(s.language, style: label),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppLanguage>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: AppLanguage.system,
                      label: Text(s.languageSystem),
                    ),
                    const ButtonSegment(
                      value: AppLanguage.ru,
                      label: Text('Русский'),
                    ),
                    const ButtonSegment(
                      value: AppLanguage.en,
                      label: Text('English'),
                    ),
                  ],
                  selected: {_language},
                  onSelectionChanged: (choice) =>
                      setState(() => _language = choice.single),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _seed,
                onChanged: (value) => setState(() => _seed = value),
                title: Text(s.seedAfter),
                subtitle: Text(
                  s.seedAfterHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: _tray,
                onChanged: (value) => setState(() => _tray = value),
                title: Text(s.closeToTray),
                subtitle: Text(
                  s.closeToTrayHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(s.save)),
      ],
    );
  }

  Widget _limit(String title, TextEditingController field, TextStyle? label) {
    final s = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: label),
        const SizedBox(height: 8),
        TextField(
          controller: field,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(7),
          ],
          decoration: InputDecoration(
            hintText: s.limitHint,
            suffixText: s.kbPerSecond,
          ),
        ),
      ],
    );
  }
}
