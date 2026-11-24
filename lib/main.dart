import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'core/constants.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';

/// Kept for the app's lifetime: saves the index when the app quits.
late final AppLifecycleListener appLifecycle;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  // Quitting saves what was read since the last save, so the next start doesn't read it again.
  appLifecycle = AppLifecycleListener(onExitRequested: () async {
    // The window is hidden at once; whatever is left gets 10 s, then the app exits
    // regardless. An unfinished save never replaces the last complete one.
    await controller.prepareToQuit().timeout(const Duration(seconds: 10), onTimeout: () {});
    return AppExitResponse.exit;
  });
  runApp(SmartSearchApp(controller: controller));
  controller.init();
}

class SmartSearchApp extends StatelessWidget {
  const SmartSearchApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      themeMode: ThemeMode.light,
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.ready) return const _Splash();
          return controller.needsOnboarding
              ? OnboardingScreen(controller: controller)
              : HomeScreen(controller: controller);
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.manage_search_rounded, size: 56, color: cs.primary),
          const SizedBox(height: 16),
          const SizedBox(width: 120, child: LinearProgressIndicator()),
          const SizedBox(height: 14),
          Text('Opening your search index…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
