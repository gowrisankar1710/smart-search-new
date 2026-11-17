import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/services/file_scan.dart';
import 'package:smart_file_search/services/folder_watcher.dart';
import 'package:smart_file_search/services/index_store.dart';
import 'package:smart_file_search/services/indexer.dart';
import 'package:smart_file_search/services/locations.dart';
import 'package:smart_file_search/services/ocr_service.dart';
import 'package:smart_file_search/services/search_engine.dart';
import 'package:smart_file_search/services/video_service.dart';

void main() {
  test('a file added during a long background run is read in that run', () async {
    final dir = await Directory.systemTemp.createTemp('live_q');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/long.mp4').writeAsBytesSync([0, 0, 0, 1]);

    final store = IndexStore();
    final engine = SearchEngine();
    final slow = _SlowVideo();
    final indexer = Indexer(store, engine, _NoOcr(), video: slow);
    final run = indexer.run(roots: [ScanRoot(dir.path, 't')], skipPaths: const [], onProgress: (_) {});

    await slow.started.future; // the run is busy with the video
    final txt = File('${dir.path}/new.txt')..writeAsStringSync('quarterly zebra report');
    final f = IndexedFile(path: txt.path, size: txt.lengthSync(), modifiedMs: 1);
    store.files[f.path] = f;
    engine.upsert(f, contentTf: const {});
    expect(indexer.enqueue(f), isTrue);

    // Read while the video is still going – not after it.
    for (var i = 0; i < 100 && f.isPending; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(f.status, IndexStatus.indexed);
    expect(slow.finish.isCompleted, isFalse);
    expect(engine.find('zebra').hits.single.file.path, txt.path);

    slow.finish.complete();
    final summary = await run;
    expect(summary.remaining, 0);
    expect(indexer.enqueue(f), isFalse); // nothing running any more
  });

  test('watcher filters match the full scan', () {
    expect(isScannablePath('/r/docs/a.pdf', '/r'), isTrue);
    expect(isScannablePath('/r/.git/config', '/r'), isFalse);
    expect(isScannablePath(r'/r/docs/~$draft.docx', '/r'), isFalse);
    expect(isScannablePath('/r/app/node_modules/x/index.js', '/r'), isFalse);
    expect(isScannablePath('/elsewhere/a.txt', '/r'), isFalse);
    // Files apps rewrite constantly, with nothing to search inside.
    expect(isScannablePath('/r/Music/Music Library.musiclibrary/x/MusicCatalogData.db', '/r'), isFalse);
    expect(isScannablePath('/r/data/MusicCatalogData.db-wal', '/r'), isFalse);
    expect(isScannablePath('/r/data/store.sqlite-shm', '/r'), isFalse);
    expect(isScannablePath('/r/data/app.db-journal', '/r'), isFalse);
    expect(isScannablePath('/r/Downloads/movie.mp4.crdownload', '/r'), isFalse);
    expect(isScannablePath('/r/Apps/Tool.app/Contents/Info.plist', '/r'), isFalse);
    // Real documents are still in.
    expect(isScannablePath('/r/Documents/notes.db.txt', '/r'), isTrue);
    expect(isScannablePath('/r/Pictures/trip.jpg', '/r'), isTrue);
  });

  test('the folder watcher reports new, nested and deleted files',
      skip: FolderWatcher.supported ? false : 'no recursive watching here', () async {
    final dir = await Directory.systemTemp.createTemp('watch');
    final root = dir.resolveSymbolicLinksSync(); // /var → /private/var on macOS
    addTearDown(() => dir.delete(recursive: true));
    final seen = <String>{};
    final w = FolderWatcher(onChanges: seen.addAll)..watch([root], const []);
    addTearDown(w.stop);
    await Future<void>.delayed(const Duration(milliseconds: 500)); // let FSEvents start
    Future<void> waitFor(String path) async {
      for (var i = 0; i < 150 && !seen.contains(path); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final a = File('$root/sub/report.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('hi');
    File('$root/.hidden.txt').writeAsStringSync('x');
    await waitFor(a.path);
    expect(seen, contains(a.path));
    expect(seen.any((s) => s.endsWith('.hidden.txt')), isFalse);

    seen.clear();
    a.deleteSync();
    await waitFor(a.path);
    expect(seen, contains(a.path)); // reported, so the app can forget it
  }, timeout: const Timeout(Duration(seconds: 60)));
}

class _SlowVideo implements VideoAnalyzer {
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  String get name => 'slow';
  @override
  Future<bool> readsMedia() async => true;
  @override
  void cancel() {}
  @override
  Future<List<VideoSegment>> analyze(String path) async {
    if (!started.isCompleted) started.complete();
    await finish.future;
    return const [VideoSegment(1, 'intro')];
  }
}

class _NoOcr implements OcrEngine {
  @override
  String get name => 'none';
  @override
  int get parallelism => 1;
  @override
  bool get readsPdf => false;
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<String> recognize(String path) async => '';
  @override
  Future<ImageReading> analyzeImage(String path) async => const ImageReading('');
}
