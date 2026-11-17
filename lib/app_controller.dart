import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'core/constants.dart';
import 'core/file_types.dart';
import 'core/indexed_file.dart';
import 'services/index_store.dart';
import 'services/file_scan.dart';
import 'services/folder_watcher.dart';
import 'services/indexer.dart';
import 'services/locations.dart';
import 'services/ocr_service.dart';
import 'services/search_engine.dart';
import 'services/video_service.dart';

class IndexStats {
  const IndexStats(this.total, this.read, this.pending, this.failed);
  final int total, read, pending, failed;
}

/// The numbers shown by the Search screen's timing strip and the Timer screen.
class TimingSnapshot {
  const TimingSnapshot({this.indexTime, this.indexAt, this.waitBeforeSearch, this.searchTook});

  /// Duration of the last time-boxed indexing pass.
  final Duration? indexTime;
  final DateTime? indexAt;

  /// From opening the Search screen until the first search began.
  final Duration? waitBeforeSearch;

  /// How long that first search took.
  final Duration? searchTook;

  /// Indexing + waiting on the Search screen: how long until searching actually started.
  Duration? get untilSearch =>
      indexTime == null || waitBeforeSearch == null ? null : indexTime! + waitBeforeSearch!;
}

class AppController extends ChangeNotifier {
  final store = IndexStore();
  final engine = SearchEngine();
  final OcrEngine ocr = createOcrEngine();
  final VideoAnalyzer video = createVideoAnalyzer();
  late final Indexer indexer = Indexer(store, engine, ocr, video: video);
  late final FolderWatcher watcher = FolderWatcher(onChanges: _onDiskChanges);

  bool ready = false;
  List<ScanRoot> roots = const [];
  IndexProgress? backgroundProgress;
  Timer? _autoScanTimer;

  /// Bumped whenever a run finishes, so open searches can refresh.
  int revision = 0;
  DateTime _lastNotify = DateTime(2000);
  DateTime _lastAutoScan = DateTime(2000);

  /// Background reading uses half the CPU cores (2–4), leaving the rest for the user.
  static final int _bgWorkers = (Platform.numberOfProcessors ~/ 2).clamp(2, 4);

  bool get needsOnboarding => !store.initialDone;

  Future<void> init() async {
    await store.load();
    _upgradeOcr();
    _requeueSniffable();
    _upgradeContent();
    roots = await Locations.roots(store.extraRoots);
    await engine.rebuild(store.files.values);
    ready = true;
    notifyListeners();
    if (!needsOnboarding) {
      _rewatch();
      startBackground();
    }
    _autoScanTimer ??=
        Timer.periodic(const Duration(seconds: 3), (_) => _autoScan());
  }

  /// When the OCR engine improves, queue every image to be read again.
  /// What was already read stays searchable until the new reading replaces it.
  void _upgradeOcr() {
    if (store.ocrVersion >= kOcrVersion) return;
    for (final f in store.files.values) {
      if (!isOcrCandidate(f.ext)) continue;
      f.status = IndexStatus.pending;
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

  /// Re-read files an older extractor cut short. They stay searchable meanwhile.
  void _upgradeContent() {
    if (store.contentVersion >= kContentVersion) return;
    const reread = {'pdf', 'xlsx', 'xlsm', 'ods'};
    for (final f in store.files.values) {
      if (isVideoCandidate(f.ext)) {
        // v4: read what videos show and say. v5: again, with per-word speech timing.
        // Already-read text stays searchable until the new reading replaces it.
        if (f.status != IndexStatus.pending) f.status = IndexStatus.pending;
        continue;
      }
      if (f.status != IndexStatus.indexed || f.source != ContentSource.text) continue;
      if (store.contentVersion < 2 && (reread.contains(f.ext) || f.content.length >= 39000)) {
        f.status = IndexStatus.pending;
      } else if (f.ext == 'pdf' && f.content.trim().length < 20) {
        // v3: PDF with no text layer → read its pages with OCR.
        f
          ..source = ContentSource.ocr
          ..status = IndexStatus.pending;
      }
    }
    store.contentVersion = kContentVersion;
    unawaited(store.save());
  }

  /// Reading shorter than this (a file or two saved) isn't worth a status change.
  static const _quietReading = Duration(seconds: 3);

  /// Should the UI say files are being read? Not for a run that's only just started –
  /// a couple of changed files are read in well under a second and would only flicker.
  bool get showReading {
    final bg = backgroundProgress;
    if (bg != null) return bg.remaining > 0 && bg.elapsed >= _quietReading;
    // Nothing running: only say so when files really wait (background reading turned off).
    return !store.backgroundEnabled && stats.pending > 0;
  }

  void _onProgress(IndexProgress pr) {
    backgroundProgress = pr.phase == IndexPhase.done ? null : pr;
    if (_fresh.isNotEmpty) {
      final read = _fresh.where((f) => !f.isPending).toList();
      if (read.isNotEmpty) {
        _fresh.removeAll(read);
        revision++; // a just-added file was read – show it in open searches
      }
    }
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
    // Watched folders report new files at once; the full disk walk is then only a safety net.
    final every = watcher.active ? kWatchedRescanInterval : kAutoScanInterval;
    final scanDue = now.difference(_lastAutoScan) >= every;
    if (!hasWork && !scanDue) return;
    if (scanDue) _lastAutoScan = now;
    unawaited(() async {
      try {
        await indexer.run(
          roots: roots,
          skipPaths: Locations.skipPaths(),
          scan: scanDue,
          analyze: readFiles,
          maxWorkers: _bgWorkers,
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
    if (watcher.active) _rewatch();
    notifyListeners();
  }

  // ------------------------------------------------------------------ live folder watching

  void _rewatch() => watcher.watch([for (final r in roots) r.path], Locations.skipPaths());

  /// Files added/changed while a run is reading; when one finishes, open searches refresh.
  final Set<IndexedFile> _fresh = {};

  /// When the watcher last queued each file. A file that keeps changing (a log being
  /// written, a document autosaving) is re-read at most this often; the periodic
  /// full scan catches its final state.
  final Map<String, DateTime> _lastQueued = {};
  static const _hotFileGap = Duration(minutes: 2);
  Timer? _saveSoon;

  /// Something changed on disk: index new/changed files by name right away and have
  /// their contents read now; forget files that are gone.
  Future<void> _onDiskChanges(Set<String> paths) async {
    if (!ready) return;
    final toRead = <IndexedFile>[];
    var changed = false;

    final now = DateTime.now();
    _lastQueued.removeWhere((_, t) => now.difference(t) > _hotFileGap);

    void addFile(String path, FileStat st) {
      final ms = st.modified.millisecondsSinceEpoch;
      final old = store.files[path];
      if (old != null && old.size == st.size && old.modifiedMs == ms) return;
      if (old != null && _lastQueued.containsKey(path)) return; // changing again and again – later
      _lastQueued[path] = now;
      final f = IndexedFile(path: path, size: st.size, modifiedMs: ms);
      if (!(hasExtractableText(f.ext) || isOcrCandidate(f.ext) || isVideoCandidate(f.ext))) {
        f.status = IndexStatus.nameOnly;
      }
      store.files[path] = f;
      engine.upsert(f, contentTf: const {});
      changed = true;
      if (f.isPending) toRead.add(f);
    }

    for (final path in paths) {
      final FileStat st;
      try {
        st = await FileStat.stat(path);
      } catch (_) {
        continue;
      }
      switch (st.type) {
        case FileSystemEntityType.file:
          addFile(path, st);
        case FileSystemEntityType.directory:
          // A folder copied or moved in: everything inside is new.
          final root = roots.where((r) => p.isWithin(r.path, path)).firstOrNull;
          if (root == null) continue;
          try {
            await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
              if (e is File && isScannablePath(e.path, root.path)) addFile(e.path, await e.stat());
            }
          } catch (_) {}
        case FileSystemEntityType.notFound:
          // Deleted or moved away – a file, or a whole folder of them.
          final gone = store.files.containsKey(path)
              ? [path]
              : store.files.keys.where((k) => p.isWithin(path, k)).toList();
          for (final k in gone) {
            store.files.remove(k);
            engine.remove(k);
            changed = true;
          }
        default:
          break;
      }
    }
    if (!changed) return;

    var needRun = false;
    for (final f in toRead) {
      if (indexer.enqueue(f)) {
        _fresh.add(f);
      } else {
        needRun = true;
      }
    }
    if (needRun && !indexer.isRunning && store.initialDone) startBackground();

    revision++; // names are searchable already – refresh open searches
    _saveSoon ??= Timer(const Duration(seconds: 20), () {
      _saveSoon = null;
      unawaited(store.save());
    });
    notifyListeners();
  }

  IndexStats? _stats;
  DateTime _statsAt = DateTime(2000);

  /// Counting 100k+ files on every repaint is wasteful – refresh at most once a second.
  IndexStats get stats {
    final now = DateTime.now();
    if (_stats != null && now.difference(_statsAt) < const Duration(seconds: 1)) return _stats!;
    _statsAt = now;
    return _stats = _computeStats();
  }

  IndexStats _computeStats() {
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

  /// Personal folders (Desktop, Documents, Downloads, Pictures, Videos, Music, OneDrive,
  /// folders the user added) – what the Timer screen waits for.
  List<ScanRoot> get personalRoots => [for (final r in roots) if (!r.wholeDrive) r];

  /// Whole drives are read in the background after Search opens.
  bool get hasWholeDrives => roots.any((r) => r.wholeDrive);

  /// A full analysis of the personal folders (or [only]): finds every file and reads
  /// every document and image before returning, so Search opens with them searchable.
  /// Videos (minutes each) and whole drives follow in the background.
  /// Used on first launch, for re-analysis and new folders.
  Future<IndexSummary> analyse(
      {required void Function(IndexProgress) onProgress,
      List<ScanRoot>? only}) async {
    await indexer.cancel();
    backgroundProgress = null;
    _rewatch(); // the user has started: files added while this runs join it
    final summary = await indexer.run(
      roots: only ?? personalRoots,
      skipPaths: Locations.skipPaths(),
      onProgress: onProgress,
      videos: false,
    );
    // Drives next: the background scan starts as soon as Search is open.
    if (only == null && hasWholeDrives) _lastAutoScan = DateTime(2000);
    store
      ..lastIndexTime = summary.elapsed
      ..lastIndexAt = DateTime.now();
    revision++;
    notifyListeners();
    unawaited(store.save());
    if (store.initialDone) startBackground(); // videos (first launch: completeOnboarding)
    return summary;
  }

  // ------------------------------------------------------------------ search timing

  final Stopwatch _onSearchScreen = Stopwatch();
  bool _searchBegan = false;

  /// Time since the Search screen was (re)entered, frozen once a search begins.
  Duration get searchScreenElapsed => _onSearchScreen.elapsed;

  /// True while the user is on the Search screen and hasn't started a search yet.
  bool get waitingForSearch => _onSearchScreen.isRunning;

  TimingSnapshot get timing => TimingSnapshot(
        indexTime: store.lastIndexTime,
        indexAt: store.lastIndexAt,
        waitBeforeSearch: store.lastWaitBeforeSearch,
        searchTook: store.lastSearchTook,
      );

  /// Call when the Search screen appears – or reappears after a Timer screen closes.
  void enterSearchScreen() {
    _onSearchScreen
      ..reset()
      ..start();
    _searchBegan = false;
    notifyListeners();
  }

  /// The first search of this visit is starting: freeze the "time until search" clock.
  void searchBegan() {
    if (_searchBegan) return;
    _searchBegan = true;
    _onSearchScreen.stop();
    store.lastWaitBeforeSearch = _onSearchScreen.elapsed;
    store.lastSearchTook = null;
    notifyListeners();
  }

  /// The first search of this visit finished.
  void searchFinished(Duration took) {
    if (!_searchBegan || store.lastSearchTook != null) return;
    store.lastSearchTook = took;
    unawaited(store.save());
    notifyListeners();
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
          maxWorkers: _bgWorkers,
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
    if (watcher.active) _rewatch();
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
    if (watcher.active) _rewatch();
    revision++;
    unawaited(store.save());
    notifyListeners();
    startBackground();
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    _saveSoon?.cancel();
    watcher.stop();
    super.dispose();
  }
}
