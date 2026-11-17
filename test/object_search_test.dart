import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/core/object_terms.dart';
import 'package:smart_file_search/services/search_engine.dart';

IndexedFile photo(String path, List<(String, double)> labels, {String text = ''}) =>
    IndexedFile(path: path, size: 1, modifiedMs: 0)
      ..content = text
      ..labels = [for (final (id, c) in labels) ImageLabel(id, c)]
      ..source = ContentSource.ocr
      ..status = IndexStatus.indexed;

void main() {
  final sari = photo('/p/IMG_001.jpg', [('people', .93), ('adult', .93), ('sari', .81), ('clothing', .6)]);
  final birds = photo('/p/IMG_002.jpg', [('outdoor', .9), ('bird', .88), ('rocks', .7)]);
  final rocks = photo('/p/IMG_003.jpg', [('rocks', .83), ('sky', .92), ('blue_sky', .92)]);
  final gown = photo('/p/IMG_004.jpg', [('people', .9), ('wedding_dress', .77), ('gown', .6)]);
  final faint = photo('/p/IMG_005.jpg', [('bird', .58)]);
  final notes = IndexedFile(path: '/d/notes.txt', size: 1, modifiedMs: 0)
    ..content = 'we saw a bird today'
    ..source = ContentSource.text
    ..status = IndexStatus.indexed;
  final engine = SearchEngine();
  for (final f in [sari, birds, rocks, gown, faint, notes]) {
    engine.upsert(f);
  }
  Set<String> paths(String q) => engine.find(q).hits.map((h) => h.file.path).toSet();

  test('saree finds the picture of a sari – any spelling, singular or plural', () {
    for (final q in ['saree', 'sarees', 'sari', 'Saree photo']) {
      expect(paths(q), {sari.path}, reason: q);
    }
    final hit = engine.find('saree').hits.single;
    expect(hit.sources, {MatchSource.objects});
    expect(hit.objects.single.id, 'sari');
  });

  test('every thing named must be in the picture', () {
    expect(paths('woman wearing saree'), {sari.path});
    expect(paths('birds on stones'), {birds.path});
    expect(paths('stone'), {birds.path, rocks.path});
    expect(paths('birds in sky'), isEmpty); // no picture has both
  });

  test('dress finds dress-like garments: gowns, wedding dresses, saris', () {
    expect(paths('dress'), {gown.path, sari.path});
    expect(paths('wedding dress'), {gown.path});
  });

  test('text matches come first; surer pictures rank higher', () {
    final hits = engine.find('bird').hits.map((h) => h.file.path).toList();
    expect(hits, [notes.path, birds.path, faint.path]);
  });

  test('labels are saved with the index', () {
    final back = IndexedFile.fromJson(Map<String, dynamic>.from(sari.toJson()));
    expect(back.labels.map((l) => l.id), ['people', 'adult', 'sari', 'clothing']);
    final e = SearchEngine()..upsert(back);
    expect(e.find('saree').hits.single.file.path, sari.path);
  });

  test('removing or re-reading a picture updates object search', () {
    final e = SearchEngine()..upsert(photo('/x/a.jpg', [('bird', .9)]));
    expect(e.find('bird').hits, hasLength(1));
    e.upsert(photo('/x/a.jpg', [('cat', .9)]));
    expect(e.find('bird').hits, isEmpty);
    expect(e.find('cat').hits, hasLength(1));
    e.remove('/x/a.jpg');
    expect(e.find('cat').hits, isEmpty);
  });

  test('every alias points at a label the macOS classifier knows', () {
    // Saved from VNClassifyImageRequest.supportedIdentifiers() on macOS (1,303 labels).
    final f = File('test/fixtures/vision_labels.txt');
    if (!f.existsSync()) return;
    final words = <String>{};
    for (final l in f.readAsLinesSync()) {
      words.addAll(labelWords(l.trim()));
    }
    expect(aliasTargets.where((t) => !words.contains(t)).toSet(), isEmpty);
  });
}
