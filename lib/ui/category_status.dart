import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/file_types.dart';

const _green = Color(0xFF22B573);

/// Under the search field: names files just added, e.g. "New image added: beach.jpg ·
/// reading…" → "· searchable". Nothing is shown otherwise.
class CategoryLine extends StatelessWidget {
  const CategoryLine({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final adds = controller.recentAdds;
    if (adds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
      child: _RecentAddsLine(adds: adds, controller: controller),
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

