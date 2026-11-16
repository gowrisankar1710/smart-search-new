import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../services/search_engine.dart';
import 'format.dart';
import 'theme.dart';

class ResultTile extends StatefulWidget {
  const ResultTile({
    super.key,
    required this.hit,
    this.selected = false,
    this.onSelect,
  });
  final SearchHit hit;
  final bool selected;

  /// Single click selects (shows details); double click opens. Null → click opens.
  final VoidCallback? onSelect;

  @override
  State<ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends State<ResultTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hit = widget.hit;
    final f = hit.file;
    final sel = widget.selected;
    final hiStyle = TextStyle(
      backgroundColor: const Color(0xFFFFE58A),
      color: cs.onSurface,
      fontWeight: FontWeight.w600,
    );
    final inImage = hit.sources.contains(MatchSource.imageText);
    final inFile = hit.sources.contains(MatchSource.content);
    final muted = tt.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: sel ? cs.primaryContainer : (_hover ? Colors.white : Colors.white.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? cs.primary.withValues(alpha: 0.45) : cs.outlineVariant),
            boxShadow: _hover && !sel
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onSelect ?? () => openFile(context, f.path),
              onDoubleTap: widget.onSelect == null ? null : () => openFile(context, f.path),
              onLongPress: () => showActions(context, f.path),
              onSecondaryTap: () => showActions(context, f.path),
              hoverColor: Colors.transparent,
              splashColor: cs.primary.withValues(alpha: 0.06),
              highlightColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _Thumb(hit: hit),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text.rich(
                            highlightSpan(f.name, hit.highlights,
                                tt.bodyLarge!.copyWith(fontWeight: FontWeight.w600, height: 1.25), hiStyle),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(formatDate(f.modified), style: muted),
                      ]),
                      const SizedBox(height: 3),
                      Row(children: [
                        Icon(Icons.folder_outlined, size: 13, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(friendlyPath(f.folder),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                        ),
                        if (inImage || inFile) ...[
                          const SizedBox(width: 8),
                          _MatchLabel(
                            inImage ? 'Text in image' : 'Inside file',
                            inImage ? Icons.image_search_rounded : Icons.notes_rounded,
                          ),
                        ],
                      ]),
                      if (hit.snippet != null) ...[
                        const SizedBox(height: 8),
                        Text.rich(
                          highlightSpan(hit.snippet!, hit.highlights,
                              tt.bodySmall!.copyWith(height: 1.45, color: cs.onSurface.withValues(alpha: 0.72)),
                              hiStyle),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _previewable = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// Real thumbnail for images, a tinted type icon for everything else.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.hit});
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final f = hit.file;
    final kind = f.kind;
    final icon = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(kind.icon, color: kind.color, size: 24),
    );
    if (!_previewable.contains(f.ext) || f.size > 25 << 20) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Image.file(
          File(f.path),
          fit: BoxFit.cover,
          cacheWidth: 120,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => icon,
        ),
      ),
    );
  }
}

class _MatchLabel extends StatelessWidget {
  const _MatchLabel(this.label, this.icon);
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: cs.primary),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary)),
      ]),
    );
  }
}

Future<void> openFile(BuildContext context, String path) async {
  final r = await OpenFilex.open(path);
  if (r.type != ResultType.done && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t open file: ${r.message}')));
  }
}

bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> revealInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,$path']);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [p.dirname(path)]);
  }
}

void showActions(BuildContext context, String path) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(p.basename(path),
              maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        ListTile(
          leading: const Icon(Icons.open_in_new_rounded),
          title: const Text('Open'),
          onTap: () {
            Navigator.pop(ctx);
            openFile(context, path);
          },
        ),
        if (_desktop)
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Show in folder'),
            onTap: () {
              Navigator.pop(ctx);
              revealInFolder(path);
            },
          ),
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('Copy file location'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: path));
            Navigator.pop(ctx);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location copied')));
          },
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}
