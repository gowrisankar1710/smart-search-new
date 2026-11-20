import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/file_types.dart';
import '../core/indexed_file.dart';
import '../services/search_engine.dart';
import '../services/video_service.dart';
import 'format.dart';
import 'result_tile.dart';
import 'theme.dart';

/// video_player plays files on these platforms; elsewhere the system player is used,
/// which can't be told where to start.
bool get inAppVideo => Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

/// Opens a result. Videos matched by their content start playing at the first matching moment.
Future<void> openHit(BuildContext context, SearchHit hit) {
  final moment = hit.firstMoment;
  if (hit.file.kind == FileKind.video && moment != null) return playVideoAt(context, hit, moment);
  return openFile(context, hit.file.path);
}

/// Plays [hit]'s video from [from].
Future<void> playVideoAt(BuildContext context, SearchHit hit, VideoSegment from) async {
  if (!inAppVideo) {
    // The system player can't be told where to start – say where to look.
    await openFile(context, hit.file.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('The match is at ${formatTimestamp(from.at)} in the video')));
    }
    return;
  }
  await Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    pageBuilder: (_, __, ___) => VideoPlayerView(hit: hit, start: from),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  ));
}

class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({super.key, required this.hit, required this.start});
  final SearchHit hit;
  final VideoSegment start;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  late final VideoPlayerController _video = VideoPlayerController.file(File(widget.hit.file.path));
  late VideoSegment _current = widget.start;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _video.addListener(_tick);
    _video.initialize().then((_) async {
      await _startAt(widget.start.at);
      if (mounted) setState(() {});
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _video
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  Future<void> _jump(VideoSegment m) async {
    setState(() => _current = m);
    await _startAt(m.at);
  }

  /// Plays from [at]. Windows' media engine can drop a seek made just as playback
  /// starts and play from the beginning: if it isn't near [at] a moment later, seek again.
  Future<void> _startAt(Duration at) async {
    await _video.seekTo(at);
    await _video.play();
    if (at < const Duration(seconds: 3)) return;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    final pos = _video.value.position;
    if (pos < at - const Duration(seconds: 3) || pos > at + const Duration(seconds: 10)) {
      await _video.seekTo(at);
    }
  }

  void _toggle() => _video.value.isPlaying ? _video.pause() : _video.play();

  void _skip(int seconds) {
    final v = _video.value;
    var to = v.position + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (to > v.duration) to = v.duration;
    _video.seekTo(to);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hit = widget.hit;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-5),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(5),
      },
      child: Focus(
        autofocus: true,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
                    child: Row(children: [
                      Icon(Icons.movie_rounded, color: cs.primary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(hit.file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('Open in player'),
                        onPressed: () {
                          _video.pause();
                          openFile(context, hit.file.path);
                        },
                      ),
                      IconButton(
                        tooltip: 'Close (Esc)',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ]),
                  ),
                  Flexible(child: _screen(context)),
                  _controls(context),
                  if (hit.moments.isNotEmpty) _momentList(context),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _screen(BuildContext context) {
    final v = _video.value;
    final Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('This video can\'t be played here. Use “Open in player” – '
              'the match is at ${formatTimestamp(_current.at)}.',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
        ),
      );
    } else if (!v.isInitialized) {
      body = const Center(child: CircularProgressIndicator(color: Colors.white));
    } else {
      body = Center(
        child: AspectRatio(
          aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio,
          child: GestureDetector(onTap: _toggle, child: VideoPlayer(_video)),
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: 240, maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: body,
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final v = _video.value;
    final total = v.duration.inMilliseconds;
    final pos = v.position.inMilliseconds.clamp(0, total == 0 ? 0 : total);
    final mono = tt.labelMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 0),
      child: Row(children: [
        IconButton(
          tooltip: 'Back 5 s (←)',
          icon: const Icon(Icons.replay_5_rounded),
          onPressed: v.isInitialized ? () => _skip(-5) : null,
        ),
        IconButton.filled(
          tooltip: v.isPlaying ? 'Pause (Space)' : 'Play (Space)',
          icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
          onPressed: v.isInitialized ? _toggle : null,
        ),
        IconButton(
          tooltip: 'Forward 5 s (→)',
          icon: const Icon(Icons.forward_5_rounded),
          onPressed: v.isInitialized ? () => _skip(5) : null,
        ),
        const SizedBox(width: 8),
        Text(formatTimestamp(v.position), style: mono),
        Expanded(
          child: Stack(alignment: Alignment.center, children: [
            Slider(
              value: total == 0 ? 0 : pos / total,
              onChanged: total == 0
                  ? null
                  : (x) => _video.seekTo(Duration(milliseconds: (x * total).round())),
            ),
            // Ticks where the searched text appears.
            if (total > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(builder: (_, box) {
                    const inset = 24.0; // Slider's horizontal track padding
                    final w = box.maxWidth - inset * 2;
                    return Stack(children: [
                      for (final m in widget.hit.moments)
                        Positioned(
                          left: inset + w * (m.at.inMilliseconds / total).clamp(0.0, 1.0) - 1.5,
                          top: box.maxHeight / 2 - 9,
                          child: Container(
                            width: 3,
                            height: 6,
                            decoration: BoxDecoration(color: const Color(0xFFFFB300), borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                    ]);
                  }),
                ),
              ),
          ]),
        ),
        Text(formatTimestamp(v.duration), style: mono?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _momentList(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hiStyle = TextStyle(backgroundColor: Brand.highlight, color: cs.onSurface, fontWeight: FontWeight.w600);
    final moments = widget.hit.moments;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          moments.length == 1 ? 'MATCH IN THIS VIDEO' : '${moments.length} MATCHING MOMENTS',
          style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: moments.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (_, i) {
              final m = moments[i];
              final sel = identical(m, _current);
              return Material(
                color: sel ? cs.primaryContainer : cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _jump(m),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.play_circle_outline_rounded, size: 16, color: cs.primary),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 56,
                        child: Text(formatTimestamp(m.at),
                            style: tt.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cs.primary,
                                fontFeatures: const [FontFeature.tabularFigures()])),
                      ),
                      Expanded(
                        child: Text.rich(
                          highlightSpan(m.text.replaceAll('\n', ' · '), widget.hit.highlights,
                              tt.bodySmall!.copyWith(height: 1.4), hiStyle),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
