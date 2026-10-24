import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noodlet/app_controller.dart';
import 'package:noodlet/engine/engine.dart';
import 'package:noodlet/settings.dart';
import 'package:noodlet/updates.dart';
import 'package:noodlet/version.dart';

Torrent _torrent(
  String id, {
  String name = '',
  int added = 0,
  double progress = 0,
  int size = 0,
  int rate = 0,
}) => Torrent(
  id: id,
  name: name.isEmpty ? id : name,
  savePath: '',
  state: TorrentState.downloading,
  progress: progress,
  size: size,
  done: 0,
  downloadRate: rate,
  uploadRate: 0,
  uploaded: 0,
  peers: 0,
  seeds: 0,
  added: added,
  error: '',
);

void main() {
  test('lib/version.dart follows pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    final version = line.substring('version:'.length).trim().split('+').first;
    expect(appVersion, version);
  });

  test('compares versions as numbers', () {
    expect(Updates.isNewer('1.3.0', '1.2.1'), isTrue);
    expect(Updates.isNewer('1.10.0', '1.9.9'), isTrue);
    expect(Updates.isNewer('2.0', '1.9.9'), isTrue);
    expect(Updates.isNewer('1.2.1', '1.2.1'), isFalse);
    expect(Updates.isNewer('1.2.0', '1.2.1'), isFalse);
    expect(Updates.isNewer('1.2', '1.2.0'), isFalse);
  });

  test('sorts the torrents and keeps ties in a stable order', () {
    List<String> order(TorrentSort sort) {
      final list = [
        _torrent('a', name: 'beta', added: 1, progress: 0.9, size: 10),
        _torrent('b', name: 'Alpha', added: 3, progress: 0.1, rate: 50),
        _torrent('c', name: 'gamma', added: 2, progress: 0.5, size: 30),
        _torrent('d', name: 'delta', added: 2, progress: 0.5, size: 30),
      ];
      AppController.sortTorrents(list, sort);
      return [for (final t in list) t.id];
    }

    expect(order(TorrentSort.added), ['b', 'c', 'd', 'a']);
    expect(order(TorrentSort.name), ['b', 'a', 'd', 'c']);
    expect(order(TorrentSort.progress), ['b', 'c', 'd', 'a']);
    expect(order(TorrentSort.size), ['c', 'd', 'a', 'b']);
    expect(order(TorrentSort.speed), ['b', 'c', 'd', 'a']);
  });

  group('the check for updates', () {
    late HttpServer github;
    var answer = '';
    var code = 200;

    setUp(() async {
      // Stands in for GitHub's "latest release".
      github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      github.listen((request) {
        request.response
          ..statusCode = code
          ..write(answer)
          ..close();
      });
    });

    tearDown(() => github.close(force: true));

    Future<UpdateCheck> check() => Updates.check(
      source: Uri.parse('http://127.0.0.1:${github.port}/latest'),
    );

    test('finds a newer release', () async {
      answer = '{"tag_name": "v99.0.0"}';
      code = 200;
      expect(await check(), (
        status: UpdateStatus.available,
        version: '99.0.0',
      ));
    });

    test('says when this is the latest', () async {
      answer = '{"tag_name": "v$appVersion"}';
      code = 200;
      expect(await check(), (
        status: UpdateStatus.upToDate,
        version: appVersion,
      ));
    });

    test('says when GitHub does not answer properly', () async {
      answer = '{"message": "API rate limit exceeded"}';
      code = 403;
      expect((await check()).status, UpdateStatus.failed);
      code = 200;
      answer = 'not json';
      expect((await check()).status, UpdateStatus.failed);
    });

    test('says when GitHub cannot be reached', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final result = await Updates.check(
        source: Uri.parse('http://127.0.0.1:$port/latest'),
      );
      expect(result.status, UpdateStatus.failed);
    });
  });
}
