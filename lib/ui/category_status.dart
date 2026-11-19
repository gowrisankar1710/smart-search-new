import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_controller.dart';
import '../core/file_types.dart';
import '../services/indexer.dart';
import 'format.dart';

const _green = Color(0xFF22B573);

/// Under the search field: names files just added, e.g. "New image added: beach.jpg ·
/// reading…" → "· searchable". Nothing is shown otherwise.
class CategoryLine extends StatelessWidget {
  const CategoryLine({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final adds = controller.freshAdds;
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
        byCat[a.category!] = (byCat[a.category!] ?? 0) + 1;
      }
      more = ' +${others.length} more (${[
        for (final e in byCat.entries) '${e.value} ${e.key.singular}${e.value == 1 ? '' : 's'}',
      ].join(', ')})';
    }
    final waiting = newest.category == FileCategory.videos ? 'reading in background…' : 'reading…';
    final what = newest.category!.singular;

    return Tooltip(
      message: [for (final a in adds) '${a.category!.singular}: ${a.name}${controller.isRead(a.path) ? ' ✓' : ''}'].join('\n'),
      child: Row(children: [
        Icon(Icons.fiber_new_rounded, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(style: style, children: [
              TextSpan(text: 'New $what added: '),
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


/// Under the search field while files are read in the background:
///
///   Reading file contents                                   62%
///   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░
///   1,240 of 2,000 files · image: beach.jpg · 4.2 MB        1 min 05 s
///
/// Search works the whole time; this shows how far reading has got.
class ReadingProgressCard extends StatefulWidget {
  const ReadingProgressCard({super.key, required this.controller});
  final AppController controller;

  @override
  State<ReadingProgressCard> createState() => _ReadingProgressCardState();
}

class _ReadingProgressCardState extends State<ReadingProgressCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The controller notifies once a second; a quicker tick keeps the bar lively.
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final c = widget.controller;
      if (mounted && (c.backgroundProgress != null || c.contentLoading != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pr = c.backgroundProgress;
    final loading = c.contentLoading;
    final Widget child;
    if (loading != null) {
      final (done, total) = loading;
      child = _card(
        context,
        icon: Icons.manage_search_rounded,
        title: 'Preparing search',
        frac: total == 0 ? 1 : done / total,
        done: done,
        total: total,
        detail: 'names searchable now · text inside files loading',
      );
    } else if (pr != null && pr.phase == IndexPhase.analysing && pr.video != null) {
      // A video takes minutes: show how far this one has got, not the file count.
      final v = pr.video!;
      final size = c.store.files[v]?.size;
      child = _card(
        context,
        icon: Icons.movie_outlined,
        title: 'Watching ${p.basename(v)}',
        frac: pr.videoFraction,
        caption: pr.videoCount > 1 ? 'Video ${pr.videoNumber} of ${pr.videoCount}' : 'Video',
        detail: [
          if (size != null) formatBytes(size),
          'on-screen text${c.speechInVideos ? ' & speech' : ''}',
        ].join(' · '),
        elapsed: pr.elapsed,
        timeLeft: pr.videoTimeLeft,
      );
    } else if (pr != null && pr.phase == IndexPhase.analysing && c.showReading) {
      final cur = pr.current;
      final curFile = cur == null ? null : c.store.files[cur];
      final cat = curFile == null ? null : categoryOf(curFile.ext);
      child = _card(
        context,
        icon: cat == FileCategory.videos ? Icons.movie_outlined : Icons.auto_stories_outlined,
        title: cat == FileCategory.videos ? 'Watching videos' : 'Reading file contents',
        frac: pr.fraction,
        done: pr.analysed,
        total: pr.analysed + pr.remaining,
        detail: curFile == null
            ? null
            : '${cat?.singular ?? 'file'}: ${p.basename(cur!)} · ${formatBytes(curFile.size)}',
        elapsed: pr.elapsed,
        timeLeft: pr.timeLeft,
      );
    } else {
      child = const SizedBox(width: double.infinity);
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required String title,
    required double frac,
    int? done,
    int? total,
    String? caption,
    String? detail,
    Duration? elapsed,
    Duration? timeLeft,
  }) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    const tabular = [FontFeature.tabularFigures()];
    frac = frac.clamp(0.0, 1.0);
    final pct = (frac * 100).floor().clamp(0, 99); // 100 % only once it's finished
    final muted = tt.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: tabular);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Text('$pct%',
                style: tt.titleSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w800,
                  fontFeatures: tabular,
                )),
          ]),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(end: frac),
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOut,
            builder: (_, v, __) => ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: cs.primary.withValues(alpha: 0.10),
                color: cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(children: [
            Expanded(
              child: Text.rich(
                TextSpan(style: muted, children: [
                  if (done != null && total != null) ...[
                    TextSpan(
                      text: formatCount(done),
                      style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' of ${formatCount(total)} files'),
                  ] else if (caption != null)
                    TextSpan(text: caption, style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700)),
                  if (detail != null) TextSpan(text: '  ·  $detail'),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Time left once it can be estimated; until then, time so far.
            if (timeLeft != null || elapsed != null) ...[
              const SizedBox(width: 10),
              Text(timeLeft != null ? formatTimeLeft(timeLeft) : formatSeconds(elapsed!),
                  style: timeLeft != null ? muted?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600) : muted),
            ],
          ]),
        ]),
      ),
    );
  }
}
