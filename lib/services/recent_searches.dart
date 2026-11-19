import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The last searches the user made, newest first. Kept in a small file of its own –
/// not in the index, so clearing or rebuilding the index keeps them.
class RecentSearches extends ChangeNotifier {
  RecentSearches({this.max = 10, Future<Directory> Function()? dir})
      : _dir = dir ?? getApplicationSupportDirectory;

  final int max;
  final Future<Directory> Function() _dir;
  File? _file;
  Future<void> _writing = Future.value();

  List<String> _items = const [];
  List<String> get items => _items;

  /// Reads the saved list. Cheap (a few hundred bytes); a missing or broken file is an
  /// empty list.
  Future<void> load() async {
    try {
      final f = _file ??= File(p.join((await _dir()).path, 'recent_searches.json'));
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString());
      if (list is List) {
        _items = [for (final q in list) if (q is String && q.trim().isNotEmpty) q.trim()].take(max).toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Puts [query] first. The same search typed differently ("Invoice " / "invoice")
  /// is kept once, as last typed.
  void add(String query) {
    final q = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (q.length < 2) return;
    if (_items.isNotEmpty && _items.first == q) return;
    final key = q.toLowerCase();
    _items = [q, ..._items.where((e) => e.toLowerCase() != key)].take(max).toList();
    _changed();
  }

  void remove(String query) {
    final before = _items.length;
    _items = _items.where((e) => e != query).toList();
    if (_items.length != before) _changed();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items = const [];
    _changed();
  }

  void _changed() {
    notifyListeners();
    final snapshot = jsonEncode(_items);
    // One write at a time, in order; the screen never waits for it.
    _writing = _writing.then((_) async {
      try {
        final f = _file ??= File(p.join((await _dir()).path, 'recent_searches.json'));
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }

  /// Finishes pending writes (tests, quitting).
  Future<void> flush() => _writing;
}
