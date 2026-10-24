import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noodlet/app_controller.dart';
import 'package:noodlet/engine/engine.dart';
import 'package:noodlet/l10n/app_localizations.dart';
import 'package:noodlet/settings.dart';
import 'package:noodlet/ui/details_panel.dart';
import 'package:noodlet/ui/dialogs.dart';
import 'package:noodlet/ui/home_page.dart';
import 'package:noodlet/ui/theme.dart';
import 'package:noodlet/version.dart';
import 'package:noodlet/ui/torrent_row.dart';

Torrent _torrent(TorrentState state) => Torrent(
  id: state.name,
  name: 'A very long torrent name that certainly does not fit ' * 3,
  savePath: r'C:\Downloads',
  state: state,
  progress: 0.4256,
  size: 5 * 1024 * 1024 * 1024,
  done: 2 * 1024 * 1024 * 1024,
  downloadRate: 12 * 1024 * 1024,
  uploadRate: 300 * 1024,
  uploaded: 700 * 1024 * 1024,
  peers: 128,
  seeds: 64,
  added: 1760000000,
  error: state == TorrentState.error ? 'Disk is full ' * 20 : '',
);

final _en = lookupAppLocalizations(const Locale('en'));
final _ru = lookupAppLocalizations(const Locale('ru'));

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('rows fit a narrow window in every state', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var toggled = 0;
    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            for (final state in TorrentState.values)
              TorrentRow(
                torrent: _torrent(state),
                onTap: () {},
                onToggle: () => toggled++,
                onOpenFolder: () {},
                onRemove: () {},
              ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(TorrentRow), findsNWidgets(TorrentState.values.length));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    expect(toggled, 1);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(_en.openFolder), findsOneWidget);
    expect(find.text(_en.remove), findsOneWidget);
  });

  testWidgets('a row is equally tall in every state', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final width in [480.0, 900.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              for (final state in TorrentState.values)
                TorrentRow(
                  torrent: _torrent(state),
                  onTap: () {},
                  onToggle: () {},
                  onOpenFolder: () {},
                  onRemove: () {},
                ),
            ],
          ),
        ),
      );
      final heights = tester
          .widgetList(find.byType(TorrentRow))
          .map((w) => tester.getSize(find.byWidget(w)).height)
          .toSet();
      expect(heights, hasLength(1), reason: 'at width $width');
    }
  });

  testWidgets('details fit a narrow and a wide panel in every state', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final width in [360.0, 680.0]) {
      tester.view.physicalSize = Size(width, 900);
      // Russian too: the date and the numbers are formatted per language.
      await tester.pumpWidget(
        _app(
          TorrentDetails(
            torrent: _torrent(TorrentState.downloading),
            onToggle: () {},
            onOpenFolder: () {},
            onRemove: () {},
          ),
          locale: const Locale('ru'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'ru at $width');
      expect(find.text(_ru.addedOn), findsOneWidget);
      for (final state in TorrentState.values) {
        var removed = 0;
        await tester.pumpWidget(
          _app(
            TorrentDetails(
              torrent: _torrent(state),
              onToggle: () {},
              onOpenFolder: () {},
              onRemove: () => removed++,
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: '$state at $width');
        expect(find.text(r'C:\Downloads'), findsOneWidget);
        expect(find.text(state.name), findsOneWidget); // the id as the hash
        await tester.tap(find.text(_en.remove));
        expect(removed, 1);
      }
    }
  });

  testWidgets('details list the files and switch them on and off', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 1400);
    final files = [
      for (final (i, name) in ['one.mkv', 'two.srt', 'three.nfo'].indexed)
        TorrentFile(
          index: i,
          path: 'Album/${'very long folder name/' * 3}$name',
          size: (i + 1) * 1000000,
          done: 0,
          wanted: i != 1,
        ),
    ];
    final calls = <String>[];
    await tester.pumpWidget(
      _app(
        TorrentDetails(
          torrent: _torrent(TorrentState.downloading),
          files: files,
          onToggle: () {},
          onOpenFolder: () {},
          onRemove: () {},
          onFilesWanted: (indexes, wanted) =>
              calls.add('${indexes.join(',')} $wanted'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('${_en.files}  ·  ${_en.filesChosen(2, 3)}'), findsOne);
    // The torrent's own folder is not repeated in every line.
    expect(find.textContaining('Album/'), findsNothing);

    final boxes = find.byType(Checkbox);
    expect(boxes, findsNWidgets(4)); // "all" and one per file
    await tester.tap(boxes.at(2)); // the skipped two.srt
    await tester.tap(boxes.at(1)); // one.mkv
    await tester.tap(boxes.first); // partly chosen: all of them
    expect(calls, ['1 true', '0 false', '0,1,2 true']);
  });

  testWidgets('file choice dialog returns the chosen files', (tester) async {
    final files = [
      for (final (i, name) in ['one.mkv', 'two.srt', 'three.nfo'].indexed)
        TorrentFile(
          index: i,
          path: 'Album/$name',
          size: (i + 1) * 1000,
          done: 0,
          wanted: true,
        ),
    ];
    FilePick? result = (files: {-1}, folder: '');
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showFileChoiceDialog(
              context,
              name: 'Album',
              folder: r'C:\Downloads',
              files: files,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text(_en.chooseFilesTitle), findsOne);
    expect(find.text('one.mkv'), findsOne);
    expect(find.text(r'C:\Downloads'), findsOne); // where it goes
    // Sizes only: nothing is downloaded yet.
    expect(find.textContaining('%'), findsNothing);
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(2)); // two.srt
    await tester.pump();
    await tester.tap(find.text(_en.add));
    await tester.pumpAndSettle();
    expect(result?.files, {0, 2});
    expect(result?.folder, r'C:\Downloads');
    expect(find.text(_en.saveTo), findsNothing); // closed

    await open();
    await tester.tap(find.text(_en.cancel));
    await tester.pumpAndSettle();
    expect(result, isNull);

    // With every file cleared there is nothing to add.
    await open();
    await tester.tap(find.byType(Checkbox).first); // all chosen: clears all
    await tester.pump();
    final add = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, _en.add),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('remove dialog returns the checkbox value', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showRemoveDialog(context, 'ubuntu.iso'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_en.removeFiles));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _en.remove));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('the language chosen in the settings is applied and saved', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('noodlet_lang');
    addTearDown(() => dir.deleteSync(recursive: true));
    // A desktop window, so that the whole dialog fits.
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController(
      engine: TorrentEngine(),
      store: SettingsStore(dir.path),
    )..settings = AppSettings(downloadDir: dir.path, listenPort: 50000);
    controller.language.value = AppLanguage.ru;

    // The application's own wiring: the locale follows the controller.
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: controller.language,
        builder: (context, language, _) => _app(
          Builder(
            builder: (context) => Column(
              children: [
                // Constant, so only a change of locale can rebuild it.
                const _Probe(),
                TextButton(
                  onPressed: () => showSettingsDialog(context, controller),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
          locale: language.locale!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_ru.done), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(_ru.language), findsOneWidget);
    await tester.ensureVisible(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _ru.save));
    // Saving writes and renames a file, and a widget test lets file
    // operations finish only in real time, one step per round.
    final settingsFile = File('${dir.path}/settings.json');
    for (var i = 0; i < 20 && !settingsFile.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(controller.language.value, AppLanguage.en);
    expect(find.text(_en.done), findsOneWidget);
    expect(find.text(_ru.done), findsNothing);
    final saved = jsonDecode(
      File('${dir.path}/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(saved['language'], 'en');
  });

  _themeTest();
  _proxyTest();
  _updateTest();
  _updateTagTest();
}

void _themeTest() {
  testWidgets('the theme chosen in the settings is applied and saved', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('noodlet_theme');
    addTearDown(() => dir.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController(
      engine: TorrentEngine(),
      store: SettingsStore(dir.path),
    )..settings = AppSettings(downloadDir: dir.path, listenPort: 50000);

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context, controller),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // One swatch per colour.
    for (final accent in AppAccent.values) {
      expect(find.byTooltip(_en.accentName(accent.name)), findsOne);
    }
    await tester.ensureVisible(find.text(_en.themeDark));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_en.themeDark));
    await tester.ensureVisible(find.byTooltip(_en.accentName('red')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(_en.accentName('red')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _en.save));
    final settingsFile = File('${dir.path}/settings.json');
    for (var i = 0; i < 20 && !settingsFile.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(controller.appearance.value, (AppThemeMode.dark, AppAccent.red));
    final saved =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(saved['theme_mode'], 'dark');
    expect(saved['accent'], 'red');
  });

  test('every colour builds a light and a dark theme', () {
    for (final accent in AppAccent.values) {
      for (final brightness in Brightness.values) {
        final theme = buildTheme(brightness, accent: accent);
        expect(theme.colorScheme.brightness, brightness, reason: '$accent');
      }
    }
    // The own colours stay NoodleT's.
    expect(buildTheme(Brightness.dark).colorScheme.primary, Palette.mint);
  });
}

void _proxyTest() {
  testWidgets('the proxy chosen in the settings is checked and saved', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('noodlet_proxy');
    addTearDown(() => dir.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController(
      engine: TorrentEngine(),
      store: SettingsStore(dir.path),
    )..settings = AppSettings(downloadDir: dir.path, listenPort: 50000);

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context, controller),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    FilledButton save() =>
        tester.widget(find.widgetWithText(FilledButton, _en.save));
    // Off: nothing to fill in.
    expect(save().onPressed, isNotNull);
    expect(find.text(_en.proxySocksHint), findsNothing);

    // Off: no proxy fields either, only the two speed limits.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    // On without a server: it cannot be saved.
    await tester.ensureVisible(find.text('SOCKS5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOCKS5'));
    await tester.pumpAndSettle();
    expect(fields, findsNWidgets(6));
    expect(save().onPressed, isNull);
    expect(find.text(_en.proxyIncomplete), findsOne);
    expect(find.text(_en.proxySocksHint), findsOne);

    // After the two speed limits.
    await tester.enterText(fields.at(2), ' proxy.example ');
    await tester.enterText(fields.at(3), '8080');
    await tester.enterText(fields.at(4), 'me');
    await tester.enterText(fields.at(5), 'secret');
    await tester.pump();
    expect(save().onPressed, isNotNull);
    // The password is hidden until asked for.
    expect(tester.widget<TextField>(fields.at(5)).obscureText, isTrue);
    await tester.ensureVisible(find.byTooltip(_en.proxyShowPassword));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(_en.proxyShowPassword));
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(5)).obscureText, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, _en.save));
    final settingsFile = File('${dir.path}/settings.json');
    for (var i = 0; i < 20 && !settingsFile.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(
      controller.settings.proxy,
      const ProxyConfig(
        kind: ProxyKind.socks5,
        host: 'proxy.example',
        port: 8080,
        username: 'me',
        password: 'secret',
      ),
    );
    final saved =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(saved['proxy'], {
      'type': 'socks5',
      'host': 'proxy.example',
      'port': 8080,
      'username': 'me',
      'password': 'secret',
    });
  });
}

void _updateTest() {
  testWidgets('the settings end with the version and a check for updates', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('noodlet_update');
    addTearDown(() => dir.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController(
      engine: TorrentEngine(),
      store: SettingsStore(dir.path),
    )..settings = AppSettings(downloadDir: dir.path, listenPort: 50000);
    // As if the check at startup had found one.
    controller.availableUpdate.value = '99.0.0';

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context, controller),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('NoodleT $appVersion'), findsOne);
    expect(find.text(_en.updateCheckNow), findsOne);
    expect(find.text(_en.updateFound('99.0.0')), findsOne);
    expect(find.text(_en.updateDownload), findsOne);
  });
}

void _updateTagTest() {
  testWidgets('a newer release shows as a tag', (tester) async {
    await tester.pumpWidget(_app(const UpdateTag(version: '1.6.0')));
    expect(tester.takeException(), isNull);
    expect(find.text(_en.updateTag('1.6.0')), findsOne);
    expect(
      find.byTooltip('${_en.updateAvailable('1.6.0')} — ${_en.updateDownload}'),
      findsOne,
    );
  });
}

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) => Text(AppLocalizations.of(context).done);
}
