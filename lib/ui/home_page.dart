import 'dart:async';
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../engine/engine.dart';
import '../input.dart';
import '../notice.dart';
import '../settings.dart';
import '../tray.dart';
import '../updates.dart';
import 'details_sheet.dart';
import 'dialogs.dart';
import 'format.dart';
import 'system.dart';
import '../l10n/app_localizations.dart';
import 'torrent_row.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.initialInputs = const [],
    this.tray,
  });

  final AppController controller;

  /// Magnet links and .torrent paths from the command line.
  final List<String> initialInputs;

  /// The notification area icon; null where there is none, e.g. in tests.
  final Tray? tray;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Magnet links and .torrent paths of later launches, which the Windows
  /// runner hands over to this window instead of opening a second one.
  static const _instance = MethodChannel('noodlet/instance');

  late final StreamSubscription<Notice> _notices;
  late final StreamSubscription<FileChoice> _fileChoices;
  // One file choice at a time, e.g. when several torrents are dropped at once.
  Future<void> _choosing = Future.value();
  late final AppLifecycleListener _lifecycle;
  final _input = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  _Filter _filter = _Filter.all;
  bool _dragging = false;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _notices = _controller.notices.listen(_showNotice);
    _fileChoices = _controller.fileChoices.listen((choice) {
      _choosing = _choosing.then((_) => _chooseFiles(choice));
    });
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
    _search.addListener(() => setState(() {}));
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
    _fileChoices.cancel();
    _lifecycle.dispose();
    _input.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _showNotice(Notice notice) {
    if (!mounted) return;
    final s = AppLocalizations.of(context);
    final text = switch (notice.kind) {
      NoticeKind.finished => s.finished(notice.detail),
      NoticeKind.duplicate => s.duplicate,
      NoticeKind.trackersAdded => s.trackersAdded(
        int.tryParse(notice.detail) ?? 0,
      ),
      NoticeKind.update => s.updateAvailable(notice.detail),
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
          action: notice.kind == NoticeKind.update
              ? SnackBarAction(
                  label: s.updateDownload,
                  onPressed: () => openUrl(Updates.releasePage),
                )
              : null,
          duration: notice.kind == NoticeKind.update
              ? const Duration(seconds: 15)
              : const Duration(seconds: 4),
        ),
      );
  }

  /// Asks which files of a torrent just added to download; it waits paused
  /// until then.
  Future<void> _chooseFiles(FileChoice choice) async {
    if (!mounted) return;
    // The metadata of a magnet link may arrive while the window is in the
    // tray.
    await widget.tray?.show();
    if (!mounted) return;
    final chosen = await showFileChoiceDialog(
      context,
      name: choice.name,
      files: choice.files,
      folder: choice.savePath,
    );
    if (chosen == null) {
      _controller.cancelAdd(choice.id);
    } else {
      _controller.chooseFiles(choice.id, chosen.files, savePath: chosen.folder);
    }
  }

  /// Keeps the tray icon in line with the settings, the language and the
  /// current speeds, which its tooltip shows.
  void _syncTray() {
    if (!mounted) return;
    final s = AppLocalizations.of(context);
    final active = [
      for (final torrent in _controller.torrents)
        if (torrent.state
            case TorrentState.downloading ||
                TorrentState.checking ||
                TorrentState.metadata)
          torrent,
    ];
    widget.tray?.update(
      enabled: _controller.settings.closeToTray,
      open: s.trayOpen,
      exit: s.trayExit,
      pauseAll: s.pauseAll,
      resumeAll: s.resumeAll,
      downloads: [
        for (final torrent in active.take(_trayRows))
          '${_shorten(torrent.name)} — ${_trayStatus(torrent, s)}',
        if (active.length > _trayRows) s.trayMore(active.length - _trayRows),
      ],
      tooltip:
          'NoodleT\n'
          '↓ ${formatRate(_controller.downloadRate, s)}   '
          '↑ ${formatRate(_controller.uploadRate, s)}',
    );
  }

  /// How many downloads the tray menu lists before "and N more".
  static const _trayRows = 5;

  /// Long names would stretch the tray menu across the screen.
  static String _shorten(String name) =>
      name.length <= 40 ? name : '${name.substring(0, 39)}…';

  static String _trayStatus(Torrent torrent, AppLocalizations s) =>
      switch (torrent.state) {
        TorrentState.metadata => s.metadata,
        TorrentState.checking =>
          '${s.checking} ${formatPercent(torrent.progress, s)}',
        _ =>
          '${formatPercent(torrent.progress, s)} · '
              '${formatRate(torrent.downloadRate, s)}',
      };

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

  /// Opens the torrent's own folder, or selects its file when it has one.
  void _openFolder(Torrent torrent) {
    final content = _controller.contentPath(torrent);
    reveal(content.path, isFile: content.isFile);
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
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _searchFocus.requestFocus,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                _searchFocus.requestFocus,
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

  /// The torrents that pass the search and the filter.
  List<Torrent> _shown(List<Torrent> torrents) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final t in torrents)
        if (_filter.accepts(t) &&
            (query.isEmpty || t.name.toLowerCase().contains(query)))
          t,
    ];
  }

  Widget _layout() {
    final torrents = _controller.torrents;
    final shown = _shown(torrents);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Stack(
          children: [
            Positioned.fill(
              child: torrents.isEmpty
                  ? const _EmptyState()
                  : Column(
                      children: [
                        _Toolbar(
                          search: _search,
                          searchFocus: _searchFocus,
                          filter: _filter,
                          sort: _controller.settings.sort,
                          canPauseAll: _controller.canPauseAll,
                          canResumeAll: _controller.canResumeAll,
                          onFilter: (filter) =>
                              setState(() => _filter = filter),
                          onSort: (sort) => _controller.updateSettings(
                            _controller.settings.copyWith(sort: sort),
                          ),
                          onPauseAll: _controller.pauseAll,
                          onResumeAll: _controller.resumeAll,
                        ),
                        Expanded(
                          child: shown.isEmpty
                              ? const _NothingFound()
                              : _list(shown),
                        ),
                      ],
                    ),
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
    padding: const EdgeInsets.fromLTRB(14, 4, 14, _Dock.reserved),
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

/// Which torrents the list shows.
enum _Filter {
  all,

  /// Running: downloading, checking or seeding.
  active,

  /// Everything wanted is downloaded.
  done,

  /// Stopped before it was done.
  paused;

  bool accepts(Torrent t) => switch (this) {
    all => true,
    active => !t.isPaused && t.state != TorrentState.error,
    done => t.isComplete,
    paused => t.isPaused && !t.isComplete,
  };

  String label(AppLocalizations s) => switch (this) {
    all => s.filterAll,
    active => s.filterActive,
    done => s.filterDone,
    paused => s.filterPaused,
  };
}

/// Search, filter, order and the buttons for all torrents at once, above
/// the list.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.searchFocus,
    required this.filter,
    required this.sort,
    required this.canPauseAll,
    required this.canResumeAll,
    required this.onFilter,
    required this.onSort,
    required this.onPauseAll,
    required this.onResumeAll,
  });

  final TextEditingController search;
  final FocusNode searchFocus;
  final _Filter filter;
  final TorrentSort sort;
  final bool canPauseAll;
  final bool canResumeAll;
  final ValueChanged<_Filter> onFilter;
  final ValueChanged<TorrentSort> onSort;
  final VoidCallback onPauseAll;
  final VoidCallback onResumeAll;

  static String _sortLabel(TorrentSort sort, AppLocalizations s) =>
      switch (sort) {
        TorrentSort.added => s.sortAdded,
        TorrentSort.name => s.sortName,
        TorrentSort.progress => s.sortProgress,
        TorrentSort.size => s.sortSize,
        TorrentSort.speed => s.sortSpeed,
      };

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: search,
                focusNode: searchFocus,
                style: theme.textTheme.bodyMedium,
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  hintText: s.search,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: s.cancel,
                          onPressed: search.clear,
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
                onTapOutside: (_) => searchFocus.unfocus(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<_Filter>(
            tooltip: filter.label(s),
            initialValue: filter,
            onSelected: onFilter,
            itemBuilder: (_) => [
              for (final f in _Filter.values)
                CheckedPopupMenuItem(
                  value: f,
                  checked: f == filter,
                  child: Text(f.label(s)),
                ),
            ],
            icon: Icon(
              Icons.filter_list_rounded,
              color: filter == _Filter.all ? null : scheme.primary,
            ),
          ),
          PopupMenuButton<TorrentSort>(
            tooltip: s.sortBy,
            initialValue: sort,
            onSelected: onSort,
            itemBuilder: (_) => [
              for (final option in TorrentSort.values)
                CheckedPopupMenuItem(
                  value: option,
                  checked: option == sort,
                  child: Text(_sortLabel(option, s)),
                ),
            ],
            icon: const Icon(Icons.sort_rounded),
          ),
          IconButton(
            tooltip: s.pauseAll,
            onPressed: canPauseAll ? onPauseAll : null,
            icon: const Icon(Icons.pause_circle_outline_rounded),
          ),
          IconButton(
            tooltip: s.resumeAll,
            onPressed: canResumeAll ? onResumeAll : null,
            icon: const Icon(Icons.play_circle_outline_rounded),
          ),
        ],
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: _Dock.reserved),
      child: Center(
        child: Text(
          AppLocalizations.of(context).nothingFound,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
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
