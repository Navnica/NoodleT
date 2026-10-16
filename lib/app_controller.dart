import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'engine/engine.dart';
import 'input.dart';
import 'notice.dart';
import 'settings.dart';

/// Owns the engine and the settings; the interface listens to it.
class AppController extends ChangeNotifier {
  AppController({required this.engine, required this.store});

  final TorrentEngine engine;
  final SettingsStore store;

  late AppSettings settings;
  List<Torrent> torrents = const [];

  /// The language of the interface; the application rebuilds when it changes.
  final language = ValueNotifier(AppLanguage.system);

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
    engine.start(
      stateDir: store.dataDir,
      listenPort: settings.listenPort,
      downloadLimit: settings.downloadLimitKb * 1024,
      uploadLimit: settings.uploadLimitKb * 1024,
    );
    _running = true;
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
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
      final name = next.where((t) => t.id == id).firstOrNull?.name;
      final files = this.files(id);
      if (files.length > 1) {
        _fileChoices.add(FileChoice(id: id, name: name ?? id, files: files));
      }
    }
    // Newest first; the id keeps the order stable within one second.
    next.sort((a, b) {
      final byTime = b.added.compareTo(a.added);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
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
          final id = engine.addFile(path, settings.downloadDir, paused: true);
          if (engine.files(id).length > 1) {
            _askFiles(id);
          } else {
            engine.resume(id);
          }
      }
      refresh();
    } on EngineException catch (e) {
      _notices.add(switch (e.code) {
        'duplicate' => const Notice(NoticeKind.duplicate),
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

  void remove(Torrent torrent, {required bool deleteFiles}) {
    _downloading.remove(torrent.id);
    _guard(() => engine.remove(torrent.id, deleteFiles: deleteFiles));
  }

  Future<void> updateSettings(AppSettings next) async {
    settings = next;
    language.value = next.language;
    _guard(
      () => engine.setRateLimits(
        next.downloadLimitKb * 1024,
        next.uploadLimitKb * 1024,
      ),
    );
    await store.save(next);
    notifyListeners();
  }

  /// Starts the torrent [id] that waited on [fileChoices], with only the
  /// files [wanted].
  void chooseFiles(String id, Set<int> wanted) {
    _guard(() {
      final skipped = [
        for (final file in engine.files(id))
          if (!wanted.contains(file.index)) file.index,
      ];
      if (skipped.isNotEmpty) {
        engine.setFilesWanted(id, skipped, wanted: false);
      }
      engine.resume(id);
    });
    refresh();
  }

  /// Drops the torrent [id] that waited on [fileChoices]: the user changed
  /// their mind about adding it.
  void cancelAdd(String id) {
    _guard(() => engine.remove(id, deleteFiles: true));
    refresh();
  }

  void _askFiles(String id) {
    final name = engine.poll().where((t) => t.id == id).firstOrNull?.name;
    _fileChoices.add(FileChoice(id: id, name: name ?? id, files: files(id)));
  }

  /// The files of [torrent]; empty until a magnet link has its metadata.
  List<TorrentFile> files(String id) {
    try {
      return engine.files(id);
    } on EngineException {
      return const [];
    }
  }

  /// Skips the files [indexes] of [torrent], or takes them back.
  void setFilesWanted(
    Torrent torrent,
    Iterable<int> indexes, {
    required bool wanted,
  }) {
    _guard(() => engine.setFilesWanted(torrent.id, indexes, wanted: wanted));
    refresh();
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

  void _guard(void Function() action) {
    try {
      action();
    } on EngineException catch (e) {
      // The torrent can disappear between two refreshes; that is not an error.
      if (e.code != 'not_found') {
        _notices.add(Notice(NoticeKind.engine, e.message));
      }
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
  const FileChoice({required this.id, required this.name, required this.files});

  final String id;
  final String name;
  final List<TorrentFile> files;
}
