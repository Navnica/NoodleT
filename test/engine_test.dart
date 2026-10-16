// Drives the real engine; nothing here needs the network.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_dart/libtorrent_dart.dart' as lt;
import 'package:noodlet/engine/engine.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';
const _magnet = 'magnet:?xt=urn:btih:$_hash&dn=Test%20%D1%84%D0%B0%D0%B9%D0%BB';

void main() {
  late Directory dir;
  late TorrentEngine engine;

  String start() => engine.start(
    stateDir: '${dir.path}${Platform.pathSeparator}состояние',
    listenPort: 0,
    downloadLimit: 0,
    uploadLimit: 0,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noodlet_test');
    engine = TorrentEngine();
  });

  tearDown(() {
    engine.shutdown();
    dir.deleteSync(recursive: true);
  });

  test('adds, pauses, restores and removes a magnet link', () {
    expect(start(), startsWith('2.0'));
    expect(engine.poll(), isEmpty);

    engine.addMagnet(_magnet, dir.path);
    var torrent = engine.poll().single;
    expect(torrent.id, _hash);
    expect(torrent.name, 'Test файл');
    expect(torrent.savePath, dir.path);
    expect(torrent.state, TorrentState.metadata);

    expect(
      () => engine.addMagnet(_magnet, dir.path),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'duplicate'),
      ),
    );

    engine.pause(_hash);
    expect(engine.poll().single.state, TorrentState.paused);

    // A new session finds the torrent again, still paused.
    engine.shutdown();
    start();
    torrent = engine.poll().single;
    expect(torrent.id, _hash);
    expect(torrent.state, TorrentState.paused);

    engine.resume(_hash);
    expect(engine.poll().single.state, TorrentState.metadata);

    engine.remove(_hash, deleteFiles: true);
    expect(engine.poll(), isEmpty);
    engine.shutdown();
    start();
    expect(engine.poll(), isEmpty);
  });

  test('lists the files of a torrent and keeps the ones skipped', () {
    start();
    // A torrent of three files, made here; the downloads go elsewhere.
    final sep = Platform.pathSeparator;
    final source = Directory(
      '${dir.path}$sep'
      'Альбом',
    )..createSync();
    final sizes = {'a.txt': 1000, 'b.txt': 20000, 'c.txt': 300};
    sizes.forEach((name, size) {
      File('${source.path}$sep$name').writeAsBytesSync(List.filled(size, 7));
    });
    final torrentFile = File('${dir.path}${sep}album.torrent')
      ..writeAsBytesSync(lt.createTorrentData(sourcePath: source.path));
    final downloads = Directory('${dir.path}${sep}downloads')..createSync();
    // Paused, as while the user picks the files: nothing starts.
    final id = engine.addFile(torrentFile.path, downloads.path, paused: true);
    expect(engine.poll().single.id, id);
    expect(engine.poll().single.state, TorrentState.paused);

    var files = engine.files(id);
    expect(files.map((f) => f.path), [
      'Альбом/a.txt',
      'Альбом/b.txt',
      'Альбом/c.txt',
    ]);
    expect(files.map((f) => f.size), [1000, 20000, 300]);
    expect(files.every((f) => f.wanted), isTrue);
    expect(engine.poll().single.size, 21300);

    final big = files.firstWhere((f) => f.path.endsWith('b.txt')).index;
    engine.setFilesWanted(id, [big], wanted: false);
    files = engine.files(id);
    expect(files.where((f) => !f.wanted).single.index, big);
    expect(engine.poll().single.size, 1300);

    // The choice survives a restart.
    engine.shutdown();
    start();
    expect(engine.files(id).where((f) => !f.wanted).single.index, big);

    engine.setFilesWanted(id, [big], wanted: true);
    expect(engine.files(id).every((f) => f.wanted), isTrue);
    expect(engine.poll().single.size, 21300);

    // Still paused after the restart, until the choice is made.
    expect(engine.poll().single.state, TorrentState.paused);
    engine.resume(id);
    expect(engine.poll().single.state, isNot(TorrentState.paused));
    expect(engine.takeFileChoices(), isEmpty); // only magnet links go there
  });

  test('reports bad input', () {
    start();
    expect(
      () => engine.addMagnet('magnet:?xt=nonsense', dir.path),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'bad_magnet'),
      ),
    );
    final notTorrent = File('${dir.path}${Platform.pathSeparator}x.torrent')
      ..writeAsStringSync('hello');
    expect(
      () => engine.addFile(notTorrent.path, dir.path),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'bad_torrent'),
      ),
    );
    expect(
      () => engine.addFile('${dir.path}/missing.torrent', dir.path),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'unreadable'),
      ),
    );
    expect(
      () => engine.pause(_hash),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'not_found'),
      ),
    );
  });
}
