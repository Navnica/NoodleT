/// Something the user should be told, shown as a snack bar. The controller
/// only says what happened; the interface puts it into words in the current
/// language.
enum NoticeKind {
  /// [Notice.detail] is the name of the torrent.
  finished,
  duplicate,

  /// A magnet link of a torrent already in the list brought new trackers;
  /// [Notice.detail] is how many.
  trackersAdded,
  badMagnet,
  badTorrent,
  unreadable,
  notRecognised,

  /// [Notice.detail] is the reason given by the engine or the system.
  addFailed,

  /// [Notice.detail] is the whole text, as the engine words it.
  engine,

  /// A newer release is out; [Notice.detail] is its version.
  update,
}

class Notice {
  const Notice(this.kind, [this.detail = '']);

  final NoticeKind kind;
  final String detail;
}
