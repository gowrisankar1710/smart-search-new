import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/imagenet_labels.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/core/object_terms.dart';
import 'package:smart_file_search/services/ocr_service.dart';
import 'package:smart_file_search/services/search_engine.dart';

Map<String, double> labels(List<(int, double)> top) =>
    {for (final l in labelsFromImagenet(top)) l.id: l.confidence};

void main() {
  test('class ids line up with the model (spot checks)', () {
    expect(imagenetNames, hasLength(1000));
    expect(imagenetNames[291], 'lion');
    expect(imagenetNames[404], 'airliner');
    expect(imagenetNames[614], 'kimono');
    expect(imagenetNames[972], 'cliff');
  });

  test('saree photo (model says kimono / overskirt) → sari, dress, clothing, people', () {
    // From a real saree photo: kimono 0.93, overskirt 0.47.
    final l = labels([(614, 0.93), (689, 0.47), (578, 0.12)]);
    expect(l['sari'], greaterThan(0.5));
    expect(l['dress'], 1.0);
    expect(l['clothing'], 1.0);
    expect(l['people'], greaterThan(0.5));
    expect(l['kimono'], 0.93);
  });

  test('bird species add up to a sure "bird"', () {
    final l = labels([(13, 0.12), (14, 0.11), (15, 0.10), (88, 0.09), (130, 0.08)]);
    expect(l['bird'], closeTo(0.50, 1e-9));
    expect(l.containsKey('junco'), isFalse); // each species alone is unsure
  });

  test('abstract backgrounds do not become animals', () {
    // Real app background: nematode 0.67, jellyfish 0.25.
    final l = labels([(111, 0.67), (107, 0.25)]);
    expect(l.containsKey('animal'), isFalse);
    expect(l['nematode'], 0.67); // the raw guess stays, but nobody searches it
  });

  test('a class named like a category is not counted twice', () {
    final l = labels([(578, 0.40), (400, 0.10)]); // gown + academic gown
    expect(l['gown'], closeTo(0.50, 1e-9));
    expect(l['clothing'], closeTo(0.50, 1e-9));
  });

  test('scenery maps onto the Mac search words', () {
    expect(labels([(972, 0.69), (976, 0.29)])['rocks'], closeTo(0.98, 1e-9));
    expect(labels([(404, 0.98)])['airplane'], 0.98);
    expect(labels([(963, 0.6)])['food'], 0.6);
  });

  test('Windows labels from the native side are searchable like Mac ones', () {
    final ls = parseNativeLabels([
      ['imagenet:614', 0.93],
      ['imagenet:689', 0.47],
    ]);
    final f = IndexedFile(path: r'C:\Users\a\Pictures\saree.jpg', size: 1, modifiedMs: 0)
      ..labels = ls
      ..source = ContentSource.ocr
      ..status = IndexStatus.indexed;
    final e = SearchEngine()..upsert(f);
    for (final q in ['saree', 'woman wearing saree', 'dress', 'kimono']) {
      expect(e.find(q).hits, hasLength(1), reason: q);
    }
    // Mac labels pass straight through.
    expect(parseNativeLabels([['sari', 0.9]]).single.id, 'sari');
  });

  test('every Windows category word is one the search vocabulary reaches', () {
    final cats = <String>{
      for (var i = 0; i < 1000; i++) ...imagenetCategories(i),
      'sari', 'people', 'fruit', 'vegetable', 'food',
    };
    // Each category is reachable by typing it (aliases or the word itself).
    for (final c in cats) {
      expect(objectKeys(c).isNotEmpty, isTrue, reason: c);
    }
  });
}
