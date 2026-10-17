import 'dart:io';

import 'package:path/path.dart' as p;

/// Shows [path] in the file manager: a folder opened, a file selected in
/// its folder where the system can do that.
void reveal(String path, {required bool isFile}) {
  final exists = isFile
      ? File(path).existsSync()
      : Directory(path).existsSync();
  if (Platform.isWindows) {
    final target = path.replaceAll('/', r'\');
    Process.run('explorer.exe', [
      if (isFile && exists) '/select,',
      exists ? target : p.dirname(target),
    ]).ignore();
  } else if (Platform.isMacOS) {
    Process.run('open', [
      if (isFile && exists) '-R',
      exists ? path : p.dirname(path),
    ]).ignore();
  } else {
    Process.run('xdg-open', [
      isFile || !exists ? p.dirname(path) : path,
    ]).ignore();
  }
}

/// Opens a web page in the default browser.
void openUrl(String url) {
  if (Platform.isWindows) {
    Process.run('rundll32', ['url.dll,FileProtocolHandler', url]).ignore();
  } else {
    Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [url]).ignore();
  }
}
