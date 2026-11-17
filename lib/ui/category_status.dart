import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/file_types.dart';
import 'format.dart';

const _green = Color(0xFF22B573);

IconData categoryIcon(FileCategory c) => switch (c) {
      FileCategory.documents => Icons.description_outlined,
      FileCategory.images => Icons.image_outlined,
      FileCategory.videos => Icons.movie_outlined,
    };

/// Accent per category, used for its icon and progress bar.
Color categoryColor(FileCategory c) => switch (c) {
      FileCategory.documents => const Color(0xFF4F5BFF),
      FileCategory.images => const Color(0xFFF08C2E),
      FileCategory.videos => const Color(0xFFE0457B),
    };

/// Search screen before typing: one quiet card – how far documents, images and videos
/// are read, and which kind of file was just added.
class ReadingProgress extends StatelessWidget {
  const ReadingProgress({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final counts = controller.categories();
    final adds = controller.recentAdds;
    final cats = FileCategory.values;
    final total = cats.fold<int>(0, (n, c) => n + counts[c]!.total);
    final allDone = cats.every((c) => counts[c]!.done);

    return Align(
      alignment: const Alignment(0, -0.35),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 18, offset: const Offset(0, 6)),
                ],
              ),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                  child: Row(children: [
                    if (allDone)
                      const Icon(Icons.check_circle_rounded, size: 18, color: _green)
                    else
                      _spinner(cs.primary),
                    const SizedBox(width: 10),
                    Text(allDone ? 'Ready to search' : 'Reading your files',
                        style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('${formatCount(total)} files',
                        style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
                ),
                Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
                LayoutBuilder(builder: (context, box) {
                  final tiles = [for (final c in cats) _Tile(category: c, count: counts[c]!)];
                  if (box.maxWidth < 420) {
                    return Column(children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) Divider(height: 1, indent: 20, endIndent: 20, color: cs.outlineVariant.withValues(alpha: 0.4)),
                        tiles[i],
                      ],
                    ]);
                  }
                  return IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) VerticalDivider(width: 1, indent: 16, endIndent: 16, color: cs.outlineVariant.withValues(alpha: 0.4)),
                        Expanded(child: tiles[i]),
                      ],
                    ]),
                  );
                }),
              ]),
            ),
            if (adds.isNotEmpty) ...[
              const SizedBox(height: 14),
              _RecentAddsLine(adds: adds, controller: controller),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.category, required this.count});
  final FileCategory category;
  final CategoryCount count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final accent = categoryColor(category);
    final none = count.total == 0;
    final done = !none && count.done;
    final muted = tt.labelSmall?.copyWith(color: cs.onSurfaceVariant);

    final Widget status = none
        ? Text('None yet', style: muted)
        : done
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_rounded, size: 14, color: _green),
                const SizedBox(width: 3),
                Text('All read', style: muted?.copyWith(color: _green, fontWeight: FontWeight.w600)),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '${formatCount(count.left)} left${category == FileCategory.videos ? ' · background' : ''}',
                  style: muted?.copyWith(color: accent, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: count.read / count.total,
                    minHeight: 3,
                    color: accent,
                    backgroundColor: accent.withValues(alpha: 0.12),
                  ),
                ),
              ]);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(9)),
            child: Icon(categoryIcon(category), size: 17, color: accent),
          ),
          const SizedBox(width: 10),
          Text(category.label, style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        Text(formatCount(count.total),
            style: tt.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800, letterSpacing: -0.5, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 4),
        status,
      ]),
    );
  }
}

/// "New image added: beach.jpg · reading…" → "· searchable".
class _RecentAddsLine extends StatelessWidget {
  const _RecentAddsLine({required this.adds, required this.controller});
  final List<RecentAdd> adds;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final newest = adds.first;
    final allRead = adds.every((a) => controller.isRead(a.path));
    final newestRead = controller.isRead(newest.path);
    final style = tt.labelSmall?.copyWith(color: cs.onSurfaceVariant);
    final strong = TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700);

    final others = adds.skip(1).toList();
    String? more;
    if (others.isNotEmpty) {
      final byCat = <FileCategory, int>{};
      for (final a in others) {
        byCat[a.category] = (byCat[a.category] ?? 0) + 1;
      }
      more = ' +${others.length} more (${[
        for (final e in byCat.entries) '${e.value} ${e.key.singular}${e.value == 1 ? '' : 's'}',
      ].join(', ')})';
    }
    final waiting = newest.category == FileCategory.videos ? 'reading in background…' : 'reading…';

    return Tooltip(
      message: [for (final a in adds) '${a.category.singular}: ${a.name}${controller.isRead(a.path) ? ' ✓' : ''}'].join('\n'),
      child: Row(children: [
        Icon(Icons.fiber_new_rounded, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(style: style, children: [
              TextSpan(text: 'New ${newest.category.singular} added: '),
              TextSpan(text: newest.name, style: strong),
              TextSpan(
                text: newestRead ? ' · searchable' : ' · $waiting',
                style: TextStyle(color: newestRead ? _green : cs.primary, fontWeight: FontWeight.w600),
              ),
              if (more != null) TextSpan(text: more + (allRead ? ' · all searchable' : '')),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}

Widget _spinner(Color color) =>
    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color));
