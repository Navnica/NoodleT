import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import '../settings.dart';
import '../l10n/app_localizations.dart';
import 'file_list.dart';
import 'format.dart';
import 'theme_palette.dart';

/// Returns whether the downloaded files should be deleted too, or null when
/// cancelled.
Future<bool?> showRemoveDialog(BuildContext context, String name) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _RemoveDialog(name: name),
    );

/// What the user picked for a torrent just added: the indexes of the [files]
/// to download and the [folder] to put them in.
typedef FilePick = ({Set<int> files, String folder});

/// Asks which of the [files] of the torrent [name] to download, and where;
/// [folder] is offered first. Returns null when the user cancels adding it.
Future<FilePick?> showFileChoiceDialog(
  BuildContext context, {
  required String name,
  required List<TorrentFile> files,
  required String folder,
}) => showDialog<FilePick>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _FileChoiceDialog(name: name, files: files, folder: folder),
);

/// Asks for a folder, starting in [initial]; null when cancelled.
Future<String?> pickFolder(String initial) =>
    getDirectoryPath(initialDirectory: initial);

/// A folder path with a button that changes it.
class FolderField extends StatelessWidget {
  const FolderField({
    super.key,
    required this.path,
    required this.onChanged,
    this.label,
  });

  final String path;
  final ValueChanged<String> onChanged;
  final String? label;

  Future<void> _pick() async {
    final picked = await pickFolder(path);
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _pick,
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
                child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              TextButton(onPressed: _pick, child: Text(label ?? s.change)),
            ],
          ),
        ),
      ),
    );
  }
}

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
  const _FileChoiceDialog({
    required this.name,
    required this.files,
    required this.folder,
  });

  final String name;
  final List<TorrentFile> files;
  final String folder;

  @override
  State<_FileChoiceDialog> createState() => _FileChoiceDialogState();
}

class _FileChoiceDialogState extends State<_FileChoiceDialog> {
  late final _chosen = {for (final f in widget.files) f.index};
  late String _folder = widget.folder;

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
            const SizedBox(height: 16),
            Text(
              s.saveTo,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            FolderField(
              path: _folder,
              onChanged: (folder) => setState(() => _folder = folder),
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
              : () => Navigator.pop<FilePick>(context, (
                  files: Set.of(_chosen),
                  folder: _folder,
                )),
          child: Text(s.add),
        ),
      ],
    );
  }
}

/// The tabs of the settings.
enum _SettingsTab {
  downloads,
  interface,
  app;

  String title(AppLocalizations s) => switch (this) {
    downloads => s.settingsDownloads,
    interface => s.settingsAppearance,
    app => s.settingsInterface,
  };
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
  late bool _updates = widget.controller.settings.checkUpdates;
  late AppThemeMode _themeMode = widget.controller.settings.themeMode;
  late AppAccent _accent = widget.controller.settings.accent;

  _SettingsTab _tab = _SettingsTab.downloads;

  static TextEditingController _limitField(int kb) =>
      TextEditingController(text: kb > 0 ? '$kb' : '');

  @override
  void dispose() {
    _down.dispose();
    _up.dispose();
    super.dispose();
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
        checkUpdates: _updates,
        themeMode: _themeMode,
        accent: _accent,
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final compact = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(96, 36)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      // The same size on every tab, so that it does not jump.
      child: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.settings,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: s.cancel,
                    iconSize: 18,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final tab in _SettingsTab.values)
                    _Tab(
                      label: tab.title(s),
                      selected: tab == _tab,
                      onTap: () => setState(() => _tab = tab),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Scrolls when the window is too low for all the settings.
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: switch (_tab) {
                    _SettingsTab.downloads => _downloads(s, theme),
                    _SettingsTab.interface => _interface(s),
                    _SettingsTab.app => _app(s),
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: compact,
                    onPressed: () => Navigator.pop(context),
                    child: Text(s.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: compact,
                    onPressed: _save,
                    child: Text(s.save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Where the downloads go, whether they seed, and how fast they may be.
  List<Widget> _downloads(AppLocalizations s, ThemeData theme) => [
    _Section(
      children: [
        _FormRow(
          label: s.downloadFolder,
          child: FolderField(
            path: _dir,
            onChanged: (dir) => setState(() => _dir = dir),
          ),
        ),
        _FormRow(
          child: _Check(
            value: _seed,
            title: s.seedAfter,
            hint: s.seedAfterHint,
            onChanged: (value) => setState(() => _seed = value),
          ),
        ),
      ],
    ),
    _Section(
      title: s.settingsSpeed,
      children: [
        _FormRow(label: s.downloadLimit, child: _limit(_down)),
        _FormRow(label: s.uploadLimit, child: _limit(_up)),
        _FormRow(
          child: Text(
            s.limitsHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  ];

  /// What the window looks like: its language, light or dark, its colour.
  List<Widget> _interface(AppLocalizations s) => [
    _Section(
      children: [
        _FormRow(
          label: s.language,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 200,
              child: DropdownButtonFormField<AppLanguage>(
                initialValue: _language,
                isDense: true,
                borderRadius: BorderRadius.circular(8),
                items: [
                  DropdownMenuItem(
                    value: AppLanguage.system,
                    child: Text(s.languageSystem),
                  ),
                  const DropdownMenuItem(
                    value: AppLanguage.ru,
                    child: Text('Русский'),
                  ),
                  const DropdownMenuItem(
                    value: AppLanguage.en,
                    child: Text('English'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _language = value ?? _language),
              ),
            ),
          ),
        ),
        _FormRow(
          label: s.themeMode,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<AppThemeMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                  value: AppThemeMode.system,
                  icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                  label: Text(s.themeSystem),
                ),
                ButtonSegment(
                  value: AppThemeMode.light,
                  icon: const Icon(Icons.light_mode_outlined, size: 18),
                  label: Text(s.themeLight),
                ),
                ButtonSegment(
                  value: AppThemeMode.dark,
                  icon: const Icon(Icons.dark_mode_outlined, size: 18),
                  label: Text(s.themeDark),
                ),
              ],
              selected: {_themeMode},
              onSelectionChanged: (choice) =>
                  setState(() => _themeMode = choice.single),
            ),
          ),
        ),
        _FormRow(
          label: s.accentLabel,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ThemePalette(
              selected: _accent,
              onChanged: (accent) => setState(() => _accent = accent),
            ),
          ),
        ),
      ],
    ),
  ];

  /// How NoodleT behaves around the window: the tray and the updates.
  List<Widget> _app(AppLocalizations s) => [
    _Section(
      children: [
        // No labels here, so no column for them either.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _Check(
            value: _tray,
            title: s.closeToTray,
            hint: s.closeToTrayHint,
            onChanged: (value) => setState(() => _tray = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _Check(
            value: _updates,
            title: s.checkUpdates,
            hint: s.checkUpdatesHint,
            onChanged: (value) => setState(() => _updates = value),
          ),
        ),
      ],
    ),
  ];

  /// A speed limit in KB/s, the unit after the field.
  Widget _limit(TextEditingController field) {
    final s = AppLocalizations.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: field,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.end,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(7),
            ],
            decoration: InputDecoration(
              hintText: s.limitHint,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(s.kbPerSecond),
      ],
    );
  }
}

/// A tab of the settings, underlined while open.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}

/// A titled frame around a few settings that belong together.
class _Section extends StatelessWidget {
  const _Section({required this.children, this.title});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title case final title?)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            // A frame only: the fields inside keep their own fill.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// A form line: the label in a column of its own, the control after it. A
/// line without a label lines its control up with the others.
class _FormRow extends StatelessWidget {
  const _FormRow({required this.child, this.label});

  final String? label;
  final Widget child;

  static const _labelWidth = 150.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: label == null
                ? null
                : Text(label!, style: theme.textTheme.bodyMedium),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A checkbox with its name and, under it, what it does.
class _Check extends StatelessWidget {
  const _Check({
    required this.value,
    required this.title,
    required this.hint,
    required this.onChanged,
  });

  final bool value;
  final String title;
  final String hint;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
