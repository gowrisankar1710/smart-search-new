import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/locations.dart';
import 'analysis_view.dart';
import 'format.dart';

void showSettingsSheet(BuildContext context, AppController c) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => _SettingsBody(controller: c, scroll: scroll, hostContext: context),
      ),
    ),
  );
}

/// Opens a full-screen analysis that reads every file; it returns to Search only once
/// everything is read (no back button meanwhile). Returning to Search restarts
/// its "time until search" clock.
Future<void> openAnalysis(BuildContext context, AppController c, {List<ScanRoot>? only}) async {
  final previous = c.timing;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (ctx) => Scaffold(
      appBar: AppBar(title: const Text('Analysing'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: AnalysisView(
          start: (onProgress) => c.analyse(onProgress: onProgress, only: only),
          previous: previous,
          footnote: only == null ? analysisFootnote(c) : null,
          onContinue: () {
            Navigator.of(ctx).pop();
            c.startBackground();
          },
        ),
      ),
    ),
  ));
  c.enterSearchScreen();
}

/// What the Timer screen says it waits for.
String? analysisFootnote(AppController c) => c.hasWholeDrives
    ? 'Search opens once your documents and images are read. Large files, videos and whole drives continue in the background.'
    : null;

class _SettingsBody extends StatelessWidget {
  const _SettingsBody({required this.controller, required this.scroll, required this.hostContext});
  final AppController controller;
  final ScrollController scroll;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = c.stats;

    return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
      Text('Index', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      Row(children: [
        _Tile('Files', formatCount(s.total)),
        _Tile('Read', formatCount(s.read)),
        _Tile('Waiting', formatCount(s.pending)),
        _Tile('Unreadable', formatCount(s.failed)),
      ]),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Keep reading files in the background'),
        subtitle: const Text('Reads new and changed files as they appear'),
        value: c.store.backgroundEnabled,
        onChanged: c.setBackgroundEnabled,
      ),
      FutureBuilder<bool>(
        future: c.ocr.isAvailable(),
        builder: (_, snap) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.image_search_rounded),
          title: const Text('Text in images'),
          subtitle: Text(snap.data == false
              ? 'Not available on this device'
              : c.ocr.name),
        ),
      ),
      const Divider(height: 32),
      Text('Search locations', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      for (final r in c.roots)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(r.userAdded ? Icons.folder_special_rounded : Icons.folder_rounded, color: cs.primary),
          title: Text(r.label),
          subtitle: Text(friendlyPath(r.path), maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: r.userAdded
              ? IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: () => c.removeFolder(r),
                )
              : null,
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Add folder'),
        onPressed: () async {
          final root = await c.pickAndAddFolder();
          if (root != null && hostContext.mounted) {
            Navigator.of(context).pop();
            await openAnalysis(hostContext, c, only: [root]);
          }
        },
      ),
      const SizedBox(height: 12),
      FilledButton.tonalIcon(
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Re-analyse everything (1 min)'),
        onPressed: () {
          Navigator.of(context).pop();
          openAnalysis(hostContext, c);
        },
      ),
      if (c.store.lastRun != null) ...[
        const SizedBox(height: 12),
        Text('Last analysed ${formatDate(c.store.lastRun!)}',
            textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          FittedBox(child: Text(value, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          Text(label, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
