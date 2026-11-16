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
    expect(engine.search('receipt').hits.single.file.path, image.path);
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
    expect(engine.search('galaxy').hits.single.file.path, arb.path);
    expect(engine.search('compile').hits.single.file.path, mk.path);
    expect(store.files[blob.path]!.content, isEmpty);
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
    final paths = engine.search('wild things', exact: true).hits.map((h) => h.file.path).toSet();
    expect(paths, {img.path, named.path});
    expect(engine.search('wild things', exact: true).hits.first.file.path, img.path);
    expect(engine.search('wild things').hits.length, greaterThan(2)); // smart mode still broad
    expect(engine.find('wild things').exact, isTrue);
    expect(engine.find('wild things').hits.length, 2);
    // Nothing unrelated: typos and partial-word lookalikes give no results.
    expect(engine.find('wyld thinggs').hits, isEmpty);
    expect(engine.find('wil things ').hits, isEmpty);
    // The word being typed can be unfinished.
    expect(engine.find('wild th').hits.map((h) => h.file.path).toSet(), {img.path, named.path});
    expect(engine.find('wild th').hits.firstWhere((h) => h.file.path == img.path).snippet, contains('WILD'));
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
    final hits = engine.search('wild things').hits;
    expect(hits.first.file.path, img.path);
    expect(hits.first.snippet, isNotNull);
  });
}

class _FakeOcrEngine implements OcrEngine {
  @override
  String get name => 'Test OCR';

  @override
  int get parallelism => 1;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> recognize(String path) async => 'receipt total 42';
}
