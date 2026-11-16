import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/permissions.dart';
import 'analysis_view.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _analysing = false;
  bool _asking = false;

  AppController get c => widget.controller;

  Future<void> _start() async {
    setState(() => _asking = true);
    final granted = await requestStorageAccess();
    await c.refreshRoots();
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Without full storage access only some folders can be searched. You can change this in Settings later.'),
      ));
    }
    setState(() {
      _asking = false;
      _analysing = true;
    });
  }

  Future<void> _addFolder() async {
    await c.pickAndAddFolder();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _analysing
            ? AnalysisView(
                start: (onProgress) => c.analyse(onProgress: onProgress),
                onContinue: c.completeOnboarding,
              )
            : _intro(context),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(20)),
                child: Icon(Icons.manage_search_rounded, size: 36, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 24),
              Text('Find any file by what\'s inside it',
                  style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.15)),
              const SizedBox(height: 10),
              Text('No need to remember exact names or folders. Type any word you recall.',
                  style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
              const _Feature(Icons.description_outlined, 'Reads your documents', 'PDF, Word, Excel, PowerPoint and text files'),
              const _Feature(Icons.image_search_rounded, 'Reads text in images', 'Screenshots, scanned bills, photos of notes'),
              const _Feature(Icons.spellcheck_rounded, 'Forgiving search', 'Partial names, typos and related words all work'),
              const _Feature(Icons.lock_outline_rounded, 'Private', 'Everything runs on this device. Nothing is uploaded.'),
              const SizedBox(height: 24),
              Text('Places to search', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              ListenableBuilder(
                listenable: c,
                builder: (_, __) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in c.roots)
                      Chip(
                        avatar: Icon(r.userAdded ? Icons.folder_special_rounded : Icons.folder_rounded, size: 18),
                        label: Text(r.label),
                        side: BorderSide.none,
                        backgroundColor: cs.surfaceContainerHigh,
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add folder'),
                      onPressed: _addFolder,
                    ),
                  ],
                ),
              ),
              if (Platform.isIOS) ...[
                const SizedBox(height: 12),
                Text(
                  'iPhone apps can only read folders you choose. Tap “Add folder” to pick folders from Files or iCloud Drive.',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: _asking ? null : _start,
                  icon: const Icon(Icons.bolt_rounded),
                  label: Text(Platform.isAndroid ? 'Allow access & analyse' : 'Start analysis'),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text('Takes 1 minute at most', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 22, color: cs.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}
