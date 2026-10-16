import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libtorrent_dart/libtorrent_dart.dart' as lt;
import 'package:path/path.dart' as p;

enum TorrentState { paused, checking, metadata, downloading, seeding, error }

class Torrent {
  const Torrent({
    required this.id,
    required this.name,
    required this.savePath,
    required this.state,
    required this.progress,
    required this.size,
    required this.done,
    required this.downloadRate,
    required this.uploadRate,
    required this.uploaded,
    required this.peers,
    required this.seeds,
    required this.added,
    required this.error,
  });

  final String id;
  final String name;
  final String savePath;
  final TorrentState state;

  /// 0..1
  final double progress;
  final int size;
  final int done;

  /// Bytes per second.
  final int downloadRate;
  final int uploadRate;

  /// Bytes sent to other peers over the whole life of the torrent.
  final int uploaded;
  final int peers;
  final int seeds;

  /// Unix time the torrent was added at.
  final int added;
  final String error;

  bool get isPaused => state == TorrentState.paused;
  bool get isComplete => size > 0 && done >= size;

  /// The state to present: a finished download that was stopped is still
  /// first of all finished, not paused.
  TorrentState get shownState =>
      isPaused && isComplete ? TorrentState.seeding : state;

  /// Time left at the current speed, null when it cannot be estimated.
  Duration? get eta {
    if (state != TorrentState.downloading || downloadRate <= 0) return null;
    return Duration(seconds: (size - done) ~/ downloadRate);
  }
}

/// One file inside a torrent.
class TorrentFile {
  const TorrentFile({
    required this.index,
    required this.path,
    required this.size,
    required this.done,
    required this.wanted,
  });

  /// The index libtorrent knows the file by.
  final int index;

  /// Relative to the save folder, with '/' between the parts; a torrent of
  /// several files puts them all under its own folder.
  final String path;
  final int size;
  final int done;

  /// False when the user chose to skip the file.
  final bool wanted;

  double get progress => size > 0 ? (done / size).clamp(0, 1).toDouble() : 1;
}

class EngineException implements Exception {
  const EngineException(this.code, this.message);

  /// Stable identifier, e.g. "duplicate" or "bad_magnet".
  final String code;
  final String message;

  @override
  String toString() => 'EngineException($code): $message';
}

/// The torrent engine: libtorrent-rasterbar, the library qBittorrent is built
/// on, through the libtorrent_dart package.
///
/// It keeps its own files in the state directory given to [start]:
///   torrents.json        the list of torrents
///   resume/`id`.resume   libtorrent resume data of each torrent
///   session.dat          session state, most importantly the DHT nodes
class TorrentEngine {
  lt.Session? _session;
  late String _stateDir;
  final _entries = <String, _Entry>{};
  final _fileChoices = <String>[];
  DateTime _lastAutosave = DateTime.now();

  static const _autosaveInterval = Duration(seconds: 30);

  /// How often a running torrent without connections asks the DHT for peers.
  static const _dhtRetryInterval = Duration(seconds: 15);

  File get _indexFile => File(p.join(_stateDir, 'torrents.json'));
  File get _sessionFile => File(p.join(_stateDir, 'session.dat'));
  File _resumeFile(String id) =>
      File(p.join(_stateDir, 'resume', '$id.resume'));

  /// Starts the session and restores the torrents of the previous run.
  /// Rate limits are in bytes per second, 0 means unlimited. Returns the
  /// libtorrent version.
  String start({
    required String stateDir,
    required int listenPort,
    required int downloadLimit,
    required int uploadLimit,
  }) => _wrap('start_failed', () {
    if (_session == null) {
      _stateDir = stateDir;
      Directory(p.join(stateDir, 'resume')).createSync(recursive: true);
      final session = _createSession();
      _applySettings(session, listenPort, downloadLimit, uploadLimit);
      _session = session;
      _restore(session);
    }
    return lt.getLibtorrentVersion();
  });

  /// Adds a magnet link and returns the id of the torrent. Once its metadata
  /// arrives and shows more than one file, the torrent is paused and its id
  /// comes out of [takeFileChoices], so that the user can pick the files.
  String addMagnet(String uri, String savePath) {
    final session = _running;
    final lt.MagnetUriInfo info;
    try {
      info = lt.parseMagnetUri(uri);
    } on lt.LibtorrentException catch (e) {
      throw EngineException('bad_magnet', e.message);
    }
    final id = info.infohashHex.toLowerCase();
    if (id.isEmpty) throw const EngineException('bad_magnet', 'no info-hash');
    _checkNew(id);
    _wrap('add_failed', () {
      final handle = session.addMagnet(magnetUri: uri, savePath: savePath);
      _adopt(id, handle, name: info.name, savePath: savePath, magnet: uri);
      _entries[id]!.askFiles = true;
    });
    return id;
  }

  /// Adds a .torrent file and returns the id of the torrent. A [paused] one
  /// downloads nothing until [resume], e.g. while the user picks its files.
  String addFile(String torrentPath, String savePath, {bool paused = false}) {
    final session = _running;
    final Uint8List data;
    try {
      data = File(torrentPath).readAsBytesSync();
    } on FileSystemException catch (e) {
      throw EngineException('unreadable', e.message);
    }
    final lt.TorrentFileInfo info;
    try {
      info = lt.loadTorrentFile(torrentPath);
    } on lt.LibtorrentException catch (e) {
      throw EngineException('bad_torrent', e.message);
    }
    final id = info.infohashHex.toLowerCase();
    _checkNew(id);
    _wrap('add_failed', () {
      final handle = session.addTorrentFromTags([
        lt.LibtorrentTagItem.bytesValue(lt.LibtorrentTag.torTorrent, data),
        lt.LibtorrentTagItem.intValue(
          lt.LibtorrentTag.torTorrentSize,
          data.length,
        ),
        lt.LibtorrentTagItem.stringValue(
          lt.LibtorrentTag.torSavePath,
          savePath,
        ),
        // Paused from the start, so that not a single byte comes first.
        if (paused)
          lt.LibtorrentTagItem.intValue(lt.LibtorrentTag.torPaused, 1),
      ]);
      _adopt(
        id,
        handle,
        name: info.name,
        savePath: savePath,
        magnet: '',
        paused: paused,
      );
    });
    return id;
  }

  /// Magnet links whose metadata has just shown several files; each is paused
  /// until the user picks the files. Empties the list.
  List<String> takeFileChoices() {
    final ids = List.of(_fileChoices);
    _fileChoices.clear();
    return ids;
  }

  /// The state of every torrent. Also writes resume data when it is due.
  List<Torrent> poll() {
    _running;
    final now = DateTime.now();
    final autosave = now.difference(_lastAutosave) >= _autosaveInterval;
    if (autosave) _lastAutosave = now;

    final result = <Torrent>[];
    var indexChanged = false;
    for (final entry in _entries.values) {
      final lt.TorrentStatus status;
      try {
        status = entry.handle.getStatus();
      } on lt.LibtorrentException {
        continue;
      }
      final finished =
          status.state == lt.LibtorrentTorrentState.finished ||
          status.state == lt.LibtorrentTorrentState.seeding;

      // Metadata of a magnet link has arrived: its real name is known now.
      final gotMetadata = !entry.hasMetadata && status.totalWanted > 0;
      if (gotMetadata) {
        entry.hasMetadata = true;
        final name = _nameOf(entry.handle);
        if (name.isNotEmpty) entry.name = name;
        indexChanged = true;
        if (entry.askFiles) {
          entry.askFiles = false;
          if (files(entry.id).length > 1) {
            _pauseEntry(entry);
            _fileChoices.add(entry.id);
          }
        }
      }
      final justFinished = finished && !entry.finished;
      entry.finished = finished;
      if (gotMetadata ||
          justFinished ||
          (autosave && _needsSave(entry.handle))) {
        _saveResume(entry);
      }
      _retryDht(entry, status, now);

      result.add(
        Torrent(
          id: entry.id,
          name: entry.name.isEmpty ? entry.id : entry.name,
          savePath: entry.savePath,
          state: _stateOf(status),
          progress: status.progress.clamp(0, 1).toDouble(),
          size: status.totalWanted,
          done: status.totalWantedDone,
          downloadRate: status.downloadPayloadRate.round(),
          uploadRate: status.uploadPayloadRate.round(),
          uploaded: status.allTimeUpload,
          peers: status.numPeers,
          seeds: status.numSeeds,
          added: entry.added,
          error: status.error,
        ),
      );
    }
    if (indexChanged) _saveIndex();
    return result;
  }

  void pause(String id) => _wrap('failed', () => _pauseEntry(_find(id)));

  void _pauseEntry(_Entry entry) {
    entry.handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
    entry.handle.pause();
    entry.paused = true;
    _saveIndex();
    _saveResume(entry);
  }

  void resume(String id) => _wrap('failed', () {
    final entry = _find(id);
    entry.handle.clearError();
    entry.handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
    entry.handle.resume();
    entry.paused = false;
    _saveIndex();
  });

  /// The files of torrent [id], in the order of the torrent. Empty while a
  /// magnet link is still waiting for its metadata.
  List<TorrentFile> files(String id) => _wrap('failed', () {
    final handle = _find(id).handle;
    final entries = handle.getFiles();
    if (entries.isEmpty) return const <TorrentFile>[];
    final progress = handle.getFileProgress(flags: _pieceGranularity);
    final priorities = handle.getFilePriorities();
    return [
      for (final file in entries)
        // Padding between files to align them with pieces; never on disk.
        if (file.flags & _padFile == 0)
          TorrentFile(
            index: file.index,
            path: file.path.replaceAll(r'\', '/'),
            size: file.size,
            done: file.index < progress.length ? progress[file.index] : 0,
            wanted:
                file.index >= priorities.length || priorities[file.index] > 0,
          ),
    ];
  });

  /// Skips the files [indexes] of torrent [id] or takes them back. A skipped
  /// file is not downloaded, and the torrent counts as finished once the
  /// wanted ones are.
  void setFilesWanted(
    String id,
    Iterable<int> indexes, {
    required bool wanted,
  }) => _wrap('failed', () {
    final entry = _find(id);
    final priorities = entry.handle.getFilePriorities();
    for (final index in indexes) {
      if (index >= 0 && index < priorities.length) {
        priorities[index] = wanted ? _defaultPriority : _skipPriority;
      }
    }
    entry.handle.prioritizeFiles(priorities);
    // The choice lives in the resume data.
    _saveResume(entry);
  });

  void remove(String id, {required bool deleteFiles}) => _wrap('failed', () {
    final entry = _find(id);
    _running.removeTorrent(entry.handle, deleteFiles: deleteFiles);
    _entries.remove(id);
    _saveIndex();
    final resume = _resumeFile(id);
    if (resume.existsSync()) resume.deleteSync();
  });

  /// Bytes per second, 0 means unlimited.
  void setRateLimits(int download, int upload) => _wrap('failed', () {
    final session = _running;
    session.setDownloadRateLimit(download > 0 ? download : 0);
    session.setUploadRateLimit(upload > 0 ? upload : 0);
  });

  /// Saves the state of every torrent and stops the session.
  void shutdown() {
    final session = _session;
    if (session == null) return;
    _session = null;
    try {
      session.pause();
      for (final entry in _entries.values) {
        _saveResume(entry);
      }
      _saveIndex();
      _write(_sessionFile, session.getState());
    } on Object {
      // Closing must go on: whatever was saved earlier still stands.
    } finally {
      _entries.clear();
      session.close();
    }
  }

  // ------------------------------------------------------------ session ----

  lt.Session get _running =>
      _session ??
      (throw const EngineException('not_running', 'the engine is not running'));

  lt.Session _createSession() {
    try {
      if (_sessionFile.existsSync()) {
        return lt.createSessionFromState(_sessionFile.readAsBytesSync());
      }
    } on Object {
      // A damaged state file only costs a slower DHT start.
    }
    return lt.createSession();
  }

  /// The network and disk defaults of qBittorrent, so that the same library
  /// behaves the same way here.
  void _applySettings(lt.Session s, int port, int download, int upload) {
    const ints = {
      _Setting.alertMask: 0, // nothing reads the alerts
      _Setting.listenQueueSize: 30,
      _Setting.mixedModeAlgorithm: 0, // prefer TCP
      _Setting.connectionsLimit: 500,
      _Setting.unchokeSlotsLimit: 20,
      _Setting.connectionSpeed: 30,
      _Setting.requestQueueTime: 3,
      _Setting.peerTurnover: 4,
      _Setting.peerTurnoverCutoff: 90,
      _Setting.peerTurnoverInterval: 300,
      _Setting.chokingAlgorithm: 0, // fixed slots
      _Setting.seedChokingAlgorithm: 1, // fastest upload
      _Setting.sendBufferWatermark: 500 * 1024,
      _Setting.sendBufferLowWatermark: 10 * 1024,
      _Setting.sendBufferWatermarkFactor: 50,
      _Setting.stopTrackerTimeout: 2,
      _Setting.aioThreads: 10,
      _Setting.checkingMemUsage: 2048, // 32 MiB in 16 KiB blocks
      // No queue: every torrent is active at once.
      _Setting.activeDownloads: -1,
      _Setting.activeSeeds: -1,
      _Setting.activeLimit: -1,
      _Setting.activeTrackerLimit: -1,
      _Setting.activeDhtLimit: -1,
      _Setting.activeLsdLimit: -1,
      _Setting.outEncPolicy: lt.LibtorrentEncryptionPolicy.enabled,
      _Setting.inEncPolicy: lt.LibtorrentEncryptionPolicy.enabled,
      _Setting.allowedEncLevel: lt.LibtorrentEncryptionLevel.both,
    };
    const bools = {
      _Setting.enableDht: true,
      _Setting.enableLsd: true,
      _Setting.enableUpnp: true,
      _Setting.enableNatpmp: true,
      _Setting.enableIncomingUtp: true,
      _Setting.enableOutgoingUtp: true,
      _Setting.rateLimitIpOverhead: false,
      _Setting.announceToAllTrackers: false,
      _Setting.announceToAllTiers: true,
    };
    ints.forEach(s.setIntSetting);
    bools.forEach(s.setBoolSetting);
    s.setStringSetting(_Setting.userAgent, 'NoodleT/1.0.0');
    s.setStringSetting(_Setting.peerFingerprint, '-NT1000-');
    s.setStringSetting(
      _Setting.dhtBootstrapNodes,
      'dht.libtorrent.org:25401,dht.transmissionbt.com:6881,'
      'router.bittorrent.com:6881,router.utorrent.com:6881,'
      'dht.aelitis.com:6881',
    );
    s.setStringSetting(_Setting.listenInterfaces, '0.0.0.0:$port,[::]:$port');
    s.setDownloadRateLimit(download > 0 ? download : 0);
    s.setUploadRateLimit(upload > 0 ? upload : 0);
  }

  // ----------------------------------------------------------- torrents ----

  void _checkNew(String id) {
    if (_entries.containsKey(id)) {
      throw const EngineException('duplicate', 'the torrent is already added');
    }
  }

  _Entry _find(String id) =>
      _entries[id] ??
      (throw const EngineException('not_found', 'no such torrent'));

  void _adopt(
    String id,
    lt.TorrentHandle handle, {
    required String name,
    required String savePath,
    required String magnet,
    bool paused = false,
  }) {
    final entry = _Entry(
      id: id,
      handle: handle,
      name: name,
      savePath: savePath,
      magnet: magnet,
      added: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      paused: paused,
    );
    _configure(entry);
    _entries[id] = entry;
    _saveIndex();
    _saveResume(entry);
  }

  /// qBittorrent's per-torrent limits, and no automatic queueing: a torrent
  /// runs exactly when the user has not paused it.
  void _configure(_Entry entry) {
    final handle = entry.handle;
    handle.unsetFlags(lt.LibtorrentTorrentFlags.autoManaged);
    handle.setMaxConnections(100);
    handle.setMaxUploads(4);
    entry.paused ? handle.pause() : handle.resume();
  }

  void _restore(lt.Session session) {
    final List<dynamic> records;
    try {
      records = jsonDecode(_indexFile.readAsStringSync()) as List;
    } on Object {
      return; // first run
    }
    for (final record in records.cast<Map<String, dynamic>>()) {
      final id = record['id'] as String;
      final savePath = record['save_path'] as String;
      final magnet = record['magnet'] as String? ?? '';
      final handle =
          _addFromResume(session, id, savePath) ??
          _addFromMagnet(session, magnet, savePath);
      if (handle == null) continue;
      final entry = _Entry(
        id: id,
        handle: handle,
        name: record['name'] as String? ?? '',
        savePath: savePath,
        magnet: magnet,
        added: record['added'] as int? ?? 0,
        paused: record['paused'] == true,
        hasMetadata: record['has_metadata'] == true,
      );
      _configure(entry);
      _entries[id] = entry;
    }
  }

  lt.TorrentHandle? _addFromResume(
    lt.Session session,
    String id,
    String savePath,
  ) {
    try {
      final data = _resumeFile(id).readAsBytesSync();
      if (data.isEmpty) return null;
      return session.addTorrentFromTags([
        lt.LibtorrentTagItem.bytesValue(lt.LibtorrentTag.torResumeData, data),
        lt.LibtorrentTagItem.intValue(
          lt.LibtorrentTag.torResumeDataSize,
          data.length,
        ),
        lt.LibtorrentTagItem.stringValue(
          lt.LibtorrentTag.torSavePath,
          savePath,
        ),
      ]);
    } on Object {
      return null;
    }
  }

  lt.TorrentHandle? _addFromMagnet(
    lt.Session session,
    String magnet,
    String savePath,
  ) {
    if (magnet.isEmpty) return null;
    try {
      return session.addMagnet(magnetUri: magnet, savePath: savePath);
    } on lt.LibtorrentException {
      return null;
    }
  }

  /// libtorrent asks the DHT for peers of a new torrent only once, right when
  /// it starts, and skips even that if the DHT is not up yet, which is always
  /// the case for the torrents restored at startup. The next regular lookup
  /// comes about 15 minutes later, and when the trackers give no peers the
  /// torrent stands still all that time. So a torrent that runs without a
  /// single connection asks again every [_dhtRetryInterval].
  void _retryDht(_Entry entry, lt.TorrentStatus status, DateTime now) {
    final waiting =
        status.state == lt.LibtorrentTorrentState.downloading ||
        status.state == lt.LibtorrentTorrentState.downloadingMetadata;
    if (!waiting || status.paused || status.numConnections > 0) return;
    if (now.difference(entry.lastDhtAnnounce) < _dhtRetryInterval) return;
    entry.lastDhtAnnounce = now;
    try {
      entry.handle.forceDhtAnnounce();
    } on lt.LibtorrentException {
      // The next poll tries again.
    }
  }

  String _nameOf(lt.TorrentHandle handle) {
    try {
      return lt.parseMagnetUri(handle.makeMagnetUri()).name;
    } on lt.LibtorrentException {
      return '';
    }
  }

  TorrentState _stateOf(lt.TorrentStatus status) {
    if (status.error.isNotEmpty) return TorrentState.error;
    if (status.paused) return TorrentState.paused;
    return switch (status.state) {
      lt.LibtorrentTorrentState.queuedForChecking ||
      lt.LibtorrentTorrentState.checkingFiles ||
      lt.LibtorrentTorrentState.checkingResumeData => TorrentState.checking,
      lt.LibtorrentTorrentState.downloadingMetadata => TorrentState.metadata,
      lt.LibtorrentTorrentState.finished ||
      lt.LibtorrentTorrentState.seeding => TorrentState.seeding,
      _ => TorrentState.downloading,
    };
  }

  // -------------------------------------------------------------- files ----

  bool _needsSave(lt.TorrentHandle handle) {
    try {
      return handle.needSaveResumeData();
    } on lt.LibtorrentException {
      return false;
    }
  }

  void _saveResume(_Entry entry) {
    try {
      final data = entry.handle.getResumeData(flags: _saveInfoDict);
      if (data.isNotEmpty) _write(_resumeFile(entry.id), data);
    } on Object {
      // The next autosave tries again.
    }
  }

  void _saveIndex() {
    final records = [
      for (final entry in _entries.values)
        {
          'id': entry.id,
          'name': entry.name,
          'save_path': entry.savePath,
          'magnet': entry.magnet,
          'added': entry.added,
          'paused': entry.paused,
          'has_metadata': entry.hasMetadata,
        },
    ];
    _write(_indexFile, utf8.encode(jsonEncode(records)));
  }

  /// Writes to a temporary file first so a crash never leaves half a file.
  static void _write(File file, List<int> data) {
    final tmp = File('${file.path}.tmp')..writeAsBytesSync(data, flush: true);
    tmp.renameSync(file.path);
  }

  T _wrap<T>(String code, T Function() action) {
    try {
      return action();
    } on lt.LibtorrentException catch (e) {
      throw EngineException(code, e.message);
    } on FileSystemException catch (e) {
      throw EngineException(code, e.osError?.message ?? e.message);
    }
  }

  /// torrent_handle::save_info_dict: keep the metadata inside resume data.
  static const _saveInfoDict = 2;

  /// torrent_handle::piece_granularity: file progress in whole pieces, much
  /// cheaper than to the byte.
  static const _pieceGranularity = 1;

  /// file_storage::flag_pad_file.
  static const _padFile = 1;

  /// libtorrent's dont_download and default_priority.
  static const _skipPriority = 0;
  static const _defaultPriority = 4;
}

class _Entry {
  _Entry({
    required this.id,
    required this.handle,
    required this.name,
    required this.savePath,
    required this.magnet,
    required this.added,
    this.paused = false,
    this.hasMetadata = false,
  });

  final String id;
  final lt.TorrentHandle handle;
  String name;
  final String savePath;

  /// The link the torrent was added with: the way back if resume data is lost.
  final String magnet;
  final int added;
  bool paused;
  bool hasMetadata;
  bool finished = false;

  /// A magnet link added in this run: its files are to be offered once its
  /// metadata is known.
  bool askFiles = false;

  /// When the engine last asked the DHT for peers itself; see `_retryDht`.
  /// Starts at the time the torrent is added, so the first retry comes one
  /// interval later.
  DateTime lastDhtAnnounce = DateTime.now();
}

/// libtorrent 2.0 `settings_pack` identifiers that libtorrent_dart has no
/// names for. Strings count from 0, integers from 0x4000, booleans from 0x8000.
abstract final class _Setting {
  static const userAgent = 0x0000;
  static const listenInterfaces = 0x0005;
  static const peerFingerprint = 0x000a;
  static const dhtBootstrapNodes = 0x000b;

  static const stopTrackerTimeout = 0x4002;
  static const requestQueueTime = 0x4006;
  static const connectionSpeed = 0x4012;
  static const sendBufferLowWatermark = 0x401c;
  static const sendBufferWatermark = 0x401d;
  static const sendBufferWatermarkFactor = 0x401e;
  static const chokingAlgorithm = 0x401f;
  static const seedChokingAlgorithm = 0x4020;
  static const activeDownloads = 0x4029;
  static const activeSeeds = 0x402a;
  static const activeDhtLimit = 0x402c;
  static const activeTrackerLimit = 0x402d;
  static const activeLsdLimit = 0x402e;
  static const activeLimit = 0x402f;
  static const unchokeSlotsLimit = 0x4053;
  static const connectionsLimit = 0x4055;
  static const mixedModeAlgorithm = 0x4060;
  static const listenQueueSize = 0x4061;
  static const checkingMemUsage = 0x4066;
  static const aioThreads = 0x4068;
  static const peerTurnover = 0x406f;
  static const peerTurnoverCutoff = 0x4070;
  static const peerTurnoverInterval = 0x4071;
  static const alertMask = 0x4075;
  static const outEncPolicy = 0x4076;
  static const inEncPolicy = 0x4077;
  static const allowedEncLevel = 0x4078;

  static const rateLimitIpOverhead = 0x8010;
  static const announceToAllTiers = 0x8011;
  static const announceToAllTrackers = 0x8012;
  static const enableOutgoingUtp = 0x8020;
  static const enableIncomingUtp = 0x8021;
  static const enableUpnp = 0x803b;
  static const enableNatpmp = 0x803c;
  static const enableLsd = 0x803d;
  static const enableDht = 0x803e;
}
