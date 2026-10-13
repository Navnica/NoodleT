/// What the user handed over: pasted, dropped or passed on the command line.
sealed class TorrentInput {
  const TorrentInput();

  /// Returns null when [text] is neither a magnet link, an info-hash nor a
  /// path to a .torrent file.
  static TorrentInput? parse(String text) {
    var value = text.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.isEmpty) return null;
    if (value.toLowerCase().startsWith('magnet:?')) return MagnetInput(value);
    if (_infoHash.hasMatch(value)) {
      return MagnetInput('magnet:?xt=urn:btih:${value.toLowerCase()}');
    }
    if (value.toLowerCase().endsWith('.torrent')) {
      if (value.toLowerCase().startsWith('file://')) {
        return FileInput(Uri.parse(value).toFilePath());
      }
      return FileInput(value);
    }
    return null;
  }

  static final _infoHash = RegExp(r'^([0-9a-fA-F]{40}|[A-Za-z2-7]{32})$');
}

class MagnetInput extends TorrentInput {
  const MagnetInput(this.uri);
  final String uri;
}

class FileInput extends TorrentInput {
  const FileInput(this.path);
  final String path;
}
