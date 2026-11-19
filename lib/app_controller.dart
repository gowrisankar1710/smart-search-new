import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
import 'services/permissions.dart';
import 'services/recent_searches.dart';
import 'services/search_engine.dart';
import 'services/video_service.dart';

class IndexStats {
  const IndexStats(this.total, this.read, this.pending, this.failed);
  final int total, read, pending, failed;
}

/// Files of one category and how many of them still wait to be read.
class CategoryCount {
  int total = 0;
  int left = 0;
  int get read => total - left;
  bool get done => left == 0;
}

/// A file that appeared on disk while the app was open.
class RecentAdd {
  RecentAdd(this.path, this.category, this.at);
  final String path;

  /// Documents / images / videos; null for files known by name only (archives, audio…).
  final FileCategory? category;
  final DateTime at;
  String get name => p.basename(path);
  FileKind get kind => kindForExt(extensionOf(path));
}

/// Per sidebar category (by file kind): files with something inside to read, how many
/// still wait, and how far the one being read has got – the Search screen's cards.
class KindProgress {
  int total = 0;
  int left = 0;

  /// Part of a file read so far (a video being watched), 0–1.
  double partial = 0;
  int get done => total - left;
  double get fraction => total == 0 ? 1 : ((done + partial) / total).clamp(0.0, 1.0);
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
  final recent = RecentSearches();

  bool ready = false;
  List<ScanRoot> roots = const [];
  IndexProgress? backgroundProgress;

  /// After start: (files loaded, total) while the saved text inside files is loaded into
  /// the search index. Names are searchable already. Null once loaded.
  (int, int)? contentLoading;
  Timer? _autoScanTimer;

  /// Bumped whenever a run finishes, so open searches can refresh.
  int revision = 0;
  DateTime _lastNotify = DateTime(2000);
  DateTime _lastAutoScan = DateTime(2000);

  /// Background reading stays gentle – a quarter of the cores for documents and for
  /// pictures, but at least two of each (one each made a big first index take hours on
  /// 4-core PCs). Picture reading runs at low priority in the OS engines, and the UI
  /// thread only receives results, so typing stays smooth. The first analysis, which
  /// the user waits for, uses more.
  static final int _bgWorkers = (Platform.numberOfProcessors ~/ 4).clamp(2, 3);
  static final int _bgOcrLanes = (Platform.numberOfProcessors ~/ 4).clamp(2, 3);

  bool get needsOnboarding => !store.initialDone;

  Future<void> init() async {
    unawaited(recent.load()); // tiny file, read alongside the index – never waited for
    await store.load();
    _upgradeOcr();
    _requeueSniffable();
    _upgradeContent();
    _skipBigVideos();
    _dropWrongWindowsPaths();
    unawaited(_checkSpeech());
    unawaited(_checkEngines());
    roots = await Locations.roots(store.extraRoots);
    // The app opens once names are searchable; the text inside files loads in after.
    var lastLoadNotify = DateTime(2000);
    await engine.rebuild(
      store.files.values,
      onNamesReady: () {
        ready = true;
        notifyListeners();
      },
      onContent: (done, total) {
        contentLoading = done < total ? (done, total) : null;
        final now = DateTime.now();
        if (now.difference(lastLoadNotify).inMilliseconds > 500) {
          lastLoadNotify = now;
          revision++; // open searches pick up the text loaded so far
          notifyListeners();
        }
      },
    );
    contentLoading = null;
    revision++;
    notifyListeners();
    if (!needsOnboarding) {
      _rewatch();
      startBackground();
      unawaited(askSystemPermissions()); // speech, if it could never be asked before
    }
    // The first full re-scan after start waits a minute (see kFirstRescanDelay).
    final every = watcher.active ? kWatchedRescanInterval : kAutoScanInterval;
    _lastAutoScan = DateTime.now().subtract(every).add(kFirstRescanDelay);
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

  /// Videos over 50 MB that an older version queued are found by name only now.
  /// Windows: older versions listed drive C: as "C:\\Users\…", which slipped past the
  /// skip list – the profile was indexed a second time under that spelling, along with
  /// AppData, Windows and Program Files. Those entries go; the next scan keeps only the
  /// right ones (most already exist under the normal spelling, already read).
  void _dropWrongWindowsPaths() {
    if (!Platform.isWindows) return;
    final skip = [for (final s in Locations.skipPaths()) '${s.toLowerCase()}\\'];
    bool skipped(String path) {
      final lower = path.toLowerCase();
      return skip.any(lower.startsWith);
    }

    final wrong = [
      for (final path in store.files.keys)
        if (cleanPath(path) != path || skipped(path)) path,
    ];
    for (final path in wrong) {
      store.files.remove(path);
    }
    if (wrong.isNotEmpty) store.dirty = true;
  }

  void _skipBigVideos() {
    for (final f in store.files.values) {
      if (f.status == IndexStatus.pending && isVideoCandidate(f.ext) && !isReadableVideo(f.ext, f.size)) {
        f.status = IndexStatus.nameOnly;
        store.dirty = true;
      }
    }
  }

  /// Re-read files an older extractor cut short. They stay searchable meanwhile.
  void _upgradeContent() {
    if (store.contentVersion >= kContentVersion) return;
    const reread = {'pdf', 'xlsx', 'xlsm', 'ods'};
    for (final f in store.files.values) {
      if (isVideoCandidate(f.ext)) {
        if (!isReadableVideo(f.ext, f.size)) continue; // over 50 MB: by name only
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
    // Hindi and Tamil: scanned PDFs are read again (images follow kOcrVersion).
    if (store.contentVersion < (Platform.isWindows ? 9 : 6)) {
      for (final f in store.files.values) {
        if (f.ext == 'pdf' && f.source == ContentSource.ocr && f.status == IndexStatus.indexed) {
          f.status = IndexStatus.pending;
        }
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
    if (!ready || contentLoading != null || !store.initialDone || indexer.isRunning || roots.isEmpty) {
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
          ocrReaders: _bgOcrLanes,
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

  static const _window = MethodChannel('smart_file_search/window');

  /// The app is quitting: the window disappears at once, background reading stops,
  /// and the index is saved only if something changed since the last save – usually
  /// nothing has (runs save every minute), so the app is gone right away.
  Future<void> prepareToQuit() async {
    try {
      await _window.invokeMethod<void>('hide');
    } catch (_) {}
    if (!ready) return;
    // Reading a scanned PDF can take a while to stop – don't wait for it.
    await indexer.cancel().timeout(const Duration(seconds: 2), onTimeout: () {});
    if (store.dirty) await store.save();
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
    final goneFolders = <String>{};
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
      if (!(hasExtractableText(f.ext) || isOcrCandidate(f.ext) || isReadableVideo(f.ext, f.size))) {
        f.status = IndexStatus.nameOnly;
      }
      if (old == null) {
        _recentAdds
          ..removeWhere((a) => a.path == path)
          ..insert(0, RecentAdd(path, categoryOf(f.ext), now));
        if (_recentAdds.length > 200) _recentAdds.removeLast();
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
          // Deleted or moved away – a file, or a whole folder of them (checked below,
          // all at once: Windows creates and deletes temporary files all the time).
          if (store.files.remove(path) != null) {
            engine.remove(path);
            changed = true;
          } else {
            goneFolders.add(path);
          }
        default:
          break;
      }
    }
    if (goneFolders.isNotEmpty) {
      // In slices, so typing never waits on a pass over a large index.
      final keys = List.of(store.files.keys);
      final gone = <String>[];
      for (var i = 0; i < keys.length; i++) {
        if (_insideAny(goneFolders, keys[i])) gone.add(keys[i]);
        if (i % 4000 == 3999) await Future<void>.delayed(Duration.zero);
      }
      for (final k in gone) {
        if (store.files.remove(k) == null) continue;
        engine.remove(k);
        changed = true;
      }
    }
    if (!changed) return;
    store.dirty = true;

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

  /// Is [path] inside one of [folders]? A walk up its parent folders: one pass over the
  /// index for a whole batch of deletions, instead of one pass per deleted path.
  static bool _insideAny(Set<String> folders, String path) {
    var i = path.lastIndexOf(p.separator);
    while (i > 0) {
      if (folders.contains(path.substring(0, i))) return true;
      i = path.lastIndexOf(p.separator, i - 1);
    }
    return false;
  }

  final List<RecentAdd> _recentAdds = [];

  /// The sidebar marks categories holding new files for this long.
  static const _recentWindow = Duration(minutes: 10);

  /// The line under the search field names a new file for this long.
  static const _announceWindow = Duration(minutes: 2);

  /// Files added in the last few minutes, newest first.
  List<RecentAdd> get recentAdds {
    final now = DateTime.now();
    _recentAdds.removeWhere((a) => now.difference(a.at) > _recentWindow || !store.files.containsKey(a.path));
    return List.unmodifiable(_recentAdds);
  }

  /// New documents, images and videos from the last couple of minutes, for the line
  /// under the search field.
  List<RecentAdd> get freshAdds {
    final now = DateTime.now();
    return [
      for (final a in recentAdds)
        if (a.category != null && now.difference(a.at) <= _announceWindow) a,
    ];
  }

  /// True once a recently added file's content is searchable (or it holds none).
  bool isRead(String path) => !(store.files[path]?.isPending ?? false);

  final Map<String, (DateTime, Map<FileCategory, CategoryCount>)> _categories = {};

  /// Per category: how many files there are and how many still wait to be read –
  /// everywhere, or only under [within] (the folders a Timer run reads).
  Map<FileCategory, CategoryCount> categories({List<ScanRoot>? within}) {
    final key = within == null ? '' : within.map((r) => r.path).join('|');
    final now = DateTime.now();
    final cached = _categories[key];
    if (cached != null && now.difference(cached.$1) < const Duration(milliseconds: 700)) return cached.$2;
    final out = {for (final c in FileCategory.values) c: CategoryCount()};
    // Plain prefix test: this runs over every file several times a second.
    final prefixes = within?.map((r) => r.path.endsWith(p.separator) ? r.path : r.path + p.separator).toList();
    for (final f in store.files.values) {
      final cat = categoryOf(f.ext);
      if (cat == null) continue;
      if (prefixes != null && !prefixes.any(f.path.startsWith)) continue;
      final c = out[cat]!;
      c.total++;
      if (f.isPending) c.left++;
    }
    _categories[key] = (now, out);
    return out;
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
  /// every document and image up to [quickReadBytes] before returning, so Search opens
  /// with them searchable. Larger files, videos (minutes each) and whole drives follow
  /// in the background.
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
      quick: true, // large files follow in the background, smallest first
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

  /// macOS: brings up the system prompts for the personal folders, then for speech
  /// recognition (what is said in videos), one after another – at the start, instead of
  /// popping up in the middle of the analysis. Folders are asked once; speech whenever
  /// macOS has never asked (a run started from an editor couldn't ask before).
  Future<void> askSystemPermissions() async {
    if (!hasSystemPrompts) return;
    if (!store.permissionsAsked) {
      for (final r in personalRoots.where((r) => !r.userAdded)) {
        await requestFolderAccess([r.path]);
      }
    }
    var speechGranted = false;
    if (await speechAccess() == SpeechAccess.notAsked) speechGranted = await requestSpeechAccess();
    permissionsAnswered(speechGranted: speechGranted);
  }

  /// Speech recognition is allowed, so what is said in videos is read too (macOS).
  bool speechInVideos = false;

  /// What this device can read, found out once at start.
  bool ocrAvailable = true, ocrNative = true, videoMedia = true;

  Future<void> _checkEngines() async {
    ocrAvailable = await ocr.isAvailable();
    ocrNative = ocr.readsPdf; // the OS's own engine: reads scanned PDFs and classifies photos
    videoMedia = await video.readsMedia();
    notifyListeners();
  }

  (DateTime, Map<FileKind, KindProgress>)? _kinds;

  /// True while a run is reading file contents (not just walking folders).
  bool get readingContents => backgroundProgress != null && indexer.isRunning;

  /// Per file kind: files whose contents are read, and how many still wait.
  Map<FileKind, KindProgress> kindProgress() {
    final now = DateTime.now();
    if (_kinds != null && now.difference(_kinds!.$1) < const Duration(milliseconds: 700)) return _kinds!.$2;
    final out = {for (final k in FileKind.values) k: KindProgress()};
    for (final f in store.files.values) {
      if (f.status == IndexStatus.nameOnly) continue; // nothing inside to read
      final k = out[f.kind]!;
      k.total++;
      if (f.isPending) k.left++;
    }
    final pr = backgroundProgress;
    if (pr?.video != null) out[FileKind.video]!.partial = pr!.videoFraction;
    _kinds = (now, out);
    return out;
  }

  Future<void> _checkSpeech() async => speechInVideos = await speechAccess() == SpeechAccess.granted;

  /// The system prompts were answered. The first time speech is allowed, videos read
  /// without it are read again so what is said in them becomes searchable – once only:
  /// macOS may ask again (a rebuilt development copy counts as a new app), and saying
  /// yes again must not mean reading every video again.
  void permissionsAnswered({required bool speechGranted}) {
    store.permissionsAsked = true;
    if (speechGranted) speechInVideos = true;
    if (speechGranted && !store.speechVideos) {
      store.speechVideos = true;
      for (final f in store.files.values) {
        if (isReadableVideo(f.ext, f.size) && f.status != IndexStatus.pending) f.status = IndexStatus.pending;
      }
      if (store.initialDone) startBackground();
    }
    unawaited(store.save());
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
          ocrReaders: _bgOcrLanes,
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
