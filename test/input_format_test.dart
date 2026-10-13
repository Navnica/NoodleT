import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:noodlet/input.dart';
import 'package:noodlet/ui/format.dart';
import 'package:noodlet/l10n/app_localizations.dart';

void main() {
  group('TorrentInput.parse', () {
    test('recognises magnet links', () {
      final input = TorrentInput.parse('  magnet:?xt=urn:btih:abc  ');
      expect(input, isA<MagnetInput>());
      expect((input! as MagnetInput).uri, 'magnet:?xt=urn:btih:abc');
    });

    test('turns a bare info-hash into a magnet link', () {
      final hash = 'A' * 40;
      final input = TorrentInput.parse(hash) as MagnetInput;
      expect(input.uri, 'magnet:?xt=urn:btih:${'a' * 40}');
    });

    test('recognises .torrent paths, quoted or not', () {
      final input = TorrentInput.parse(r'"C:\Downloads\Файл.TORRENT"');
      expect((input! as FileInput).path, r'C:\Downloads\Файл.TORRENT');
    });

    test('rejects everything else', () {
      expect(TorrentInput.parse(''), isNull);
      expect(TorrentInput.parse('https://example.com'), isNull);
      expect(TorrentInput.parse('notes.txt'), isNull);
    });
  });

  group('format', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final ru = lookupAppLocalizations(const Locale('ru'));

    test('bytes', () {
      expect(formatBytes(0, en), '0 B');
      expect(formatBytes(1536, en), '1.5 KB');
      expect(formatBytes(1536, ru), '1,5 КБ');
      expect(formatBytes(150 * 1024 * 1024, en), '150 MB');
      expect(formatBytes(5 * 1024 * 1024 * 1024, en), '5.0 GB');
      expect(formatRate(2 * 1024 * 1024, ru), '2,0 МБ/с');
    });

    test('percent never shows 100% early', () {
      expect(formatPercent(0, en), '0%');
      expect(formatPercent(0.99999, en), '99.9%');
      expect(formatPercent(0.425, ru), '42,5%');
      expect(formatPercent(1, en), '100%');
    });

    test('duration keeps the two largest units', () {
      expect(
        formatDuration(const Duration(hours: 2, minutes: 5), ru),
        '2 ч 5 мин',
      );
      expect(
        formatDuration(const Duration(minutes: 7, seconds: 30), en),
        '7 min',
      );
      expect(formatDuration(Duration.zero, en), '1 s');
    });

    test('ratio', () {
      expect(formatRatio(0.345, en), '0.35');
      expect(formatRatio(1234.5, ru), '1234,50');
    });

    test('peers are declined', () {
      expect(en.peersCount(1), '1 peer');
      expect(en.peersCount(5), '5 peers');
      expect(ru.peersCount(1), '1 пир');
      expect(ru.peersCount(3), '3 пира');
      expect(ru.peersCount(5), '5 пиров');
      expect(ru.peersCount(21), '21 пир');
    });
  });
}
