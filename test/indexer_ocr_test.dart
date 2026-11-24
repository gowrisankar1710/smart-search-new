import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/services/index_store.dart';
import 'package:smart_file_search/services/indexer.dart';
import 'package:smart_file_search/services/locations.dart';
import 'package:smart_file_search/services/ocr_service.dart';
import 'package:smart_file_search/services/search_engine.dart';

void main() {
  test('OCR indexes searchable text from a small image', () async {
    final directory = await Directory.systemTemp.createTemp('ocr_test');
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/small.png');
    await image.writeAsBytes([1, 2, 3]);

    final store = IndexStore();
    final engine = SearchEngine();
    final indexer = Indexer(store, engine, _FakeOcrEngine());

    await indexer.run(
      roots: [ScanRoot(directory.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
    );

    expect(store.files[image.path]?.status, IndexStatus.indexed);
    expect(store.files[image.path]?.source, ContentSource.ocr);
    expect(engine.find('receipt').hits.single.file.path, image.path);
  });

  test('PDF without a text layer is read with OCR', () async {
    final dir = await Directory.systemTemp.createTemp('scan_pdf');
    addTearDown(() => dir.delete(recursive: true));
    final pdf = File('${dir.path}/GC100.pdf')..writeAsBytesSync([37, 80, 68, 70, 0, 1, 2, 3]); // no text layer
    final store = IndexStore();
    final engine = SearchEngine();
    await Indexer(store, engine, _FakeOcrEngine()).run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
    );
    final f = store.files[pdf.path]!;
    expect(f.status, IndexStatus.indexed);
    expect(f.source, ContentSource.ocr);
    expect(engine.find('receipt total').hits.single.file.path, pdf.path);
  });

  test('quick pass leaves large files for the background run, which reads them', () async {
    final dir = await Directory.systemTemp.createTemp('quick_pass');
    addTearDown(() => dir.delete(recursive: true));
    final small = File('${dir.path}/small.png')..writeAsBytesSync([1, 2, 3]);
    final big = File('${dir.path}/huge.png')..writeAsBytesSync(List.filled((8 << 20) + 1, 7));
    final store = IndexStore();
    final engine = SearchEngine();
    final indexer = Indexer(store, engine, _FakeOcrEngine());

    final quick = await indexer.run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
      quick: true,
    );
    expect(store.files[small.path]!.status, IndexStatus.indexed);
    expect(store.files[big.path]!.status, IndexStatus.pending);
    expect(quick.remaining, 0); // the Timer screen isn't held up by it
    expect(quick.deferred, 1);

    final progress = <IndexProgress>[];
    await indexer.run(roots: const [], skipPaths: const [], scan: false, onProgress: progress.add);
    expect(store.files[big.path]!.status, IndexStatus.indexed);
    expect(progress.last.fraction, 1);
  });

  test('a budgeted pass stops on time with many files; the background run reads the rest', () async {
    final dir = await Directory.systemTemp.createTemp('budget_pass');
    addTearDown(() => dir.delete(recursive: true));
    for (var i = 0; i < 400; i++) {
      File('${dir.path}/note_$i.txt').writeAsStringSync('meeting notes $i');
      File('${dir.path}/scan_$i.png').writeAsBytesSync([1, 2, 3]);
    }
    final store = IndexStore();
    final engine = SearchEngine();
    final indexer = Indexer(store, engine, _FakeOcrEngine(delay: const Duration(milliseconds: 20)));

    final sw = Stopwatch()..start();
    final quick = await indexer.run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
      budget: const Duration(seconds: 3),
      videos: false,
      quick: true,
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 4))); // the limit is hard
    expect(quick.found, 800);
    expect(quick.scanComplete, isTrue);
    expect(quick.hitTimeLimit, isTrue); // 400 images at 20 ms each can't fit in 3 s
    expect(quick.remaining, greaterThan(0));

    await indexer.run(roots: const [], skipPaths: const [], scan: false, onProgress: (_) {});
    expect(store.files.values.where((f) => f.isPending), isEmpty);
  });

  test('every file ends up read: unknown text formats sniffed, binaries settled', () async {
    final dir = await Directory.systemTemp.createTemp('sniff_test');
    addTearDown(() => dir.delete(recursive: true));
    final arb = File('${dir.path}/app_en.arb')..writeAsStringSync('{"title": "Galaxy launcher"}');
    final mk = File('${dir.path}/Makefile')..writeAsStringSync('build: compile everything');
    final blob = File('${dir.path}/data.weird')..writeAsBytesSync([0, 1, 2, 0, 255, 3]);
    File('${dir.path}/song.mp3').writeAsBytesSync([0, 1]);

    final store = IndexStore();
    final engine = SearchEngine();
    await Indexer(store, engine, _FakeOcrEngine()).run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
    );

    expect(store.files.values.where((f) => f.isPending), isEmpty);
    expect(engine.find('galaxy').hits.single.file.path, arb.path);
    expect(engine.find('compile').hits.single.file.path, mk.path);
    expect(store.files[blob.path]!.content, isEmpty);
  });

  test('results list images first, then videos, then documents, then the rest', () {
    final engine = SearchEngine();
    IndexedFile mk(String path, String text) => IndexedFile(path: path, size: 1, modifiedMs: 0)
      ..content = text
      ..source = ContentSource.text
      ..status = IndexStatus.indexed;
    // Each is a stronger match than the next (name + content beats content only).
    for (final f in [
      mk('/x/invoice notes.txt', 'invoice'),
      mk('/x/invoice.pdf', 'invoice'),
      mk('/x/scan.png', 'invoice'),
      mk('/x/report.docx', 'invoice total'),
      IndexedFile(path: '/x/call.mp4', size: 1, modifiedMs: 0)
        ..segments = const [VideoSegment(12, 'the invoice is due')]
        ..source = ContentSource.video
        ..status = IndexStatus.indexed,
    ]) {
      engine.upsert(f);
    }
    final order = engine.find('invoice').hits.map((h) => h.file.path.split('/').last).toList();
    expect(order.take(2), ['scan.png', 'call.mp4']);
    expect(order.indexOf('call.mp4'), lessThan(order.indexOf('invoice.pdf')));
    expect(order.indexOf('invoice.pdf'), lessThan(order.indexOf('invoice notes.txt')));
    expect(order.indexOf('report.docx'), lessThan(order.indexOf('invoice notes.txt')));
  });

  test('exact mode lists only files containing the exact words', () {
    final engine = SearchEngine();
    IndexedFile mk(String path, String text, [ContentSource src = ContentSource.text]) =>
        IndexedFile(path: path, size: 1, modifiedMs: 0)
          ..content = text
          ..source = src
          ..status = IndexStatus.indexed;
    final img = mk('/x/shot.png', 'Where the WILD\nThings are', ContentSource.ocr);
    final named = mk('/x/Wild-Things-poster.pdf', '');
    final loose = mk('/x/notes.txt', 'wild animals and other things');
    final typo = mk('/x/other.txt', 'wyld thing');
    final folder = mk('/wild things/readme.txt', 'nothing here');
    for (final f in [img, named, loose, typo, folder]) {
      engine.upsert(f);
    }
    Set<String> paths(String q) => engine.find(q).hits.map((h) => h.file.path).toSet();
    expect(paths('wild things'), {img.path, named.path});
    // Plain text: case doesn't matter, and the text may sit inside a word.
    expect(paths('WILD THINGS'), {img.path, named.path});
    expect(paths('ild thin'), {img.path, named.path});
    expect(paths('poster'), {named.path});
    expect(paths('oster'), {named.path});
    // Nothing unrelated: typos give no results.
    expect(paths('wyld thinggs'), isEmpty);
    expect(paths('wild animals'), {loose.path});
    expect(paths('wild th'), {img.path, named.path});
    expect(engine.find('wild th').hits.firstWhere((h) => h.file.path == img.path).snippet, contains('WILD'));
  });

  test('multi-word phrases are found even among thousands of single-word matches', () {
    final engine = SearchEngine();
    IndexedFile doc(String path, String text, int ms) => IndexedFile(path: path, size: 1, modifiedMs: ms)
      ..content = text
      ..source = ContentSource.text
      ..status = IndexStatus.indexed;
    // 5,000 newer files that each contain only one of the words.
    for (var i = 0; i < 5000; i++) {
      engine.upsert(doc('/n/d$i.txt', i.isEven ? 'many years ago, filler $i' : 'chapter 100 filler $i', 1000000 + i));
    }
    final target = doc('/old/history.txt', 'The company celebrated 100 Years of service.', 1);
    final pdfGlued = doc('/old/scan.pdf', 'celebrating 100years together', 1);
    final wrapped = doc('/old/wrap.txt', 'over the last 100\nyears we grew', 1);
    for (final f in [target, pdfGlued, wrapped]) {
      engine.upsert(f);
    }
    final paths = engine.find('100 years').hits.map((h) => h.file.path).toSet();
    expect(paths, {target.path, pdfGlued.path, wrapped.path});
    expect(engine.find('celebrated 100 years of').hits.single.file.path, target.path);
    expect(engine.find('100 years of service').hits.single.file.path, target.path);
    expect(engine.find('100 year').hits.length, 3); // last word still being typed
    expect(engine.find('100 months').hits, isEmpty);
  });

  test('phrase split across OCR lines ranks the image first', () {
    final engine = SearchEngine();
    final img = IndexedFile(path: '/x/shot.png', size: 1, modifiedMs: 0)
      ..content = 'Where the Wild\nThings are'
      ..source = ContentSource.ocr
      ..status = IndexStatus.indexed;
    final doc = IndexedFile(path: '/x/notes.txt', size: 1, modifiedMs: 0)
      ..content = 'wild animals and other things'
      ..source = ContentSource.text
      ..status = IndexStatus.indexed;
    engine.upsert(doc);
    engine.upsert(img);
    final hits = engine.find('wild things').hits;
    expect(hits.first.file.path, img.path);
    expect(hits.first.snippet, isNotNull);
  });
}

class _FakeOcrEngine implements OcrEngine {
  _FakeOcrEngine({this.delay = Duration.zero});
  final Duration delay;

  @override
  String get name => 'Test OCR';

  @override
  int get parallelism => 1;

  @override
  bool get readsPdf => true;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> recognize(String path) async => 'receipt total 42';

  @override
  Future<ImageReading> analyzeImage(String path) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return const ImageReading('receipt total 42', [ImageLabel('document', 0.9)]);
  }
}
