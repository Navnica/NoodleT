import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import '../proxy_check.dart';
import '../settings.dart';
import '../updates.dart';
import '../version.dart';
import '../l10n/app_localizations.dart';
import 'file_list.dart';
import 'format.dart';
import 'system.dart';
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
  late ProxyKind _proxyKind = widget.controller.settings.proxy.kind;
  late final _proxyHost = TextEditingController(
    text: widget.controller.settings.proxy.host,
  );
  late final _proxyPort = TextEditingController(
    text: widget.controller.settings.proxy.port > 0
        ? '${widget.controller.settings.proxy.port}'
        : '',
  );
  late final _proxyUser = TextEditingController(
    text: widget.controller.settings.proxy.username,
  );
  late final _proxyPassword = TextEditingController(
    text: widget.controller.settings.proxy.password,
  );
  bool _showPassword = false;

  /// The last check of the proxy: null before one, or while it runs.
  ({ProxyCheckResult result, String detail})? _check;
  bool _checking = false;

  ProxyConfig get _proxy => ProxyConfig(
    kind: _proxyKind,
    host: _proxyHost.text.trim(),
    port: int.tryParse(_proxyPort.text) ?? 0,
    username: _proxyUser.text,
    password: _proxyPassword.text,
  );

  @override
  void initState() {
    super.initState();
    // The Save button and the check follow what is typed.
    for (final field in [_proxyHost, _proxyPort, _proxyUser, _proxyPassword]) {
      field.addListener(() => setState(() => _check = null));
    }
  }

  Future<void> _checkProxy() async {
    setState(() {
      _checking = true;
      _check = null;
    });
    var detail = '';
    final result = await checkProxy(_proxy, detail: (text) => detail = text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _check = (result: result, detail: detail);
    });
  }

  /// Scrolled down to the proxy fields once they open.
  final _scroll = ScrollController();

  static TextEditingController _limitField(int kb) =>
      TextEditingController(text: kb > 0 ? '$kb' : '');

  @override
  void dispose() {
    _scroll.dispose();
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPassword.dispose();
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
        proxy: _proxy,
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final proxyOn = _proxyKind != ProxyKind.none;

    return AlertDialog(
      title: Text(s.settings),
      // Scrolls when the window is too low for all the settings.
      content: SizedBox(
        width: 660,
        // Scrolls by the wheel only: a scroll bar would cover the controls
        // along the right edge.
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Group(s.settingsDownloads),
                _Setting(
                  title: s.downloadFolder,
                  wide: true,
                  control: FolderField(
                    path: _dir,
                    onChanged: (dir) => setState(() => _dir = dir),
                  ),
                ),
                _Setting(
                  title: s.seedAfter,
                  hint: s.seedAfterHint,
                  control: Switch(
                    value: _seed,
                    onChanged: (value) => setState(() => _seed = value),
                  ),
                ),
                _Group(s.settingsSpeed),
                _Setting(
                  title: s.downloadLimit,
                  hint: s.limitsHint,
                  control: _limit(_down),
                ),
                _Setting(
                  title: s.uploadLimit,
                  hint: s.limitsHint,
                  control: _limit(_up),
                ),
                _Group(s.settingsAppearance),
                _Setting(
                  title: s.language,
                  control: SegmentedButton<AppLanguage>(
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
                _Setting(
                  title: s.themeMode,
                  control: SegmentedButton<AppThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: AppThemeMode.system,
                        label: Text(s.themeSystem),
                      ),
                      ButtonSegment(
                        value: AppThemeMode.light,
                        label: Text(s.themeLight),
                      ),
                      ButtonSegment(
                        value: AppThemeMode.dark,
                        label: Text(s.themeDark),
                      ),
                    ],
                    selected: {_themeMode},
                    onSelectionChanged: (choice) =>
                        setState(() => _themeMode = choice.single),
                  ),
                ),
                _Setting(
                  title: s.accentLabel,
                  wide: true,
                  // All of them on one line.
                  control: ThemePalette(
                    selected: _accent,
                    size: 24,
                    spacing: 6,
                    onChanged: (accent) => setState(() => _accent = accent),
                  ),
                ),
                _Group(s.settingsInterface),
                _Setting(
                  title: s.closeToTray,
                  hint: s.closeToTrayHint,
                  control: Switch(
                    value: _tray,
                    onChanged: (value) => setState(() => _tray = value),
                  ),
                ),
                _Setting(
                  title: s.checkUpdates,
                  hint: s.checkUpdatesHint,
                  control: Switch(
                    value: _updates,
                    onChanged: (value) => setState(() => _updates = value),
                  ),
                ),
                _UpdateCheck(controller: widget.controller),
                _Group(s.settingsNetwork),
                _Setting(
                  title: s.proxyType,
                  hint: switch (_proxyKind) {
                    ProxyKind.none => null,
                    ProxyKind.socks5 => s.proxySocksHint,
                  },
                  control: SegmentedButton<ProxyKind>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: ProxyKind.none,
                        label: Text(s.proxyNone),
                      ),
                      const ButtonSegment(
                        value: ProxyKind.socks5,
                        label: Text('SOCKS5'),
                      ),
                    ],
                    selected: {_proxyKind},
                    onSelectionChanged: (choice) =>
                        _setProxyKind(choice.single),
                  ),
                ),
                // The fields of the proxy only while one is chosen.
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.topCenter,
                  child: proxyOn
                      ? _proxyFields(s, theme, scheme)
                      : const SizedBox(width: double.infinity),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24, bottom: 4),
                  child: Text(
                    'NoodleT $appVersion',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        // A proxy without a server cannot be saved.
        FilledButton(
          onPressed: _proxy.isValid ? _save : null,
          child: Text(s.save),
        ),
      ],
    );
  }

  /// Opens or closes the proxy fields; opened, they are scrolled into view.
  void _setProxyKind(ProxyKind kind) {
    final opening = _proxyKind == ProxyKind.none && kind != ProxyKind.none;
    setState(() {
      _proxyKind = kind;
      _check = null;
    });
    if (!opening) return;
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _proxyFields(AppLocalizations s, ThemeData theme, ColorScheme scheme) {
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget field(
      TextEditingController controller, {
      String? hint,
      bool digits = false,
      bool secret = false,
    }) => TextField(
      controller: controller,
      obscureText: secret && !_showPassword,
      keyboardType: digits ? TextInputType.number : null,
      inputFormatters: digits
          ? [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ]
          : null,
      decoration: InputDecoration(
        hintText: hint,
        suffixIcon: secret
            ? IconButton(
                tooltip: s.proxyShowPassword,
                iconSize: 18,
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    );

    final check = _check;
    final works = check?.result == ProxyCheckResult.works;
    final status = !_proxy.isValid
        ? Text(s.proxyIncomplete, style: muted?.copyWith(color: scheme.error))
        : _checking
        ? Row(
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(s.proxyChecking, style: muted),
            ],
          )
        : check == null
        ? const SizedBox.shrink()
        : Row(
            children: [
              Icon(
                works ? Icons.check_circle_rounded : Icons.error_rounded,
                size: 16,
                color: works ? scheme.primary : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  switch (check.result) {
                    ProxyCheckResult.works => s.proxyWorks,
                    ProxyCheckResult.authFailed => s.proxyAuthFailed,
                    ProxyCheckResult.failed => s.proxyFailed(check.detail),
                  },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted?.copyWith(
                    color: works ? scheme.primary : scheme.error,
                  ),
                ),
              ),
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Setting(
          title: s.proxyServer,
          wide: true,
          control: Row(
            children: [
              Expanded(child: field(_proxyHost, hint: 'proxy.example.com')),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: field(_proxyPort, hint: s.proxyPortHint, digits: true),
              ),
            ],
          ),
        ),
        _Setting(
          title: s.proxyUsername,
          control: SizedBox(
            width: 260,
            child: field(_proxyUser, hint: s.proxyOptional),
          ),
        ),
        _Setting(
          title: s.proxyPassword,
          control: SizedBox(
            width: 260,
            child: field(_proxyPassword, hint: s.proxyOptional, secret: true),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _proxy.isValid && !_checking ? _checkProxy : null,
                child: Text(s.proxyCheck),
              ),
              const SizedBox(width: 12),
              Expanded(child: status),
            ],
          ),
        ),
      ],
    );
  }

  /// A speed limit in KB/s, the unit after the field.
  Widget _limit(TextEditingController field) {
    final s = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
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
            decoration: InputDecoration(hintText: s.limitHint),
          ),
        ),
        const SizedBox(width: 8),
        Text(s.kbPerSecond),
      ],
    );
  }
}

/// A button that looks for a newer release now, and what it found.
class _UpdateCheck extends StatefulWidget {
  const _UpdateCheck({required this.controller});

  final AppController controller;

  @override
  State<_UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<_UpdateCheck> {
  bool _checking = false;

  /// Null before a check here; a release found at startup shows anyway.
  UpdateCheck? _result;

  Future<void> _check() async {
    setState(() => _checking = true);
    final result = await widget.controller.checkUpdates();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final found = widget.controller.availableUpdate.value;
    final result =
        _result ??
        (found == null
            ? null
            : (status: UpdateStatus.available, version: found));

    Widget line(IconData icon, Color color, String text) => Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text, style: muted?.copyWith(color: color)),
        ),
      ],
    );

    final status = _checking
        ? Row(
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(s.updateChecking, style: muted),
            ],
          )
        : switch (result?.status) {
            null => const SizedBox.shrink(),
            UpdateStatus.upToDate => line(
              Icons.check_circle_rounded,
              scheme.primary,
              s.updateUpToDate,
            ),
            UpdateStatus.failed => line(
              Icons.error_rounded,
              scheme.error,
              s.updateFailed,
            ),
            UpdateStatus.available => Row(
              children: [
                Flexible(
                  child: line(
                    Icons.new_releases_rounded,
                    scheme.primary,
                    s.updateFound(result!.version),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => openUrl(Updates.releasePage),
                  child: Text(s.updateDownload),
                ),
              ],
            ),
          };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          OutlinedButton(
            onPressed: _checking ? null : _check,
            child: Text(s.updateCheckNow),
          ),
          const SizedBox(width: 12),
          Expanded(child: status),
        ],
      ),
    );
  }
}

/// The heading of a few settings that belong together.
class _Group extends StatelessWidget {
  const _Group(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One setting on a line: what it is on the left, its control on the right,
/// or under the name when [wide].
class _Setting extends StatelessWidget {
  const _Setting({
    required this.title,
    required this.control,
    this.hint,
    this.wide = false,
  });

  final String title;
  final String? hint;
  final bool wide;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyLarge),
        if (hint case final hint?) ...[
          const SizedBox(height: 2),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: wide
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 8), control],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 24),
                control,
              ],
            ),
    );
  }
}
