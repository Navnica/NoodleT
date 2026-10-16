import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// The icon of NoodleT in the notification area (the system tray). While it
/// is on, closing the window only hides it and the downloads go on: a click on
/// the icon brings the window back and its menu quits.
///
/// Closing always goes through here, tray or not: [start] takes it over from
/// the system so that quitting can hide the window before the torrents are
/// saved, which takes a few seconds.
class Tray with WindowListener {
  Tray({required this.onQuit});

  /// Saves the torrents; the process ends right after.
  final VoidCallback onQuit;

  /// Tells the Windows runner whether the hidden window is in the tray, so
  /// that a second launch shows it instead of waiting for it to quit (see
  /// windows/runner/main.cpp).
  static const _instance = MethodChannel('noodlet/instance');

  static const _image = 'assets/icon/tray.png';

  TrayIcon? _icon;
  // Kept alive with their click listeners while the icon shows the menu.
  Menu? _menu;
  List<MenuItem> _items = const [];
  (String, String)? _labels;
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

  /// Follows the setting, the language of the menu and the speeds shown in
  /// the tooltip. Cheap to call on every refresh: only changes reach the
  /// system.
  void update({
    required bool enabled,
    required String open,
    required String exit,
    required String tooltip,
  }) {
    _enabled = enabled;
    if (!enabled) {
      _removeIcon();
      return;
    }
    final icon = _icon ??= _createIcon();
    if (icon == null) return;
    if (_labels != (open, exit)) {
      _labels = (open, exit);
      _setMenu(icon, open, exit);
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

  void _setMenu(TrayIcon icon, String open, String exit) {
    final menu = Menu.create();
    final openItem = MenuItem.createWithLabelAndType(open, MenuItemType.normal);
    final exitItem = MenuItem.createWithLabelAndType(exit, MenuItemType.normal);
    if (menu == null || openItem == null || exitItem == null) return;
    openItem.addListener((event) {
      if (event is MenuItemClickedEvent) show();
    });
    exitItem.addListener((event) {
      if (event is MenuItemClickedEvent) quit();
    });
    menu
      ..addItem(openItem)
      ..addSeparator()
      ..addItem(exitItem);
    icon.setContextMenu(menu);
    _disposeMenu();
    _menu = menu;
    _items = [openItem, exitItem];
  }

  void _removeIcon() {
    _icon
      ?..setVisible(false)
      ..dispose();
    _icon = null;
    _disposeMenu();
    _labels = null;
    _tooltip = null;
  }

  void _disposeMenu() {
    for (final item in _items) {
      item.dispose();
    }
    _items = const [];
    _menu?.dispose();
    _menu = null;
  }

  void _markInTray(bool inTray) {
    if (Platform.isWindows) {
      _instance.invokeMethod('setInTray', inTray).ignore();
    }
  }
}
