import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/file_types.dart';
import '../core/indexed_file.dart';
import '../core/text_tools.dart';
import 'extract_worker.dart';
import 'file_scan.dart';
import 'index_store.dart';
import 'locations.dart';
import 'ocr_service.dart';
import 'search_engine.dart';

enum IndexPhase { preparing, scanning, analysing, done }

class IndexProgress {
  const IndexProgress({
    required this.phase,
    required this.found,
    required this.analysed,
    required this.remaining,
    required this.elapsed,
    this.budget,
    this.filesPerSecond = 0,
    this.mbPerSecond = 0,
    this.workers = 0,
    this.current,
  });
  final IndexPhase phase;
  final int found;
  final int analysed;
  final int remaining;
  final Duration elapsed;
  final Duration? budget;
  final double filesPerSecond;
  final double mbPerSecond;
  final int workers;
  final String? current;
}

class IndexSummary {
  const IndexSummary({
    required this.found,
    required this.analysed,
    required this.remaining,
    required this.elapsed,
    required this.filesPerSecond,
    required this.hitTimeLimit,
  });
  final int found;
  final int analysed;
  final int remaining;
  final Duration elapsed;
  final double filesPerSecond;
  final bool hitTimeLimit;
}

/// Time-budgeted indexing pipeline.
///
///  1. Discovery (≤ 35 % of the budget, background isolate, breadth-first):
///     every file becomes searchable by name immediately.
///  2. Content reading until the deadline, in priority order (recent & cheap first):
///     • N extractor isolates read PDF / Office / text files in adaptive batches
///     • an OCR lane reads text inside images in parallel
///  3. A speed model (cost-weighted bytes/second, measured live) skips files that
///     can't finish before the deadline – they stay queued for background analysis.
///  4. At the deadline a timer kills every worker: the limit is hard, not best-effort.
class Indexer {
  Indexer(this.store, this.engine, this.ocr);

  final IndexStore store;
  final SearchEngine engine;
  final OcrEngine ocr;

  bool _running = false;
  bool _cancelled = false;
  final List<ExtractWorker> _workers = [];
  FileScan? _scan;
  Completer<void>? _done;

  bool get isRunning => _running;

  Future<void> cancel() async {
    if (!_running) return;
    _cancelled = true;
    _stopAll();
    await _done?.future;
  }

  void _stopAll() {
    _scan?.stop();
    for (final w in List.of(_workers)) {
      w.kill();
    }
  }

  Future<IndexSummary> run({
    required List<ScanRoot> roots,
    required List<String> skipPaths,
    required void Function(IndexProgress) onProgress,
    Duration? budget,
    bool scan = true,
    bool analyze = true,
    int? maxWorkers,
  }) async {
    if (_running) throw StateError('Indexer already running');
    _running = true;
    _cancelled = false;
    _done = Completer<void>();

    final sw = Stopwatch()..start();
    final deadline = budget == null
        ? null
        : DateTime.now().add(budget - const Duration(milliseconds: 400));
    bool timeUp() =>
        _cancelled || (deadline != null && !DateTime.now().isBefore(deadline));
    Duration remainingTime() => deadline == null
        ? const Duration(days: 1)
        : deadline.difference(DateTime.now());
    final killTimer =
        deadline == null ? null : Timer(remainingTime(), _stopAll);
    final saveTimer = deadline == null
        ? Timer.periodic(const Duration(seconds: 30), (_) => store.save())
        : null;

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final nWorkers = maxWorkers ??
        (isMobile ? 2 : (Platform.numberOfProcessors - 1).clamp(1, 6));

    var phase = IndexPhase.preparing;
    var found = store.files.length;
    var analysed = 0;
    var bytesDone = 0;
    var pending = store.files.values.where((f) => f.isPending).length;
    var activeWorkers = 0;
    String? current;
    final analysisClock = Stopwatch();
    var lastEmit = DateTime(2000);

    void emit({bool force = false}) {
      final now = DateTime.now();
      if (!force && now.difference(lastEmit).inMilliseconds < 120) return;
      lastEmit = now;
      final secs = analysisClock.elapsedMilliseconds / 1000;
      onProgress(IndexProgress(
        phase: phase,
        found: found,
        analysed: analysed,
        remaining: max(0, pending),
        elapsed: sw.elapsed,
        budget: budget,
        filesPerSecond: secs > 0.3 ? analysed / secs : 0,
        mbPerSecond: secs > 0.3 ? bytesDone / 1048576 / secs : 0,
        workers: activeWorkers,
        current: current,
      ));
    }

    try {
      // ------------------------------------------------------------ 1. discovery
      if (scan) {
        phase = IndexPhase.scanning;
        emit(force: true);
        final fs = FileScan();
        _scan = fs;
        final scanTimer = budget == null
            ? null
            : Timer(
                Duration(
                    milliseconds: (budget.inMilliseconds * kScanShare).round()),
                fs.stop);
        final seen = <String>{};
        await for (final batch
            in fs.start([for (final r in roots) r.path], skipPaths)) {
          for (var i = 0; i + 2 < batch.length; i += 3) {
            final path = batch[i] as String;
            final size = batch[i + 1] as int;
            final ms = batch[i + 2] as int;
            seen.add(path);
            final old = store.files[path];
            if (old != null && old.size == size && old.modifiedMs == ms)
              continue;
            if (old == null) {
              found++;
            } else if (old.isPending) {
              pending--;
            }
            final f = IndexedFile(path: path, size: size, modifiedMs: ms);
            if (hasExtractableText(f.ext) || isOcrCandidate(f.ext)) {
              pending++;
            } else {
              f.status = IndexStatus.nameOnly;
            }
            store.files[path] = f;
            engine.upsert(f, contentTf: const {});
            current = path;
          }
          emit();
          if (timeUp()) break;
        }
        scanTimer?.cancel();
        // Forget files that were deleted – only when discovery covered everything.
        if (fs.completed && !_cancelled) {
          final rootPaths = [for (final r in roots) r.path];
          final gone = store.files.keys
              .where((k) =>
                  !seen.contains(k) && rootPaths.any((r) => p.isWithin(r, k)))
              .toList();
          for (final k in gone) {
            final f = store.files.remove(k);
            if (f != null && f.isPending) pending--;
            engine.remove(k);
          }
          found = store.files.length;
        }
        _scan = null;
      }

      // ------------------------------------------------------------ 2. content
      if (!timeUp() && analyze) {
        phase = IndexPhase.analysing;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        const recentMs = 180 * 24 * 3600 * 1000;
        double units(IndexedFile f) =>
            f.size * extractionCostFactor(f.ext) + 20000;

        final textQ = store.files.values.where((f) => f.needsText).toList()
          ..sort((a, b) {
            final ra = nowMs - a.modifiedMs < recentMs ? 0 : 1;
            final rb = nowMs - b.modifiedMs < recentMs ? 0 : 1;
            return ra != rb ? ra - rb : units(a).compareTo(units(b));
          });

        final ocrOk = await ocr.isAvailable();
        bool ocrSized(IndexedFile f) => f.size <= 30 * 1024 * 1024;
        if (ocrOk) {
          // Images skipped earlier because OCR was missing get another chance.
          for (final f in store.files.values) {
            if (f.status == IndexStatus.nameOnly &&
                isOcrCandidate(f.ext) &&
                ocrSized(f)) {
              f.status = IndexStatus.pending;
              pending++;
            }
          }
        }
        final ocrQ = <IndexedFile>[];
        for (final f in store.files.values.where((f) => f.needsOcr)) {
          if (ocrOk && ocrSized(f)) {
            ocrQ.add(f);
          } else {
            f.status = IndexStatus.nameOnly;
            pending--;
          }
        }
        ocrQ.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));

        analysisClock.start();
        emit(force: true);

        // Live speed model, refined after every batch.
        var unitsPerSecPerWorker = 3.0 * 1024 * 1024;
        var batchSize = 6;
        var qi = 0;

        List<IndexedFile> takeBatch() {
          final out = <IndexedFile>[];
          while (qi < textQ.length && out.length < batchSize) {
            final f = textQ[qi++];
            if (f.status != IndexStatus.pending) continue;
            if (f.size > maxExtractBytes(f.ext)) {
              f.status = IndexStatus.nameOnly;
              pending--;
              continue;
            }
            if (deadline != null) {
              final estSec = units(f) / unitsPerSecPerWorker;
              if (estSec > remainingTime().inMilliseconds / 1000 * 0.8)
                continue; // defer to background
            }
            out.add(f);
          }
          return out;
        }

        Future<void> textLane(ExtractWorker w) async {
          activeWorkers++;
          try {
            while (!timeUp()) {
              final batch = takeBatch();
              if (batch.isEmpty) return;
              final results = await w.run(ExtractJob(
                [for (final f in batch) f.path],
                [for (final f in batch) f.ext],
                deadline?.millisecondsSinceEpoch ?? 8640000000000000,
              ));
              if (_cancelled && deadline == null) return;
              final byPath = {for (final f in batch) f.path: f};
              var micros = 0;
              var doneUnits = 0.0;
              for (final r in results) {
                final f = byPath[r.path];
                if (f == null) continue;
                micros += r.micros;
                doneUnits += units(f);
                if (r.error != null) {
                  f.status = IndexStatus.failed;
                } else {
                  f
                    ..content = r.text ?? ''
                    ..source = ContentSource.text
                    ..status = IndexStatus.indexed;
                  engine.upsert(f, contentTf: r.termFreq);
                }
                analysed++;
                pending--;
                bytesDone += f.size;
                current = f.path;
              }
              if (micros > 0 && results.isNotEmpty) {
                final speed = doneUnits / (micros / 1e6);
                unitsPerSecPerWorker = unitsPerSecPerWorker * 0.6 + speed * 0.4;
                final perFile = micros / results.length;
                batchSize = (350000 / perFile).round().clamp(1, 48);
              }
              emit();
              if (results.length < batch.length)
                return; // deadline reached inside the worker
            }
          } finally {
            activeWorkers--;
          }
        }

        var oi = 0;
        Future<void> ocrLane() async {
          while (!timeUp() && oi < ocrQ.length) {
            final f = ocrQ[oi++];
            if (f.status != IndexStatus.pending) continue;
            final left = remainingTime();
            if (deadline != null && left < const Duration(milliseconds: 700))
              return;
            current = f.path;
            try {
              final cap = left < const Duration(seconds: 20)
                  ? left
                  : const Duration(seconds: 20);
              final text = await ocr.recognize(f.path).timeout(cap);
              f
                ..content = normalizeContent(text)
                ..source = ContentSource.ocr
                ..status = IndexStatus.indexed;
              engine.upsert(f);
            } on TimeoutException {
              if (timeUp()) return; // ran out of time – leave it queued
              f.status = IndexStatus.failed;
            } catch (_) {
              f.status = IndexStatus.failed;
            }
            analysed++;
            pending--;
            bytesDone += f.size;
            emit();
          }
        }

        if (textQ.isNotEmpty) {
          final spawned = await Future.wait(
              List.generate(nWorkers, (_) => ExtractWorker.spawn()));
          _workers.addAll(spawned);
          if (timeUp()) _stopAll();
        }
        await Future.wait([
          for (final w in List.of(_workers)) textLane(w),
          if (ocrQ.isNotEmpty)
            for (var i = 0; i < ocr.parallelism; i++) ocrLane(),
        ]);
      }
    } finally {
      killTimer?.cancel();
      saveTimer?.cancel();
      _stopAll();
      _workers.clear();
      _scan = null;
      _running = false;
      _done?.complete();
    }

    phase = IndexPhase.done;
    if (analyze) store.lastRun = DateTime.now();
    final left = store.files.values.where((f) => f.isPending).length;
    pending = left;
    final secs = max(0.001, analysisClock.elapsedMilliseconds / 1000);
    emit(force: true);
    unawaited(store
        .save()); // saving happens after the user is already free to search
    return IndexSummary(
      found: store.files.length,
      analysed: analysed,
      remaining: left,
      elapsed: sw.elapsed,
      filesPerSecond: analysed / secs,
      hitTimeLimit: deadline != null && left > 0,
    );
  }
}
