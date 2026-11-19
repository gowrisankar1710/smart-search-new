import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'format.dart';
import 'theme.dart';

const _green = Color(0xFF22B573);

enum _State { ready, indexing, queued, paused, off }

/// "What you can search": the sidebar's categories, each saying whether its files are
/// searchable yet – Ready, Indexing · 26 %, Queued, Paused or Off.
class CapabilitiesGrid extends StatelessWidget {
  const CapabilitiesGrid({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kinds = controller.kindProgress();
    final filters = [for (final f in ResultFilter.values) if (f.kinds != null) f];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Text('WHAT YOU CAN SEARCH',
              style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
        ),
        LayoutBuilder(builder: (context, box) {
          const gap = 12.0;
          final cols = box.maxWidth >= 560 ? 2 : 1;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final f in filters)
              SizedBox(
                width: w,
                child: _CategoryCard(filter: f, progress: _sum(f, kinds), controller: controller),
              ),
          ]);
        }),
      ]),
    );
  }

  static KindProgress _sum(ResultFilter f, Map<dynamic, KindProgress> kinds) {
    final out = KindProgress();
    for (final k in f.kinds!) {
      final p = kinds[k]!;
      out
        ..total += p.total
        ..left += p.left
        ..partial += p.partial;
    }
    return out;
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.filter, required this.progress, required this.controller});
  final ResultFilter filter;
  final KindProgress progress;
  final AppController controller;

  String get _subtitle => switch (filter) {
        ResultFilter.documents => 'Word, RTF and OpenDocument – names and the words inside',
        ResultFilter.pdf => 'Text pages, and scanned pages read like a photo',
        ResultFilter.sheets => 'Excel, CSV and OpenDocument – every cell',
        ResultFilter.slides => 'PowerPoint and OpenDocument – every slide',
        ResultFilter.text => 'Notes, code, logs, JSON and other plain text',
        ResultFilter.images => 'Text in pictures, and what photos show',
        ResultFilter.media => controller.speechInVideos
            ? 'On-screen text, subtitles and speech · videos up to 50 MB'
            : 'On-screen text and subtitles · videos up to 50 MB',
        ResultFilter.other => 'Archives and other files, by name',
        ResultFilter.all => '',
      };

  /// Off when this device can't read inside these files at all.
  String? get _offReason => switch (filter) {
        ResultFilter.images when !controller.ocrAvailable => 'No text reader on this device – images are found by name',
        _ => null,
      };

  _State get _state {
    if (_offReason != null) return _State.off;
    if (progress.left == 0) return _State.ready;
    if (controller.readingContents) return _State.indexing;
    return controller.store.backgroundEnabled ? _State.queued : _State.paused;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final state = _state;
    final off = state == _State.off;
    final p = progress;
    final tip = switch (state) {
      _State.off => _offReason!,
      _State.ready when filter == ResultFilter.other => 'Searchable by name',
      _State.ready => p.total == 0 ? 'None found yet – new files are read as they appear' : '${formatCount(p.total)} files read',
      _State.paused => '${formatCount(p.left)} files wait – background reading is off (Settings)',
      _ => '${formatCount(p.done)} of ${formatCount(p.total)} files read',
    };

    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: off ? 0.05 : 0.09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(filter.icon, size: 20, color: off ? cs.onSurfaceVariant.withValues(alpha: 0.6) : cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(filter.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: off ? cs.onSurfaceVariant : cs.onSurface,
                      )),
                ),
                const SizedBox(width: 8),
                _StatePill(state: state, fraction: p.fraction),
              ]),
              const SizedBox(height: 4),
              Text(_subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
              if (state == _State.indexing) ...[
                const SizedBox(height: 10),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: p.fraction),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOut,
                  builder: (_, v, __) => ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 4,
                      color: cs.primary,
                      backgroundColor: cs.primary.withValues(alpha: 0.10),
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.state, required this.fraction});
  final _State state;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = (fraction * 100).floor().clamp(0, 99);
    final (label, fg, bg, border) = switch (state) {
      _State.ready => ('Ready', _green, _green.withValues(alpha: 0.12), null),
      _State.indexing => ('Indexing · $pct%', cs.primary, cs.primary.withValues(alpha: 0.11), null),
      _State.queued => ('Queued', cs.onSurfaceVariant, cs.surfaceContainerHighest, null),
      _State.paused => ('Paused', cs.onSurfaceVariant, cs.surfaceContainerHighest, null),
      _State.off => ('Off', cs.onSurfaceVariant.withValues(alpha: 0.8), Colors.transparent, cs.outlineVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: fg,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
    );
  }
}
