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

  void add(TorrentInput input) {
    try {
      Directory(settings.downloadDir).createSync(recursive: true);
      switch (input) {
        case MagnetInput(:final uri):
          engine.addMagnet(uri, settings.downloadDir);
        case FileInput(:final path):
          engine.addFile(path, settings.downloadDir);
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

  /// The files of [torrent]; empty until a magnet link has its metadata.
  List<TorrentFile> files(Torrent torrent) {
    try {
      return engine.files(torrent.id);
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
    language.dispose();
    super.dispose();
  }
}
