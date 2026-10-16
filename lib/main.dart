import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_controller.dart';
import 'engine/engine.dart';
import 'settings.dart';
import 'tray.dart';
import 'ui/home_page.dart';
import 'l10n/app_localizations.dart';
import 'ui/theme.dart';

/// [args] may carry magnet links and paths to .torrent files, which is how
/// the operating system hands them over when NoodleT is their default app.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  AppController? controller;
  Tray? tray;
  Object? failure;
  try {
    controller = AppController(
      engine: TorrentEngine(),
      store: await SettingsStore.open(),
    );
    await controller.start();
  } on Object catch (e) {
    failure = e;
  }
  if (failure == null) {
    tray = Tray(onQuit: controller!.shutdown);
    await tray.start();
  }

  runApp(
    // The language chosen in the settings; without one, the system's.
    ValueListenableBuilder(
      valueListenable:
          controller?.language ?? ValueNotifier(AppLanguage.system),
      builder: (context, language, _) => MaterialApp(
        title: 'NoodleT',
        locale: language.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: failure == null
            ? HomePage(controller: controller!, initialInputs: args, tray: tray)
            : _FailurePage(details: '$failure'),
      ),
    ),
  );
}

class _FailurePage extends StatelessWidget {
  const _FailurePage({required this.details});

  final String details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).engineFailed,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(
                details,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
