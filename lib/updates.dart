import 'dart:convert';
import 'dart:io';

import 'version.dart';

/// What a look for a newer release found.
enum UpdateStatus {
  /// This build is the latest release, or newer.
  upToDate,

  /// A newer release is out.
  available,

  /// GitHub could not be reached or made no sense.
  failed,
}

/// The [status] of a check and the latest [version] it saw, if any.
typedef UpdateCheck = ({UpdateStatus status, String version});

/// Looks for a newer release of NoodleT on GitHub.
abstract final class Updates {
  /// Where the user downloads the latest installer.
  static const releasePage =
      'https://github.com/Navnica/NoodleT/releases/latest';

  static final _latest = Uri.parse(
    'https://api.github.com/repos/Navnica/NoodleT/releases/latest',
  );

  /// Asks GitHub for the latest release; [source] replaces it in the tests.
  static Future<UpdateCheck> check({Uri? source}) async {
    const failed = (status: UpdateStatus.failed, version: '');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(source ?? _latest);
      // GitHub turns away requests without one.
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'NoodleT/$appVersion')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return failed;
      }
      final body = await response.transform(utf8.decoder).join();
      final tag = (jsonDecode(body) as Map<String, dynamic>)['tag_name'];
      if (tag is! String) return failed;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      return (
        status: isNewer(version, appVersion)
            ? UpdateStatus.available
            : UpdateStatus.upToDate,
        version: version,
      );
    } on Object {
      return failed;
    } finally {
      client.close(force: true);
    }
  }

  /// Compares versions such as "1.10.2" part by part, as numbers.
  static bool isNewer(String candidate, String current) {
    List<int> parts(String v) => [
      for (final part in v.split('+').first.split('.')) int.tryParse(part) ?? 0,
    ];
    final a = parts(candidate);
    final b = parts(current);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
