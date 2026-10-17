import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The languages the interface can be switched to in the settings. The texts
/// themselves are in `lib/l10n/app_<name>.arb`.
enum AppLanguage {
  /// Whatever the operating system is set to.
  system,
  ru,
  en;

  static AppLanguage parse(Object? name) =>
      values.asNameMap()[name] ?? AppLanguage.system;

  /// The locale to force, or null to follow the system.
  Locale? get locale => this == system ? null : Locale(name);
}

/// The order of the torrent list.
enum TorrentSort {
  /// Newest first.
  added,
  name,

  /// Least done first.
  progress,

  /// Largest first.
  size,

  /// Fastest first, download and upload together.
  speed;

  static TorrentSort parse(Object? name) =>
      values.asNameMap()[name] ?? TorrentSort.added;
}

class AppSettings {
  const AppSettings({
    required this.downloadDir,
    required this.listenPort,
    this.downloadLimitKb = 0,
    this.uploadLimitKb = 0,
    this.seedAfterDownload = true,
    this.closeToTray = true,
    this.language = AppLanguage.system,
    this.sort = TorrentSort.added,
    this.checkUpdates = true,
  });

  /// The ports a user may choose; below are the ones that need privileges.
  static const minPort = 1025;
  static const maxPort = 65535;

  static bool isValidPort(int port) => port >= minPort && port <= maxPort;

  final String downloadDir;

  /// Chosen at random on the first run and kept, so that port forwarding set
  /// up by the router stays valid.
  final int listenPort;

  /// KiB per second, 0 means unlimited.
  final int downloadLimitKb;
  final int uploadLimitKb;

  /// Whether a finished download keeps seeding until the user pauses it.
  /// When false it is stopped as soon as it completes.
  final bool seedAfterDownload;

  /// Whether closing the window hides it in the notification area while the
  /// downloads go on.
  final bool closeToTray;

  final AppLanguage language;

  final TorrentSort sort;

  /// Whether to look for a newer release on GitHub at startup.
  final bool checkUpdates;

  AppSettings copyWith({
    String? downloadDir,
    int? listenPort,
    int? downloadLimitKb,
    int? uploadLimitKb,
    bool? seedAfterDownload,
    bool? closeToTray,
    AppLanguage? language,
    TorrentSort? sort,
    bool? checkUpdates,
  }) => AppSettings(
    downloadDir: downloadDir ?? this.downloadDir,
    listenPort: listenPort ?? this.listenPort,
    downloadLimitKb: downloadLimitKb ?? this.downloadLimitKb,
    uploadLimitKb: uploadLimitKb ?? this.uploadLimitKb,
    seedAfterDownload: seedAfterDownload ?? this.seedAfterDownload,
    closeToTray: closeToTray ?? this.closeToTray,
    language: language ?? this.language,
    sort: sort ?? this.sort,
    checkUpdates: checkUpdates ?? this.checkUpdates,
  );

  Map<String, dynamic> toJson() => {
    'download_dir': downloadDir,
    'listen_port': listenPort,
    'download_limit_kb': downloadLimitKb,
    'upload_limit_kb': uploadLimitKb,
    'seed_after_download': seedAfterDownload,
    'close_to_tray': closeToTray,
    'language': language.name,
    'sort': sort.name,
    'check_updates': checkUpdates,
  };
}

/// Keeps the settings in settings.json inside the application data folder.
class SettingsStore {
  SettingsStore(this.dataDir);

  /// Where NoodleT keeps its own files; the engine state lives here too.
  final String dataDir;

  File get _file => File(p.join(dataDir, 'settings.json'));

  /// NOODLET_DATA_DIR moves the data elsewhere, e.g. for a portable copy or
  /// for trying a build without touching the real downloads.
  static Future<SettingsStore> open() async {
    final custom = Platform.environment['NOODLET_DATA_DIR'] ?? '';
    final dir = custom.isNotEmpty
        ? Directory(custom)
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return SettingsStore(dir.path);
  }

  Future<AppSettings> load() async {
    Map<String, dynamic> json = const {};
    try {
      json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    } on Object {
      // First run or a damaged file: fall back to the defaults.
    }
    final port = json['listen_port'];
    final dir = json['download_dir'];
    final settings = AppSettings(
      downloadDir: dir is String && dir.isNotEmpty
          ? dir
          : await _defaultDownloadDir(),
      listenPort: port is int && AppSettings.isValidPort(port)
          ? port
          : 49152 + Random().nextInt(16000),
      downloadLimitKb: _limit(json['download_limit_kb']),
      uploadLimitKb: _limit(json['upload_limit_kb']),
      seedAfterDownload: json['seed_after_download'] != false,
      closeToTray: switch (json['close_to_tray']) {
        final bool value => value,
        // Off by default on Linux: plain GNOME has no tray, and a window
        // hidden there could not be brought back.
        _ => !Platform.isLinux,
      },
      language: AppLanguage.parse(json['language']),
      sort: TorrentSort.parse(json['sort']),
      checkUpdates: json['check_updates'] != false,
    );
    if (json.isEmpty) await save(settings);
    return settings;
  }

  Future<void> save(AppSettings settings) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await tmp.rename(_file.path);
  }

  static int _limit(Object? value) => value is int && value > 0 ? value : 0;

  static Future<String> _defaultDownloadDir() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    return p.join(home ?? Directory.current.path, 'Downloads');
  }
}
