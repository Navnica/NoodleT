import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The icon of NoodleT in the Windows notification area. While it is on,
/// closing the window only hides it there and the downloads go on: the icon
/// brings the window back and its menu quits. The icon itself lives in
/// windows/runner/flutter_window.cpp; this side tells it what to show.
class Tray {
  static const _channel = MethodChannel('noodlet/tray');

  Map<String, Object>? _config;
  String? _tooltip;

  /// Sends only what changed since the last call, so it is fine to call on
  /// every refresh.
  void update({
    required bool enabled,
    required String open,
    required String exit,
    required String hiddenTitle,
    required String hiddenText,
    required String tooltip,
  }) {
    if (!Platform.isWindows) return;
    // The tooltip first: the icon shows it from the moment it appears.
    if (tooltip != _tooltip) {
      _tooltip = tooltip;
      _channel.invokeMethod('tooltip', tooltip).ignore();
    }
    final config = <String, Object>{
      'enabled': enabled,
      'open': open,
      'exit': exit,
      'hiddenTitle': hiddenTitle,
      'hiddenText': hiddenText,
    };
    if (!mapEquals(config, _config)) {
      _config = config;
      _channel.invokeMethod('configure', config).ignore();
    }
  }
}
