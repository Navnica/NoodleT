import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import '../input.dart';
import '../notice.dart';
import '../tray.dart';
import 'details_sheet.dart';
import 'dialogs.dart';
import 'format.dart';
import '../l10n/app_localizations.dart';
import 'torrent_row.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.initialInputs = const [],
  });

  final AppController controller;

  /// Magnet links and .torrent paths from the command line.
  final List<String> initialInputs;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Magnet links and .torrent paths of later launches, which the Windows
  /// runner hands over to this window instead of opening a second one.
  static const _instance = MethodChannel('noodlet/instance');

  late final StreamSubscription<Notice> _notices;
  late final AppLifecycleListener _lifecycle;
  final _tray = Tray();
  final _input = TextEditingController();
  bool _dragging = false;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _notices = _controller.notices.listen(_showNotice);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        _controller.shutdown();
        return AppExitResponse.exit;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final input in widget.initialInputs) {
        _controller.addText(input);
      }
    });
    _instance.setMethodCallHandler((call) async {
      if (call.method != 'open') return;
      for (final input in (call.arguments as List).cast<String>()) {
        _controller.addText(input);
      }
    });
    _controller.addListener(_syncTray);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The interface language may have changed.
    _syncTray();
  }

  @override
  void dispose() {
    _controller.removeListener(_syncTray);
    _instance.setMethodCallHandler(null);
    _notices.cancel();
    _lifecycle.dispose();
    _input.dispose();
    super.dispose();
  }

  void _showNotice(Notice notice) {
    if (!mounted) return;
    final s = AppLocalizations.of(context);
    final text = switch (notice.kind) {
      NoticeKind.finished => s.finished(notice.detail),
      NoticeKind.duplicate => s.duplicate,
      NoticeKind.badMagnet => s.badMagnet,
      NoticeKind.badTorrent => s.badTorrent,
      NoticeKind.unreadable => s.unreadable,
      NoticeKind.notRecognised => s.notRecognised,
      NoticeKind.addFailed => s.addFailed(notice.detail),
      NoticeKind.engine => notice.detail,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          // Above the dock, not over it.
          margin: const EdgeInsets.fromLTRB(16, 0, 16, _Dock.reserved - 12),
        ),
      );
  }

  /// Keeps the tray icon in line with the settings, the language and the
  /// current speeds, which its tooltip shows.
  void _syncTray() {
    if (!mounted) return;
    final s = AppLocalizations.of(context);
    _tray.update(
      enabled: _controller.settings.closeToTray,
      open: s.trayOpen,
      exit: s.trayExit,
      hiddenTitle: s.trayHiddenTitle,
      hiddenText: s.trayHiddenText,
      tooltip:
          'NoodleT\n'
          '↓ ${formatRate(_controller.downloadRate, s)}   '
          '↑ ${formatRate(_controller.uploadRate, s)}',
    );
  }

  void _add(String text) {
    if (text.trim().isEmpty) return;
    _controller.addText(text);
    _input.clear();
  }

  Future<void> _openFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Torrent', extensions: ['torrent']),
      ],
    );
    for (final file in files) {
      _controller.add(FileInput(file.path));
    }
  }

  /// Ctrl+V anywhere outside the input field.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    _add(data?.text ?? '');
  }

  Future<void> _remove(Torrent torrent) async {
    final deleteFiles = await showRemoveDialog(context, torrent.name);
    if (deleteFiles != null) {
      _controller.remove(torrent, deleteFiles: deleteFiles);
    }
  }

  void _openFolder(Torrent torrent) {
    final command = Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    Process.run(command, [torrent.savePath]).ignore();
  }

  void _openSettings() => showSettingsDialog(context, _controller);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          for (final file in details.files) {
            _controller.addText(file.path);
          }
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _paste,
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
          },
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) => _layout(),
                ),
                Positioned.fill(child: _DropOverlay(visible: _dragging)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _layout() {
    final torrents = _controller.torrents;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Stack(
          children: [
            Positioned.fill(
              child: torrents.isEmpty ? const _EmptyState() : _list(torrents),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _Dock(
                input: _input,
                downloadRate: _controller.downloadRate,
                uploadRate: _controller.uploadRate,
                onSubmit: _add,
                onPaste: _paste,
                onOpenFiles: _openFiles,
                onSettings: _openSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetails(Torrent torrent) => showDetailsSheet(
    context,
    controller: _controller,
    id: torrent.id,
    onOpenFolder: _openFolder,
    onRemove: _remove,
  );

  /// The cards scroll under the floating dock.
  Widget _list(List<Torrent> torrents) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, _Dock.reserved),
    itemCount: torrents.length,
    separatorBuilder: (_, _) => const SizedBox(height: 8),
    itemBuilder: (context, index) {
      final torrent = torrents[index];
      return TorrentRow(
        key: ValueKey(torrent.id),
        torrent: torrent,
        onTap: () => _openDetails(torrent),
        onToggle: () => _controller.toggle(torrent),
        onOpenFolder: () => _openFolder(torrent),
        onRemove: () => _remove(torrent),
      );
    },
  );
}

/// The floating bar at the bottom with every control of the application:
/// the .torrent button, the field for magnet links, the total speed, the
/// settings and the add button.
class _Dock extends StatelessWidget {
  const _Dock({
    required this.input,
    required this.downloadRate,
    required this.uploadRate,
    required this.onSubmit,
    required this.onPaste,
    required this.onOpenFiles,
    required this.onSettings,
  });

  final TextEditingController input;
  final int downloadRate;
  final int uploadRate;
  final ValueChanged<String> onSubmit;
  final VoidCallback onPaste;
  final VoidCallback onOpenFiles;
  final VoidCallback onSettings;

  /// The space the content above has to leave free for the dock.
  static const reserved = 78.0;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Material(
          color: scheme.surfaceContainer,
          elevation: 16,
          shadowColor: Colors.black,
          shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    tooltip: s.openFile,
                    onPressed: onOpenFiles,
                    icon: const Icon(Icons.attach_file_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      controller: input,
                      onSubmitted: onSubmit,
                      style: theme.textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: s.inputHint,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  if (constraints.maxWidth >= 340) ...[
                    const SizedBox(width: 6),
                    _Speed(downloadRate: downloadRate, uploadRate: uploadRate),
                    const SizedBox(width: 2),
                  ],
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    tooltip: s.settings,
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_rounded),
                  ),
                  const SizedBox(width: 2),
                  // With nothing typed the button takes the link from the
                  // clipboard instead.
                  ValueListenableBuilder(
                    valueListenable: input,
                    builder: (context, value, _) {
                      final empty = value.text.trim().isEmpty;
                      return IconButton.filled(
                        visualDensity: VisualDensity.compact,
                        tooltip: s.add,
                        onPressed: empty ? onPaste : () => onSubmit(value.text),
                        icon: Icon(
                          empty
                              ? Icons.content_paste_rounded
                              : Icons.arrow_upward_rounded,
                          size: 18,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The total download and upload speed, one above the other.
class _Speed extends StatelessWidget {
  const _Speed({required this.downloadRate, required this.uploadRate});

  final int downloadRate;
  final int uploadRate;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.25,
    );
    return Container(
      constraints: const BoxConstraints(minWidth: 88),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '↓ ${formatRate(downloadRate, s)}',
            style: style?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '↑ ${formatRate(uploadRate, s)}',
            style: style?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, _Dock.reserved),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                Icons.south_rounded,
                size: 30,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              s.emptyTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          color: scheme.surface.withValues(alpha: 0.92),
          padding: const EdgeInsets.all(20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              border: Border.all(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.file_download_outlined,
                    size: 40,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppLocalizations.of(context).dropHere,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
