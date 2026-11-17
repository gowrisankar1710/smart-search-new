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

/// Search screen before typing: how far documents, images and videos are read, and
/// which kind of file was just added.
class ReadingProgress extends StatelessWidget {
  const ReadingProgress({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final counts = controller.categories();
    final adds = controller.recentAdds;
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Reading your files', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            for (final c in FileCategory.values) ...[
              _Row(category: c, count: counts[c]!),
              const SizedBox(height: 8),
            ],
            if (adds.isNotEmpty) ...[
              const SizedBox(height: 4),
              _RecentAddsLine(adds: adds, controller: controller),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.category, required this.count});
  final FileCategory category;
  final CategoryCount count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final background = category == FileCategory.videos;
    final none = count.total == 0;
    final done = !none && count.done;
    final frac = count.total == 0 ? 0.0 : count.read / count.total;

    final (String status, Color color, Widget badge) = switch (()) {
      _ when none => ('None found', cs.onSurfaceVariant, Icon(Icons.remove_rounded, size: 16, color: cs.outline)),
      _ when done => ('All ${formatCount(count.total)} read', _green, const Icon(Icons.check_circle_rounded, size: 16, color: _green)),
      _ => (
          '${formatCount(count.read)} of ${formatCount(count.total)}${background ? ' · in background' : ''}',
          cs.primary,
          _spinner(cs.primary),
        ),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: done ? _green.withValues(alpha: 0.07) : cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: [
        Row(children: [
          Icon(categoryIcon(category), size: 18, color: done ? _green : cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(category.label, style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          Flexible(
            flex: 3,
            child: Text(
              status,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: tt.labelMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(width: 8),
          badge,
        ]),
        if (!none && !done) ...[
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: frac, minHeight: 4, backgroundColor: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
        ],
      ]),
    );
  }
}

Widget _spinner(Color color) =>
    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: color));

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
