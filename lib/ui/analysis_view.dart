import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/indexer.dart';
import 'format.dart';

const _indigo = Color(0xFF4F5BFF);
const _violet = Color(0xFF9B5CFF);
const _green = Color(0xFF22B573);

/// Live view of a time-boxed analysis: countdown ring, step tracker, live counters, summary.
class AnalysisView extends StatefulWidget {
  const AnalysisView({super.key, required this.start, required this.onContinue, this.previous, this.footnote});

  final Future<IndexSummary> Function(void Function(IndexProgress) onProgress) start;
  final VoidCallback onContinue;

  /// Timings from before this run (last search visit), shown in the timer card.
  final TimingSnapshot? previous;

  /// Replaces the default line under the running analysis.
  final String? footnote;

  @override
  State<AnalysisView> createState() => _AnalysisViewState();
}

class _AnalysisViewState extends State<AnalysisView> {
  final _clock = Stopwatch()..start();
  IndexProgress? _p;
  IndexSummary? _summary;
  Object? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
    widget.start((p) {
      if (mounted) setState(() => _p = p);
    }).then((s) {
      _finish();
      if (mounted) setState(() => _summary = s);
    }).catchError((Object e) {
      _finish();
      if (mounted) setState(() => _error = e);
    });
  }

  void _finish() {
    _ticker?.cancel();
    _clock.stop();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _error != null
        ? _ErrorBody(error: _error!, onContinue: widget.onContinue)
        : _summary != null
            ? _DoneBody(summary: _summary!, previous: widget.previous, onContinue: widget.onContinue)
            : _RunningBody(progress: _p, elapsed: _clock.elapsed, footnote: widget.footnote);
    return _Backdrop(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _Card(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (c, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: c),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ running

class _RunningBody extends StatelessWidget {
  const _RunningBody({required this.progress, required this.elapsed, this.footnote});
  final IndexProgress? progress;
  final Duration elapsed;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final p = progress;
    final reading = p?.phase == IndexPhase.analysing || p?.phase == IndexPhase.done;
    final toRead = (p?.analysed ?? 0) + (p?.remaining ?? 0);
    final frac = !reading || toRead == 0 ? 0.0 : (p!.analysed / toRead).clamp(0.0, 1.0);
    final video = p?.current != null && _isVideo(p!.current!);
    final step = switch (p?.phase) {
      IndexPhase.analysing => 1,
      IndexPhase.done => 2,
      _ => 0,
    };
    final headline = switch (step) {
      0 => 'Finding your files',
      1 when video => 'Watching videos',
      1 => 'Reading documents & images',
      _ => 'Wrapping up',
    };

    return Column(
      key: const ValueKey('running'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _Ring(
          value: frac,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              reading ? '${(frac * 100).floor()}%' : formatCount(p?.found ?? 0),
              style: tt.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              reading ? '${formatCount(p?.remaining ?? 0)} left to read' : 'files found',
              style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(height: 26),
        Text(headline, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        const SizedBox(height: 10),
        _Pill(
          icon: Icons.timer_outlined,
          text: 'Indexing time  ${formatSeconds(elapsed)}',
        ),
        const SizedBox(height: 8),
        Text(
          'Everything stays on this device',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _Steps(active: step),
        const SizedBox(height: 24),
        Row(children: [
          _Stat(icon: Icons.folder_copy_outlined, label: 'Files found', value: p?.found ?? 0),
          const SizedBox(width: 10),
          _Stat(icon: Icons.menu_book_outlined, label: 'Read inside', value: p?.analysed ?? 0),
          const SizedBox(width: 10),
          _Stat(
            icon: Icons.speed_rounded,
            label: 'Files / sec',
            value: (p?.filesPerSecond ?? 0).round(),
          ),
        ]),
        const SizedBox(height: 16),
        _CurrentFile(path: p?.current),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.info_outline_rounded, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              footnote ?? 'Search opens by itself once your documents and images are read. Videos are read in the background.',
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ]),
      ],
    );
  }
}

const _videoExts = {'mp4', 'mov', 'mkv', 'avi', 'wmv', 'm4v', 'webm', '3gp'};
bool _isVideo(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && _videoExts.contains(path.substring(dot + 1).toLowerCase());
}

/// Gradient progress ring.
class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.child});
  final double value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 196,
      height: 196,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value),
        duration: const Duration(milliseconds: 200),
        builder: (_, v, __) => CustomPaint(
          painter: _RingPainter(v, Theme.of(context).colorScheme.surfaceContainerHigh),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.track);
  final double value;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2 + 6);
    // soft glow behind the ring
    canvas.drawCircle(
      rect.center,
      arcRect.width / 2,
      Paint()
        ..color = _indigo.withValues(alpha: 0.06)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    canvas.drawArc(
      arcRect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    final sweep = math.pi * 2 * value;
    canvas.drawArc(
      arcRect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 2,
          colors: const [_indigo, _violet, _indigo],
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(arcRect),
    );
    // knob at the end of the arc
    final a = -math.pi / 2 + sweep;
    final knob = arcRect.center + Offset(math.cos(a), math.sin(a)) * (arcRect.width / 2);
    canvas.drawCircle(knob, stroke / 2 + 3, Paint()..color = Colors.white);
    canvas.drawCircle(knob, stroke / 2 - 1, Paint()..color = _violet);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.track != track;
}

/// "Find files → Read contents → Ready" tracker.
class _Steps extends StatelessWidget {
  const _Steps({required this.active});
  final int active;

  @override
  Widget build(BuildContext context) {
    const labels = ['Find files', 'Read contents', 'Ready'];
    final children = <Widget>[];
    for (var i = 0; i < labels.length; i++) {
      if (i > 0) {
        children.add(Expanded(
          child: Container(
            height: 2,
            margin: const EdgeInsets.only(bottom: 22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: i <= active
                  ? const LinearGradient(colors: [_indigo, _violet])
                  : null,
              color: i <= active ? null : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ));
      }
      children.add(_StepDot(label: labels[i], state: i < active ? 2 : (i == active ? 1 : 0)));
    }
    return Row(children: children);
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({required this.label, required this.state}); // 0 todo, 1 active, 2 done
  final String label;
  final int state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final Widget dot = switch (state) {
      2 => Container(
          width: 26,
          height: 26,
          decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
        ),
      1 => Container(
          width: 26,
          height: 26,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _indigo.withValues(alpha: 0.12),
            border: Border.all(color: _indigo, width: 1.5),
          ),
          child: const CircularProgressIndicator(strokeWidth: 2, color: _indigo),
        ),
      _ => Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surfaceContainerLow,
            border: Border.all(color: cs.outlineVariant, width: 1.5),
          ),
        ),
    };
    return SizedBox(
      width: 96,
      child: Column(children: [
        dot,
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: tt.labelMedium?.copyWith(
            fontWeight: state == 1 ? FontWeight.w700 : FontWeight.w500,
            color: state == 0 ? cs.onSurfaceVariant : cs.onSurface,
          ),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: _indigo),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(end: value.toDouble()),
            duration: const Duration(milliseconds: 400),
            builder: (_, v, __) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatCount(v.round()),
                style: tt.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          Text(label, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _CurrentFile extends StatelessWidget {
  const _CurrentFile({required this.path});
  final String? path;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.description_outlined, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            path == null ? 'Preparing…' : friendlyPath(path!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontFamily: 'monospace', fontSize: 11.5),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ done

/// Everything is read: shows the summary briefly, then opens Search by itself.
class _DoneBody extends StatefulWidget {
  const _DoneBody({required this.summary, required this.onContinue, this.previous});
  final IndexSummary summary;
  final TimingSnapshot? previous;
  final VoidCallback onContinue;

  @override
  State<_DoneBody> createState() => _DoneBodyState();
}

class _DoneBodyState extends State<_DoneBody> {
  static const _autoOpen = 5;
  int _left = _autoOpen;
  Timer? _timer;
  bool _went = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) _go();
    });
  }

  void _go() {
    if (_went) return;
    _went = true;
    _timer?.cancel();
    widget.onContinue();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final previous = widget.previous;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final secs = (summary.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: const Duration(milliseconds: 500),
          curve: Curves.elasticOut,
          builder: (_, s, child) => Transform.scale(scale: s, child: child),
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [_indigo, _violet],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [BoxShadow(color: _indigo.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 8))],
            ),
            child: const Icon(Icons.check_rounded, size: 44, color: Colors.white),
          ),
        ),
        const SizedBox(height: 20),
        Text('Ready to search', style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        const SizedBox(height: 6),
        Text('Documents and images read in $secs seconds', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 24),
        const _Steps(active: 3),
        const SizedBox(height: 22),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.3,
          children: [
            _SummaryTile(Icons.search_rounded, formatCount(summary.found), 'Files searchable'),
            _SummaryTile(Icons.menu_book_outlined, formatCount(summary.analysed), 'Read inside'),
            _SummaryTile(Icons.speed_rounded, summary.filesPerSecond.toStringAsFixed(0), 'Files per second'),
            _SummaryTile(Icons.timer_outlined, formatSeconds(summary.elapsed), 'Indexing time'),
          ],
        ),
        const SizedBox(height: 12),
        _TimerCard(indexTime: summary.elapsed, previous: previous),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: _go,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text('Start searching  ·  opens in $_left s'),
            style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile(this.icon, this.value, this.label);
  final IconData icon;
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: _indigo.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: _indigo),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

/// Indexing time of this run, plus how the last Search visit went: how long the user was
/// on the Search screen before a search began, and how long that search took.
class _TimerCard extends StatelessWidget {
  const _TimerCard({required this.indexTime, this.previous});
  final Duration indexTime;
  final TimingSnapshot? previous;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final wait = previous?.waitBeforeSearch;
    final took = previous?.searchTook;
    Widget row(IconData icon, String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(icon, size: 16, color: _indigo),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
            Text(value,
                style: tt.labelLarge?.copyWith(
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ]),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: _indigo.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _indigo.withValues(alpha: 0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('TIMER',
            style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        row(Icons.timer_outlined, 'Indexing time', formatSeconds(indexTime), strong: true),
        if (wait != null) ...[
          row(Icons.hourglass_top_rounded, 'Last visit: Search screen → search began', formatSeconds(wait)),
          if (took != null) row(Icons.bolt_rounded, 'Last visit: search took', formatMillis(took)),
        ] else
          row(Icons.hourglass_top_rounded, 'Search screen → search began', 'timed on Search'),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: _indigo.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: _indigo),
        const SizedBox(width: 6),
        Text(text,
            style: tt.labelMedium?.copyWith(
              color: _indigo,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ]),
    );
  }
}

// ------------------------------------------------------------------ error

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onContinue});
  final Object error;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(key: const ValueKey('error'), mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: cs.errorContainer, shape: BoxShape.circle),
        child: Icon(Icons.priority_high_rounded, size: 38, color: cs.error),
      ),
      const SizedBox(height: 16),
      Text('Analysis stopped early', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('$error', textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(height: 22),
      SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton(onPressed: onContinue, child: const Text('Continue anyway')),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ shell

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(color: _indigo.withValues(alpha: 0.08), blurRadius: 40, offset: const Offset(0, 16)),
        ],
      ),
      child: child,
    );
  }
}

/// Soft indigo/violet wash behind the card.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF1F2FF), Color(0xFFF7F8FA), Color(0xFFF6F0FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SizedBox.expand(child: child),
    );
  }
}
