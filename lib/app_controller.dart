import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'core/constants.dart';
import 'core/file_types.dart';
import 'core/indexed_file.dart';
import 'services/index_store.dart';
import 'services/indexer.dart';
import 'services/locations.dart';
import 'services/ocr_service.dart';
import 'services/search_engine.dart';

class IndexStats {
  const IndexStats(this.total, this.read, this.pending, this.failed);
  final int total, read, pending, failed;
}

class AppController extends ChangeNotifier {
  final store = IndexStore();
  final engine = SearchEngine();
  final OcrEngine ocr = createOcrEngine();
  late final Indexer indexer = Indexer(store, engine, ocr);

  bool ready = false;
  List<ScanRoot> roots = const [];
  IndexProgress? backgroundProgress;
  Timer? _autoScanTimer;

  /// Bumped whenever a run finishes, so open searches can refresh.
  int revision = 0;
  DateTime _lastNotify = DateTime(2000);
  DateTime _lastAutoScan = DateTime(2000);

  bool get needsOnboarding => !store.initialDone;

  Future<void> init() async {
    await store.load();
    _upgradeOcr();
    _requeueSniffable();
    roots = await Locations.roots(store.extraRoots);
    await engine.rebuild(store.files.values);
    ready = true;
    notifyListeners();
    if (!needsOnboarding) startBackground();
    _autoScanTimer ??=
        Timer.periodic(const Duration(seconds: 3), (_) => _autoScan());
  }

  /// When the OCR engine improves, queue every image to be read again.
  void _upgradeOcr() {
    if (store.ocrVersion >= kOcrVersion) return;
    for (final f in store.files.values) {
      if (!isOcrCandidate(f.ext)) continue;
      f
        ..status = IndexStatus.pending
        ..source = ContentSource.none
        ..content = '';
    }
    store.ocrVersion = kOcrVersion;
    unawaited(store.save());
  }

  /// Files skipped by older versions (unknown text formats like .arb, .gn, Makefile)
  /// are queued so their contents become searchable too.
  void _requeueSniffable() {
    for (final f in store.files.values) {
      if (f.status == IndexStatus.nameOnly &&
          hasExtractableText(f.ext) &&
          f.size <= maxExtractBytes(f.ext)) {
        f.status = IndexStatus.pending;
      }
    }
  }

  void _onProgress(IndexProgress pr) {
    backgroundProgress = pr.phase == IndexPhase.done ? null : pr;
    final now = DateTime.now();
    if (pr.phase == IndexPhase.done ||
        now.difference(_lastNotify).inMilliseconds > 1000) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void _autoScan() {
    if (!ready || !store.initialDone || indexer.isRunning || roots.isEmpty) {
      return;
    }
    final readFiles = store.backgroundEnabled;
    final now = DateTime.now();
    final hasWork = readFiles && store.files.values.any((f) => f.isPending);
    if (!hasWork && now.difference(_lastAutoScan) < kAutoScanInterval) return;
    _lastAutoScan = now;
    unawaited(() async {
      try {
        await indexer.run(
          roots: roots,
          skipPaths: Locations.skipPaths(),
          scan: true,
          analyze: readFiles,
          maxWorkers: 1,
          onProgress: (pr) {
            if (pr.phase == IndexPhase.analysing) _onProgress(pr);
          },
        );
      } catch (_) {
      } finally {
        backgroundProgress = null;
        revision++;
        notifyListeners();
        if (store.backgroundEnabled) startBackground();
      }
    }());
  }

  Future<void> refreshRoots() async {
    roots = await Locations.roots(store.extraRoots);
    notifyListeners();
  }

  IndexStats get stats {
    var read = 0, pending = 0, failed = 0;
    for (final f in store.files.values) {
      // "Read" = fully processed: text extracted, or confirmed to hold no text
      // (videos, archives, fonts…). Only files still queued are not counted.
      if (f.isPending) {
        pending++;
      } else {
        read++;
      }
      if (f.status == IndexStatus.failed) failed++;
    }
    return IndexStats(store.files.length, read, pending, failed);
  }

  /// A time-boxed analysis (≤ 60 s). Used on first launch, for re-analysis and new folders.
  Future<IndexSummary> analyse(
      {required void Function(IndexProgress) onProgress,
      List<ScanRoot>? only}) async {
    await indexer.cancel();
    backgroundProgress = null;
    final summary = await indexer.run(
      roots: only ?? roots,
      skipPaths: Locations.skipPaths(),
      budget: kAnalysisBudget,
      onProgress: onProgress,
    );
    revision++;
    notifyListeners();
    return summary;
  }

  void completeOnboarding() {
    store.initialDone = true;
    unawaited(store.save());
    notifyListeners();
    startBackground();
  }

  /// Keeps reading whatever the 1-minute pass deferred, gently (one worker).
  void startBackground() {
    if (!store.backgroundEnabled || indexer.isRunning) return;
    if (!store.files.values.any((f) => f.isPending)) return;
    unawaited(() async {
      try {
        await indexer.run(
          roots: roots,
          skipPaths: const [],
          scan: false,
          maxWorkers: 1,
          onProgress: _onProgress,
        );
      } finally {
        backgroundProgress = null;
        revision++;
        notifyListeners();
      }
    }());
  }

  Future<void> setBackgroundEnabled(bool v) async {
    store.backgroundEnabled = v;
    unawaited(store.save());
    if (v) {
      startBackground();
    } else {
      await indexer.cancel();
      backgroundProgress = null;
    }
    notifyListeners();
  }

  Future<ScanRoot?> pickAndAddFolder() async {
    final path = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose a folder to search');
    if (path == null) return null;
    final n = p.normalize(path);
    if (!store.extraRoots.contains(n)) store.extraRoots.add(n);
    roots = await Locations.roots(store.extraRoots);
    unawaited(store.save());
    notifyListeners();
    for (final r in roots) {
      if (r.path == n) return r;
    }
    return null;
  }

  Future<void> removeFolder(ScanRoot root) async {
    await indexer.cancel();
    store.extraRoots.remove(root.path);
    final stillCovered = (await Locations.roots(store.extraRoots))
        .any((r) => r.path == root.path || p.isWithin(r.path, root.path));
    if (!stillCovered) {
      final gone =
          store.files.keys.where((k) => p.isWithin(root.path, k)).toList();
      for (final k in gone) {
        store.files.remove(k);
        engine.remove(k);
      }
    }
    roots = await Locations.roots(store.extraRoots);
    revision++;
    unawaited(store.save());
    notifyListeners();
    startBackground();
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    super.dispose();
  }
}
