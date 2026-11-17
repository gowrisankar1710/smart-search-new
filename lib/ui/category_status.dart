import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/file_types.dart';
import 'format.dart';

const _green = Color(0xFF22B573);

/// One plain line under the search field, e.g. "Documents ✓ · Images 12 left · Videos ✓",
/// plus a line naming files just added. Short re-reads (a saved file or two) stay quiet.
class CategoryLine extends StatelessWidget {
  const CategoryLine({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final counts = controller.categories();
    final reading = controller.showReading;
    final style = tt.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);

    final parts = <InlineSpan>[];
    for (final c in FileCategory.values) {
      final n = counts[c]!;
      if (n.total == 0) continue;
      if (parts.isNotEmpty) parts.add(const TextSpan(text: '  ·  '));
      final busy = reading && !n.done;
      parts
        ..add(TextSpan(text: '${c.label} '))
        ..add(busy
            ? TextSpan(
                text: '${formatCount(n.left)} left',
                style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600))
            : const TextSpan(text: '✓', style: TextStyle(color: _green, fontWeight: FontWeight.w700)));
    }
    final adds = controller.recentAdds;
    if (parts.isEmpty && adds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (parts.isNotEmpty) Text.rich(TextSpan(style: style, children: parts)),
        if (adds.isNotEmpty) ...[
          const SizedBox(height: 4),
          _RecentAddsLine(adds: adds, controller: controller),
        ],
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

