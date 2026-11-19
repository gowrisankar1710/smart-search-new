import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/services/recent_searches.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('recent'));
  tearDown(() => dir.delete(recursive: true));

  RecentSearches make() => RecentSearches(max: 3, dir: () async => dir);

  test('newest first, repeats moved to the top, at most max kept', () {
    final r = make()
      ..add('invoice')
      ..add('  rent   receipt ')
      ..add('Invoice')
      ..add('x') // too short
      ..add('saree')
      ..add('बिल');
    expect(r.items, ['बिल', 'saree', 'Invoice']);
    r.remove('saree');
    expect(r.items, ['बिल', 'Invoice']);
  });

  test('kept across restarts', () async {
    final a = make()
      ..add('invoice')
      ..add('rent receipt');
    await a.flush();
    final b = make();
    await b.load();
    expect(b.items, ['rent receipt', 'invoice']);
    b.clear();
    await b.flush();
    final c = make();
    await c.load();
    expect(c.items, isEmpty);
  });
}
