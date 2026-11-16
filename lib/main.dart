import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(SmartSearchApp(controller: controller));
  controller.init();
}

class SmartSearchApp extends StatelessWidget {
  const SmartSearchApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart File Search',
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
        ]),
      ),
    );
  }
}
