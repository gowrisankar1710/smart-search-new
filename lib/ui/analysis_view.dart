import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/indexer.dart';
import 'format.dart';

/// Live view of a time-boxed analysis: countdown ring, counters, measured speed, summary.
class AnalysisView extends StatefulWidget {
  const AnalysisView({super.key, required this.start, required this.onContinue});

  final Future<IndexSummary> Function(void Function(IndexProgress) onProgress) start;
  final VoidCallback onContinue;

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
            ? _DoneBody(summary: _summary!, onContinue: widget.onContinue)
            : _RunningBody(progress: _p, elapsed: _clock.elapsed);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: child),
        ),
      ),
    );
  }
}

class _RunningBody extends StatelessWidget {
  const _RunningBody({required this.progress, required this.elapsed});
  final IndexProgress? progress;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final budget = kAnalysisBudget;
    final frac = (elapsed.inMilliseconds / budget.inMilliseconds).clamp(0.0, 1.0);
    final left = ((budget - elapsed).inMilliseconds / 1000).ceil().clamp(0, budget.inSeconds);
    final p = progress;
    final phaseText = switch (p?.phase) {
      IndexPhase.scanning => 'Finding your files…',
      IndexPhase.analysing => 'Reading documents and images…',
      IndexPhase.done => 'Wrapping up…',
      _ => 'Getting ready…',
    };

    return Column(
      key: const ValueKey('running'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: frac,
                  strokeWidth: 10,
                  strokeCap: StrokeCap.round,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('$left', style: tt.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: cs.primary)),
                Text('seconds left', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(phaseText, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        Row(children: [
          _Stat(label: 'Files found', value: formatCount(p?.found ?? 0)),
          const SizedBox(width: 10),
          _Stat(label: 'Content read', value: formatCount(p?.analysed ?? 0)),
          const SizedBox(width: 10),
          _Stat(label: 'Speed', value: '${(p?.filesPerSecond ?? 0).toStringAsFixed(0)}/s'),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 18,
          child: Text(
            p?.current == null ? '' : friendlyPath(p!.current!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'This takes 1 minute at most. Anything not finished keeps going quietly in the background.',
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _DoneBody extends StatelessWidget {
  const _DoneBody({required this.summary, required this.onContinue});
  final IndexSummary summary;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
          child: Icon(Icons.check_rounded, size: 48, color: cs.onPrimaryContainer),
        ),
        const SizedBox(height: 20),
        Text('Ready to search', style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Finished in ${(summary.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            _Row('Files searchable by name', formatCount(summary.found)),
            _Row('Contents read this run', formatCount(summary.analysed)),
            _Row('Average speed', '${summary.filesPerSecond.toStringAsFixed(1)} files/s'),
            _Row('Continuing in background', formatCount(summary.remaining)),
          ]),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(onPressed: onContinue, child: const Text('Start searching')),
        ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onContinue});
  final Object error;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.error_outline_rounded, size: 56, color: Theme.of(context).colorScheme.error),
      const SizedBox(height: 12),
      const Text('Analysis stopped early'),
      const SizedBox(height: 8),
      Text('$error', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 20),
      FilledButton(onPressed: onContinue, child: const Text('Continue')),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          FittedBox(child: Text(value, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(height: 2),
          Text(label, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Expanded(child: Text(label, style: tt.bodyMedium)),
        Text(value, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
