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

  tearDown(() async {
    engine.shutdown();
    await engine.flushed;
    dir.deleteSync(recursive: true);
  });

  /// The size of the only torrent once it is [expected], or after a few
  /// seconds: libtorrent applies a new choice of files in the background.
  int sizeOnceSettled(int expected) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var size = engine.poll().single.size;
    while (size != expected && DateTime.now().isBefore(deadline)) {
      sleep(const Duration(milliseconds: 20));
      size = engine.poll().single.size;
    }
    return size;
  }

  /// A .torrent of the files [sizes] in a folder [name], made here.
  File makeTorrent(String name, Map<String, int> sizes) {
    final sep = Platform.pathSeparator;
    final source = Directory('${dir.path}${sep}source$sep$name')
      ..createSync(recursive: true);
    sizes.forEach((file, size) {
      File('${source.path}$sep$file').writeAsBytesSync(List.filled(size, 7));
    });
    final target = sizes.length == 1
        ? '${source.path}$sep${sizes.keys.single}'
        : source.path;
    return File('${dir.path}$sep$name.torrent')
      ..writeAsBytesSync(lt.createTorrentData(sourcePath: target));
  }

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
    expect(sizeOnceSettled(1300), 1300);

    // The choice survives a restart.
    engine.shutdown();
    start();
    expect(engine.files(id).where((f) => !f.wanted).single.index, big);

    engine.setFilesWanted(id, [big], wanted: true);
    expect(engine.files(id).every((f) => f.wanted), isTrue);
    expect(sizeOnceSettled(21300), 21300);

    // Still paused after the restart, until the choice is made.
    expect(engine.poll().single.state, TorrentState.paused);
    engine.resume(id);
    expect(engine.poll().single.state, isNot(TorrentState.paused));
    expect(engine.takeFileChoices(), isEmpty); // only magnet links go there
  });

  test('asks for the files again after a restart until they are chosen', () {
    start();
    final sep = Platform.pathSeparator;
    final torrent = makeTorrent('Сборник', {'a.txt': 1000, 'b.txt': 2000});
    final downloads = '${dir.path}${sep}downloads';
    final elsewhere = '${dir.path}${sep}elsewhere';
    Directory(downloads).createSync();

    final id = engine.addFile(torrent.path, downloads, chooseFiles: true);
    expect(engine.takeFileChoices(), [id]);
    expect(engine.takeFileChoices(), isEmpty);
    expect(engine.poll().single.state, TorrentState.paused);

    // Closed while the dialog was open: the question comes back.
    engine.shutdown();
    start();
    expect(engine.takeFileChoices(), [id]);
    expect(engine.poll().single.state, TorrentState.paused);

    final a = engine.files(id).firstWhere((f) => f.path.endsWith('a.txt'));
    engine.chooseFiles(id, {a.index}, savePath: elsewhere);
    var state = engine.poll().single;
    expect(state.state, isNot(TorrentState.paused));
    expect(state.savePath, elsewhere);
    expect(sizeOnceSettled(1000), 1000);
    expect(engine.files(id).where((f) => f.wanted).single.index, a.index);
    expect(engine.contentPath(id), (
      path: '$elsewhere$sepСборник',
      isFile: false,
    ));

    engine.shutdown();
    start();
    expect(engine.takeFileChoices(), isEmpty);
    state = engine.poll().single;
    expect(state.savePath, elsewhere);
    expect(state.state, isNot(TorrentState.paused));
  });

  test('starts a torrent of one file without asking', () {
    start();
    final torrent = makeTorrent('single', {'movie.mkv': 5000});
    final id = engine.addFile(torrent.path, dir.path, chooseFiles: true);
    expect(engine.takeFileChoices(), isEmpty);
    expect(engine.poll().single.state, isNot(TorrentState.paused));
    expect(engine.contentPath(id), (
      path: '${dir.path}${Platform.pathSeparator}movie.mkv',
      isFile: true,
    ));
  });

  test('a removed torrent leaves the files that were there before', () {
    start();
    final sep = Platform.pathSeparator;
    final torrent = makeTorrent('Old', {'a.txt': 100, 'b.txt': 200});
    // The same files, downloaded long ago and no longer in the list.
    final old = File('${dir.path}${sep}Old${sep}a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('mine');
    final id = engine.addFile(torrent.path, dir.path, chooseFiles: true);
    expect(engine.takeFileChoices(), [id]);
    engine.remove(id, deleteFiles: false);
    expect(engine.poll(), isEmpty);
    expect(old.readAsStringSync(), 'mine');
  });

  test('keeps the download order and adds trackers', () {
    start();
    engine.addMagnet(_magnet, dir.path);
    expect(engine.poll().single.sequential, isFalse);
    engine.setSequential(_hash, sequential: true);
    expect(engine.poll().single.sequential, isTrue);

    expect(engine.trackers(_hash), isEmpty);
    expect(
      engine.addTrackers(_hash, [
        'udp://one.example:80/announce',
        '',
        'udp://one.example:80/announce',
      ]),
      1,
    );
    // The same magnet link with one more tracker brings just that one.
    expect(
      () => engine.addMagnet(
        '$_magnet&tr=udp%3A%2F%2Ftwo.example%3A80%2Fannounce',
        dir.path,
      ),
      throwsA(isA<DuplicateException>().having((e) => e.newTrackers, 'new', 1)),
    );
    expect(engine.trackers(_hash), [
      'udp://one.example:80/announce',
      'udp://two.example:80/announce',
    ]);
    expect(engine.peers(_hash), isEmpty);

    engine.shutdown();
    start();
    expect(engine.poll().single.sequential, isTrue);
    expect(engine.trackers(_hash), hasLength(2));
  });

  test('introduces itself with the version', () {
    expect(TorrentEngine.peerFingerprint('1.3.0'), '-NT1300-');
    expect(TorrentEngine.peerFingerprint('2.10'), '-NT2900-');
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
