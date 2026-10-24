import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'engine/engine.dart';
import 'input.dart';
import 'notice.dart';
import 'settings.dart';
import 'updates.dart';

/// Owns the engine and the settings; the interface listens to it.
class AppController extends ChangeNotifier {
  AppController({required this.engine, required this.store});

  final TorrentEngine engine;
  final SettingsStore store;

  late AppSettings settings;

  /// In the order of [AppSettings.sort].
  List<Torrent> torrents = const [];

  /// The language of the interface; the application rebuilds when it changes.
  final language = ValueNotifier(AppLanguage.system);

  /// Light or dark and the colour of the theme; the application rebuilds
  /// when they change.
  final appearance = ValueNotifier((AppThemeMode.system, AppAccent.noodlet));

  /// Things to tell the user, shown as snack bars.
  Stream<Notice> get notices => _notices.stream;
  final _notices = StreamController<Notice>.broadcast();

  /// Torrents of several files that wait paused for the user to pick the
  /// files; answered with [chooseFiles] or [cancelAdd].
  Stream<FileChoice> get fileChoices => _fileChoices.stream;
  final _fileChoices = StreamController<FileChoice>.broadcast();

  Timer? _timer;
  bool _running = false;
  final _downloading = <String>{};

  int get downloadRate => torrents.fold(0, (sum, t) => sum + t.downloadRate);
  int get uploadRate => torrents.fold(0, (sum, t) => sum + t.uploadRate);

  /// Throws [EngineException] when the engine cannot be started.
  Future<void> start() async {
    settings = await store.load();
    language.value = settings.language;
    appearance.value = (settings.themeMode, settings.accent);
    engine.start(
      stateDir: store.dataDir,
      listenPort: settings.listenPort,
      downloadLimit: settings.downloadLimitKb * 1024,
      uploadLimit: settings.uploadLimitKb * 1024,
    );
    _running = true;
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
    if (settings.checkUpdates) unawaited(_checkUpdates());
  }

  Future<void> _checkUpdates() async {
    final version = await Updates.newerVersion();
    if (version != null && _running) {
      _notices.add(Notice(NoticeKind.update, version));
    }
  }

  void refresh() {
    if (!_running) return;
    final List<Torrent> next;
    try {
      next = engine.poll();
    } on EngineException {
      return;
    }
    for (final id in engine.takeFileChoices()) {
      final files = this.files(id);
      if (files.length > 1) {
        final torrent = next.where((t) => t.id == id).firstOrNull;
        _fileChoices.add(
          FileChoice(
            id: id,
            name: torrent?.name ?? id,
            files: files,
            savePath: torrent?.savePath ?? settings.downloadDir,
          ),
        );
      }
    }
    sortTorrents(next, settings.sort);
    for (final torrent in next) {
      if (torrent.state == TorrentState.downloading) {
        _downloading.add(torrent.id);
      } else if (torrent.state == TorrentState.seeding &&
          _downloading.remove(torrent.id)) {
        _notices.add(Notice(NoticeKind.finished, torrent.name));
      }
    }
    // Seeding is switched off: stop every torrent that has nothing left to
    // download. The list shows it as finished either way.
    if (!settings.seedAfterDownload) {
      for (final torrent in next) {
        if (torrent.state == TorrentState.seeding) {
          try {
            engine.pause(torrent.id);
          } on EngineException {
            // Gone in the meantime.
          }
        }
      }
    }
    torrents = next;
    notifyListeners();
  }

  /// Puts [torrents] in the order [sort]; the time added and then the id
  /// settle ties, so the order stays put between refreshes.
  static void sortTorrents(List<Torrent> torrents, TorrentSort sort) {
    int newest(Torrent a, Torrent b) {
      final byTime = b.added.compareTo(a.added);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    }

    int by(Torrent a, Torrent b) => switch (sort) {
      TorrentSort.added => 0,
      TorrentSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      TorrentSort.progress => a.progress.compareTo(b.progress),
      TorrentSort.size => b.size.compareTo(a.size),
      TorrentSort.speed => (b.downloadRate + b.uploadRate).compareTo(
        a.downloadRate + a.uploadRate,
      ),
    };

    torrents.sort((a, b) {
      final order = by(a, b);
      return order != 0 ? order : newest(a, b);
    });
  }

  /// Adds a magnet link, an info-hash or a path to a .torrent file.
  void addText(String text) {
    final input = TorrentInput.parse(text);
    if (input == null) {
      _notices.add(const Notice(NoticeKind.notRecognised));
      return;
    }
    add(input);
  }

  /// A torrent of several files waits paused on [fileChoices] for the user
  /// to pick them: a .torrent file right away, a magnet link once its
  /// metadata arrives.
  void add(TorrentInput input) {
    try {
      Directory(settings.downloadDir).createSync(recursive: true);
      switch (input) {
        case MagnetInput(:final uri):
          engine.addMagnet(uri, settings.downloadDir);
        case FileInput(:final path):
          engine.addFile(path, settings.downloadDir, chooseFiles: true);
      }
      refresh();
    } on DuplicateException catch (e) {
      _notices.add(
        e.newTrackers > 0
            ? Notice(NoticeKind.trackersAdded, '${e.newTrackers}')
            : const Notice(NoticeKind.duplicate),
      );
    } on EngineException catch (e) {
      _notices.add(switch (e.code) {
        'bad_magnet' => const Notice(NoticeKind.badMagnet),
        'bad_torrent' => const Notice(NoticeKind.badTorrent),
        'unreadable' => const Notice(NoticeKind.unreadable),
        _ => Notice(NoticeKind.addFailed, e.message),
      });
    } on FileSystemException catch (e) {
      _notices.add(
        Notice(NoticeKind.addFailed, e.osError?.message ?? e.message),
      );
    }
  }

  void toggle(Torrent torrent) {
    _guard(
      () => torrent.isPaused || torrent.state == TorrentState.error
          ? engine.resume(torrent.id)
          : engine.pause(torrent.id),
    );
  }

  /// Whether some torrent runs that [pauseAll] would stop.
  bool get canPauseAll => torrents.any((t) => !t.isPaused);

  /// Whether some torrent stands that [resumeAll] would start.
  bool get canResumeAll => torrents.any(_resumable);

  void pauseAll() {
    for (final torrent in torrents) {
      if (!torrent.isPaused) _quietly(() => engine.pause(torrent.id));
    }
    refresh();
  }

  /// Starts every paused torrent, except the finished ones while seeding is
  /// switched off: they would only stop again.
  void resumeAll() {
    for (final torrent in torrents) {
      if (_resumable(torrent)) _quietly(() => engine.resume(torrent.id));
    }
    refresh();
  }

  bool _resumable(Torrent t) =>
      (t.isPaused || t.state == TorrentState.error) &&
      (settings.seedAfterDownload || !t.isComplete);

  void remove(Torrent torrent, {required bool deleteFiles}) {
    _downloading.remove(torrent.id);
    _guard(() => engine.remove(torrent.id, deleteFiles: deleteFiles));
  }

  Future<void> updateSettings(AppSettings next) async {
    final portChanged = next.listenPort != settings.listenPort;
    final sortChanged = next.sort != settings.sort;
    settings = next;
    language.value = next.language;
    appearance.value = (next.themeMode, next.accent);
    _guard(() {
      engine.setRateLimits(
        next.downloadLimitKb * 1024,
        next.uploadLimitKb * 1024,
      );
      if (portChanged) engine.setListenPort(next.listenPort);
    });
    if (sortChanged) {
      torrents = List.of(torrents);
      sortTorrents(torrents, next.sort);
    }
    await store.save(next);
    notifyListeners();
  }

  /// Starts the torrent [id] that waited on [fileChoices], with only the
  /// files [wanted], downloading into [savePath].
  void chooseFiles(String id, Set<int> wanted, {String? savePath}) {
    _guard(() {
      if (savePath != null) Directory(savePath).createSync(recursive: true);
      engine.chooseFiles(id, wanted, savePath: savePath);
    });
  }

  /// Drops the torrent [id] that waited on [fileChoices]: the user changed
  /// their mind about adding it. Nothing of it was downloaded, and files
  /// of the same name that were there before must stay.
  void cancelAdd(String id) {
    _guard(() => engine.remove(id, deleteFiles: false));
  }

  /// The files of [torrent]; empty until a magnet link has its metadata.
  List<TorrentFile> files(String id) {
    try {
      return engine.files(id);
    } on EngineException {
      return const [];
    }
  }

  /// Skips the files [indexes] of [torrent], or takes them back. A file
  /// taken back into a finished, stopped torrent starts it again: there is
  /// something to download now.
  void setFilesWanted(
    Torrent torrent,
    Iterable<int> indexes, {
    required bool wanted,
  }) {
    _guard(() {
      engine.setFilesWanted(torrent.id, indexes, wanted: wanted);
      if (wanted && torrent.isPaused && torrent.isComplete) {
        final added = files(torrent.id)
            .where((f) => indexes.contains(f.index) && f.done < f.size);
        if (added.isNotEmpty) engine.resume(torrent.id);
      }
    });
  }

  void setSequential(Torrent torrent, {required bool sequential}) =>
      _guard(() => engine.setSequential(torrent.id, sequential: sequential));

  /// Moves the files of [torrent] to [folder].
  void move(Torrent torrent, String folder) =>
      _guard(() => engine.move(torrent.id, folder));

  /// The file or folder of [torrent] on disk.
  ({String path, bool isFile}) contentPath(Torrent torrent) {
    try {
      return engine.contentPath(torrent.id);
    } on EngineException {
      return (path: torrent.savePath, isFile: false);
    }
  }

  List<String> trackers(Torrent torrent) {
    try {
      return engine.trackers(torrent.id);
    } on EngineException {
      return const [];
    }
  }

  /// Adds the trackers in [text], one per line; returns how many were new.
  int addTrackers(Torrent torrent, String text) {
    var added = 0;
    _guard(() => added = engine.addTrackers(torrent.id, text.split('\n')));
    return added;
  }

  List<Peer> peers(Torrent torrent) {
    try {
      return engine.peers(torrent.id);
    } on EngineException {
      return const [];
    }
  }

  /// Saves the state of every torrent. Blocks for a few seconds at most.
  void shutdown() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    try {
      engine.shutdown();
    } on EngineException {
      // Nothing left to do: the application is closing.
    }
  }

  void _quietly(void Function() action) {
    try {
      action();
    } on EngineException {
      // Gone in the meantime.
    }
  }

  void _guard(void Function() action) {
    try {
      action();
    } on EngineException catch (e) {
      // The torrent can disappear between two refreshes; that is not an error.
      if (e.code != 'not_found') {
        _notices.add(Notice(NoticeKind.engine, e.message));
      }
    } on FileSystemException catch (e) {
      _notices.add(Notice(NoticeKind.engine, e.osError?.message ?? e.message));
    }
    refresh();
  }

  @override
  void dispose() {
    shutdown();
    _notices.close();
    _fileChoices.close();
    language.dispose();
    super.dispose();
  }
}

/// A torrent that was just added paused and waits for the user to pick which
/// of its [files] to download.
class FileChoice {
  const FileChoice({
    required this.id,
    required this.name,
    required this.files,
    required this.savePath,
  });

  final String id;
  final String name;
  final List<TorrentFile> files;

  /// The folder it was added with, which the user may change.
  final String savePath;
}
