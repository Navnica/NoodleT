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
import 'details_panel.dart';
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

  /// The torrent whose details are open next to the list.
  String? _selected;

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

  /// Whether a text field has the keys, so that they are left to it.
  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Esc closes the details, Delete removes the torrent they show and Space
  /// pauses or resumes it.
  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || _typing) return KeyEventResult.ignored;
    final torrent = _controller.torrents
        .where((t) => t.id == _selected)
        .firstOrNull;
    if (torrent == null) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        setState(() => _selected = null);
      case LogicalKeyboardKey.delete:
        _remove(torrent);
      case LogicalKeyboardKey.space:
        _controller.toggle(torrent);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _contextMenu(Torrent torrent, Offset position) async {
    setState(() => _selected = torrent.id);
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final resumable = torrent.isPaused || torrent.state == TorrentState.error;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () => _controller.toggle(torrent),
          child: _MenuRow(
            resumable ? Icons.play_arrow_rounded : Icons.pause_rounded,
            resumable ? s.resume : s.pause,
          ),
        ),
        PopupMenuItem(
          value: () => _openFolder(torrent),
          child: _MenuRow(Icons.folder_open_rounded, s.openFolder),
        ),
        PopupMenuItem(
          value: () => _remove(torrent),
          child: _MenuRow(
            Icons.delete_outline_rounded,
            s.remove,
            color: scheme.error,
          ),
        ),
      ],
    );
    action?.call();
  }

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
            onKeyEvent: (_, event) => _onKey(event),
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
    final selected = _selected;
    return Column(
      children: [
        _TopBar(
          input: _input,
          downloadRate: _controller.downloadRate,
          uploadRate: _controller.uploadRate,
          onSubmit: _add,
          onPaste: _paste,
          onOpenFiles: _openFiles,
          onSettings: _openSettings,
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
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
              if (selected != null) ...[
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 420,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: DetailsPanel(
                      key: ValueKey(selected),
                      controller: _controller,
                      id: selected,
                      onOpenFolder: _openFolder,
                      onRemove: _remove,
                      onClose: () {
                        if (mounted) setState(() => _selected = null);
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// A click on the open torrent closes its details.
  void _openDetails(Torrent torrent) =>
      setState(() => _selected = _selected == torrent.id ? null : torrent.id);

  Widget _list(List<Torrent> torrents) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
    itemCount: torrents.length,
    separatorBuilder: (_, _) => const SizedBox(height: 6),
    itemBuilder: (context, index) {
      final torrent = torrents[index];
      return TorrentRow(
        key: ValueKey(torrent.id),
        torrent: torrent,
        selected: torrent.id == _selected,
        onTap: () => _openDetails(torrent),
        onContextMenu: (position) => _contextMenu(torrent, position),
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
    return Center(
      child: Text(
        AppLocalizations.of(context).nothingFound,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The bar along the top of the window: the .torrent button, the field for
/// magnet links, the add button, the total speed and the settings.
class _TopBar extends StatelessWidget {
  const _TopBar({
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

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        // The page's own colour, so that the field stands out as the
        // search field below does.
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: s.openFile,
            onPressed: onOpenFiles,
            iconSize: 20,
            icon: const Icon(Icons.attach_file_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            // As tall as the add button next to it: the padding gives the
            // height, so that the row centres the field with the buttons.
            child: TextField(
              controller: input,
              onSubmitted: onSubmit,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              decoration: InputDecoration(
                hintText: s.inputHint,
                isDense: true,
                prefixIcon: const Icon(Icons.link_rounded, size: 18),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // With nothing typed the button takes the link from the
          // clipboard instead.
          ValueListenableBuilder(
            valueListenable: input,
            builder: (context, value, _) {
              final empty = value.text.trim().isEmpty;
              return IconButton.filled(
                tooltip: empty ? '${s.add} (Ctrl+V)' : s.add,
                onPressed: empty ? onPaste : () => onSubmit(value.text),
                style: IconButton.styleFrom(
                  fixedSize: const Size(36, 36),
                  minimumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: Icon(
                  empty ? Icons.content_paste_rounded : Icons.add_rounded,
                  size: 18,
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          _Speed(downloadRate: downloadRate, uploadRate: uploadRate),
          const SizedBox(width: 2),
          IconButton(
            tooltip: s.settings,
            onPressed: onSettings,
            iconSize: 20,
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
    );
  }
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
      fontSize: 10.5,
      height: 1.2,
    );
    return Container(
      constraints: const BoxConstraints(minWidth: 80, minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
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
        padding: const EdgeInsets.all(32),
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
