import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/indexed_file.dart';
import '../services/search_engine.dart';
import '../core/object_terms.dart';
import '../services/video_service.dart';
import 'format.dart';
import 'result_tile.dart';
import 'theme.dart';
import 'video_player_view.dart';

const _previewable = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// Right-hand panel: preview + details of the selected result, or index overview.
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key, required this.hit, required this.controller});
  final SearchHit? hit;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: cs.outlineVariant)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: hit == null
            ? _Overview(controller: controller, key: const ValueKey('overview'))
            : _FileDetails(hit: hit!, key: ValueKey(hit!.file.path)),
      ),
    );
  }
}

class _FileDetails extends StatelessWidget {
  const _FileDetails({super.key, required this.hit});
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final f = hit.file;
    final moment = hit.firstMoment;
    final excerpt = moment != null ? null : _excerpt(f, hit);
    final hiStyle = TextStyle(backgroundColor: const Color(0xFFFFE58A), color: cs.onSurface, fontWeight: FontWeight.w600);
    final where = [
      if (hit.sources.contains(MatchSource.name)) 'File name',
      if (hit.sources.contains(MatchSource.content)) 'Text inside the file',
      if (hit.sources.contains(MatchSource.imageText)) 'Text in the image',
      if (hit.sources.contains(MatchSource.videoContent)) 'What the video shows or says',
      if (hit.sources.contains(MatchSource.objects)) 'What the picture shows',
      if (hit.sources.contains(MatchSource.folder)) 'Folder name',
    ];

    return ListView(padding: const EdgeInsets.all(20), children: [
      _Preview(file: f),
      const SizedBox(height: 18),
      Text(f.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
      const SizedBox(height: 4),
      Text(friendlyPath(f.folder), style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: moment != null
              ? FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: Text('Play from ${formatTimestamp(moment.at)}'),
                  onPressed: () => playVideoAt(context, hit, moment),
                )
              : FilledButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open'),
                  onPressed: () => openFile(context, f.path),
                ),
        ),
        const SizedBox(width: 8),
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
          _SquareButton(
            tooltip: Platform.isMacOS ? 'Show in Finder' : 'Show in folder',
            icon: Icons.folder_open_rounded,
            onPressed: () => revealInFolder(f.path),
          ),
        const SizedBox(width: 8),
        _SquareButton(
          tooltip: 'Copy file location',
          icon: Icons.link_rounded,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: f.path));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location copied')));
          },
        ),
      ]),
      const SizedBox(height: 22),
      _Section('Details'),
      _InfoRow('Kind', _kindName(f)),
      _InfoRow('Size', formatBytes(f.size)),
      _InfoRow('Modified', formatDate(f.modified)),
      if (where.isNotEmpty) _InfoRow('Matched in', where.join(', ')),
      if (f.labels.isNotEmpty) ...[
        const SizedBox(height: 18),
        _Section('Seen in this picture'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final l in f.labels)
            Tooltip(
              message: '${(l.confidence * 100).round()}% sure',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: hit.objects.any((o) => o.id == l.id) ? const Color(0xFFFFE58A) : cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(labelName(l.id),
                    style: tt.labelMedium?.copyWith(
                      fontWeight: hit.objects.any((o) => o.id == l.id) ? FontWeight.w700 : FontWeight.w500,
                    )),
              ),
            ),
        ]),
      ],
      if (hit.moments.isNotEmpty) ...[
        const SizedBox(height: 18),
        _Section(hit.moments.length == 1 ? 'Moment in the video' : '${hit.moments.length} moments in the video'),
        for (final m in hit.moments)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: cs.surface,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => playVideoAt(context, hit, m),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.play_circle_fill_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 50,
                      child: Text(formatTimestamp(m.at),
                          style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: cs.primary)),
                    ),
                    Expanded(
                      child: Text.rich(
                        highlightSpan(m.text.replaceAll('\n', ' · '), hit.highlights,
                            tt.bodySmall!.copyWith(height: 1.45), hiStyle),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ],
      if (excerpt != null) ...[
        const SizedBox(height: 18),
        _Section(f.source == ContentSource.ocr ? 'Text found in image' : 'Matching text'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: SelectableText.rich(
            highlightSpan(excerpt, hit.highlights, tt.bodySmall!.copyWith(height: 1.55), hiStyle),
          ),
        ),
      ],
    ]);
  }

  static String _kindName(IndexedFile f) {
    final k = f.kind.name;
    final ext = f.ext.isEmpty ? '' : ' · .${f.ext.toUpperCase()}';
    return '${k[0].toUpperCase()}${k.substring(1)}$ext';
  }

  /// ~700 characters of the file's text around the first match.
  static String? _excerpt(IndexedFile f, SearchHit hit) {
    if (f.content.isEmpty) return null;
    final lower = f.contentLower;
    var at = -1;
    for (final n in hit.highlights.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      final i = lower.indexOf(n);
      if (i >= 0 && (at < 0 || i < at)) at = i;
    }
    if (at < 0) {
      if (f.source != ContentSource.ocr) return null;
      at = 0; // images: show what was read even if only the name matched
    }
    final start = max(0, at - 200);
    final end = min(f.content.length, at + 500);
    return '${start > 0 ? '… ' : ''}${f.content.substring(start, end).trim()}${end < f.content.length ? ' …' : ''}';
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.file});
  final IndexedFile file;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kind = file.kind;
    final fallback = Container(
      height: 180,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(child: Icon(kind.icon, size: 56, color: kind.color)),
    );
    if (!_previewable.contains(file.ext) || file.size > 40 << 20) return fallback;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.file(
        File(file.path),
        fit: BoxFit.contain,
        cacheWidth: 900,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = controller.stats;
    final reading = controller.showReading;
    final pct = s.total == 0 || !reading ? 1.0 : s.read / s.total;
    return ListView(padding: const EdgeInsets.all(20), children: [
      _Section('Your index'),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFEEF0FF), Color(0xFFF6EEFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(formatCount(s.total), style: tt.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          Text('files searchable', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: Colors.white,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            !reading ? 'Everything has been read' : '${formatCount(s.pending)} files still being read',
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ]),
      ),
      const SizedBox(height: 22),
      _Section('Tips'),
      const _Tip(Icons.format_quote_rounded, 'Type words exactly as they appear – files containing them are listed first.'),
      const _Tip(Icons.image_search_rounded, 'Text inside screenshots and photos is searchable too.'),
      const _Tip(Icons.center_focus_strong_rounded,
          'Search what a photo shows – “saree”, “birds on stones”, “cake” – even with no text in it.'),
      const _Tip(Icons.smart_display_outlined,
          'Videos too: search what is shown or said, and playback starts at that moment.'),
      const _Tip(Icons.mouse_outlined, 'Click a result to preview it here, double-click to open.'),
      const _Tip(Icons.keyboard_return_rounded, 'Press Enter to open the top result, Esc to clear.'),
    ]);
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: tt.bodySmall?.copyWith(height: 1.45, color: cs.onSurfaceVariant))),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title.toUpperCase(),
          style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 92, child: Text(label, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
        Expanded(child: Text(value, style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500))),
      ]),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero),
        child: Icon(icon, size: 20),
      ),
    );
  }
}
