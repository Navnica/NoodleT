import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// The icon of NoodleT in the notification area (the system tray). While it
/// is on, closing the window only hides it and the downloads go on: a click on
/// the icon brings the window back, and its menu lists what is downloading
/// and quits.
///
/// Closing always goes through here, tray or not: [start] takes it over from
/// the system so that quitting can hide the window before the torrents are
/// saved, which takes a few seconds.
class Tray with WindowListener {
  Tray({required this.onQuit, this.onPauseAll, this.onResumeAll});

  /// Saves the torrents; the process ends right after.
  final VoidCallback onQuit;

  /// The menu items that stop and start every torrent at once.
  final VoidCallback? onPauseAll;
  final VoidCallback? onResumeAll;

  /// Tells the Windows runner whether the hidden window is in the tray, so
  /// that a second launch shows it instead of waiting for it to quit (see
  /// windows/runner/main.cpp).
  static const _instance = MethodChannel('noodlet/instance');

  static const _image = 'assets/icon/tray.png';

  TrayIcon? _icon;
  // The menu and its items, kept alive with their click listeners. A rebuilt
  // menu replaces them, and the old ones are freed on the next rebuild while
  // no menu is open, since the user may still have the old one in front of
  // them.
  _TrayMenu? _menu;
  final _retired = <_TrayMenu>[];
  bool _menuOpen = false;
  List<String>? _labels;
  String? _tooltip;
  bool _enabled = false;
  bool _quitting = false;

  Future<void> start() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }

  void dispose() {
    windowManager.removeListener(this);
    _removeIcon();
  }

  /// Follows the setting, the language of the menu, the speeds shown in the
  /// tooltip and the [downloads] listed at the top of the menu, one line
  /// each. Cheap to call on every refresh: only changes reach the system.
  void update({
    required bool enabled,
    required String open,
    required String exit,
    required String tooltip,
    String pauseAll = '',
    String resumeAll = '',
    List<String> downloads = const [],
  }) {
    _enabled = enabled;
    if (!enabled) {
      _removeIcon();
      return;
    }
    final icon = _icon ??= _createIcon();
    if (icon == null) return;
    final menu = _menu;
    final labels = [open, exit, pauseAll, resumeAll];
    if (menu == null ||
        !listEquals(_labels, labels) ||
        menu.downloads.length != downloads.length) {
      // An open menu keeps its rows until it closes; the next refresh after
      // that rebuilds it.
      if (menu == null || !_menuOpen) {
        _labels = labels;
        _setMenu(icon, open, exit, pauseAll, resumeAll, downloads);
      }
    } else {
      menu.relabel(downloads);
    }
    if (tooltip != _tooltip) {
      _tooltip = tooltip;
      icon.setTooltip(tooltip);
    }
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    await windowManager.hide();
    _markInTray(false);
    _removeIcon();
    onQuit();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    // Without an icon there would be no way back to a hidden window.
    if (_enabled && _icon != null && !_quitting) {
      windowManager.hide().then((_) => _markInTray(true));
    } else {
      quit();
    }
  }

  TrayIcon? _createIcon() {
    final icon = TrayIcon.create();
    final image = ImageAsset.fromAsset(_image);
    if (icon == null || image == null) {
      icon?.dispose();
      return null;
    }
    icon
      ..icon = image
      // A left click opens the window; Linux panels report no clicks and
      // open the menu on any of them.
      ..setContextMenuTrigger(ContextMenuTrigger.rightClicked)
      ..addListener((event) {
        if (event is TrayIconClickedEvent) show();
      })
      ..setVisible(true);
    return icon;
  }

  void _setMenu(
    TrayIcon icon,
    String open,
    String exit,
    String pauseAll,
    String resumeAll,
    List<String> downloads,
  ) {
    final menu = Menu.create();
    if (menu == null) return;
    final items = <MenuItem>[];
    MenuItem? addItem(String label, void Function() onClick) {
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) return null;
      item.addListener((event) {
        if (event is MenuItemClickedEvent) onClick();
      });
      menu.addItem(item);
      items.add(item);
      return item;
    }

    final rows = [for (final line in downloads) ?addItem(line, show)];
    if (rows.isNotEmpty) menu.addSeparator();
    addItem(open, show);
    if (onPauseAll case final onClick? when pauseAll.isNotEmpty) {
      addItem(pauseAll, onClick);
    }
    if (onResumeAll case final onClick? when resumeAll.isNotEmpty) {
      addItem(resumeAll, onClick);
    }
    menu.addSeparator();
    addItem(exit, quit);
    menu.addListener((event) {
      if (event is MenuOpenedEvent) _menuOpen = true;
      if (event is MenuClosedEvent) _menuOpen = false;
    });
    icon.setContextMenu(menu);

    if (!_menuOpen) {
      for (final old in _retired) {
        old.dispose();
      }
      _retired.clear();
    }
    if (_menu case final old?) _retired.add(old);
    _menu = _TrayMenu(menu, items, rows, List.of(downloads));
  }

  void _removeIcon() {
    _icon
      ?..setVisible(false)
      ..dispose();
    _icon = null;
    _menu?.dispose();
    _menu = null;
    for (final old in _retired) {
      old.dispose();
    }
    _retired.clear();
    _menuOpen = false;
    _labels = null;
    _tooltip = null;
  }

  void _markInTray(bool inTray) {
    if (Platform.isWindows) {
      _instance.invokeMethod('setInTray', inTray).ignore();
    }
  }
}

/// A tray menu with the rows of the current downloads on top.
class _TrayMenu {
  _TrayMenu(this.menu, this.items, this.rows, this.downloads);

  final Menu menu;
  final List<MenuItem> items;
  final List<MenuItem> rows;

  /// The text each of [rows] shows.
  final List<String> downloads;

  /// Updates the rows in place, which also works while the menu is open.
  void relabel(List<String> next) {
    for (var i = 0; i < rows.length; i++) {
      if (downloads[i] != next[i]) {
        downloads[i] = next[i];
        rows[i].label = next[i];
      }
    }
  }

  void dispose() {
    for (final item in items) {
      item.dispose();
    }
    menu.dispose();
  }
}
