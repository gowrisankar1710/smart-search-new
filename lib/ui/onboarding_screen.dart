import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/locations.dart';
import '../services/permissions.dart';
import 'analysis_view.dart';
import 'settings_sheet.dart';
import 'format.dart';
import 'theme.dart';

const _brand = Brand.blue;
const _accent = Brand.teal;

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
    await c.askSystemPermissions(); // macOS: the system prompts, before the analysis starts
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
      body: _analysing
          ? SafeArea(
              child: AnalysisView(
                start: (onProgress) => c.analyse(onProgress: onProgress),
                previous: c.timing,
                footnote: analysisFootnote(c),
                onContinue: c.completeOnboarding,
              ),
            )
          : _Backdrop(
              child: SafeArea(
                child: LayoutBuilder(builder: (context, box) {
                  final wide = box.maxWidth >= 900;
                  const hero = _Hero();
                  final card = ListenableBuilder(
                    listenable: c,
                    builder: (_, __) => _StartCard(
                      roots: c.roots,
                      busy: _asking,
                      onAddFolder: _addFolder,
                      onStart: _start,
                    ),
                  );
                  return Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 56 : 20, vertical: 32),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: wide ? 1040 : 520),
                        child: wide
                            ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                const Expanded(child: Padding(padding: EdgeInsets.only(right: 56), child: hero)),
                                SizedBox(width: 440, child: card),
                              ])
                            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                hero,
                                const SizedBox(height: 28),
                                card,
                              ]),
                      ),
                    ),
                  );
                }),
              ),
            ),
    );
  }
}

// ------------------------------------------------------------------ left: what the app does

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const BrandMark(size: 40),
        const SizedBox(width: 12),
        Text('Smart Search', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
      ]),
      const SizedBox(height: 36),
      Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'Find any file by\n'),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(colors: [_brand, _accent]).createShader(r),
              child: Text(
                'what\'s inside it',
                style: tt.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  height: 1.1,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ]),
        style: tt.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.1),
      ),
      const SizedBox(height: 16),
      Text(
        'Type any text you remember – from a file name, a line in a document, or words in a screenshot – and get the exact file.',
        style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.5),
      ),
      const SizedBox(height: 32),
      const _Feature(Icons.description_outlined, 'Reads your documents', 'PDF, Word, Excel, PowerPoint, text and code'),
      const _Feature(Icons.image_search_rounded, 'Reads text in images', 'Screenshots, scanned bills, photos of notes'),
      const _Feature(Icons.format_quote_rounded, 'Exact text search', 'Only files that really contain what you type'),
      const _Feature(Icons.lock_outline_rounded, 'Private by design', 'Runs entirely on this device – nothing is uploaded'),
    ]);
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
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Icon(icon, size: 20, color: _brand),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ right: where + start

class _StartCard extends StatelessWidget {
  const _StartCard({required this.roots, required this.busy, required this.onAddFolder, required this.onStart});
  final List<ScanRoot> roots;
  final bool busy;
  final VoidCallback onAddFolder;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [BoxShadow(color: _brand.withValues(alpha: 0.08), blurRadius: 40, offset: const Offset(0, 16))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text('Places to search', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(20)),
            child: Text('${roots.length}',
                style: tt.labelMedium?.copyWith(color: _brand, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 4),
        Text('Everything in these locations becomes searchable.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 14),
        Container(
          constraints: const BoxConstraints(maxHeight: 248),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: roots.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No folders yet – add one below.',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: roots.length,
                  separatorBuilder: (_, __) => Divider(indent: 52, color: cs.outlineVariant),
                  itemBuilder: (_, i) => _RootRow(root: roots[i]),
                ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onAddFolder,
          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
          label: const Text('Add another folder'),
          style: OutlinedButton.styleFrom(
            foregroundColor: cs.onSurface,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (Platform.isIOS) ...[
          const SizedBox(height: 10),
          Text(
            'iPhone apps can only read folders you choose. Use “Add another folder” to pick folders from Files or iCloud Drive.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 20),
        _GradientButton(
          onPressed: busy ? null : onStart,
          label: Platform.isAndroid ? 'Allow access & start' : 'Start analysis',
          busy: busy,
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.timer_outlined, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text('Reads every file first · Search opens when everything is searchable',
                textAlign: TextAlign.center, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ]),
      ]),
    );
  }
}

class _RootRow extends StatelessWidget {
  const _RootRow({required this.root});
  final ScanRoot root;

  static IconData _icon(ScanRoot r) {
    final l = r.label.toLowerCase();
    if (r.userAdded) return Icons.folder_special_outlined;
    if (l.contains('desktop')) return Icons.desktop_windows_outlined;
    if (l.contains('document')) return Icons.description_outlined;
    if (l.contains('download')) return Icons.download_outlined;
    if (l.contains('picture') || l.contains('camera')) return Icons.photo_outlined;
    if (l.contains('video') || l.contains('movie')) return Icons.movie_outlined;
    if (l.contains('music')) return Icons.music_note_outlined;
    if (l.contains('icloud')) return Icons.cloud_outlined;
    if (l.contains('home')) return Icons.home_outlined;
    if (l.contains('drive') || l.contains('storage') || l.contains('sd')) return Icons.storage_rounded;
    return Icons.folder_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: _brand.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
          child: Icon(_icon(root), size: 17, color: _brand),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(root.label, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(friendlyPath(root.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
        const Icon(Icons.check_circle_rounded, size: 18, color: Brand.teal),
      ]),
    );
  }
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({required this.onPressed, required this.label, required this.busy});
  final VoidCallback? onPressed;
  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [_brand, _accent]),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: _brand.withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 56,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (busy)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              else
                const Icon(Icons.bolt_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: Brand.wash),
      child: SizedBox.expand(child: child),
    );
  }
}
