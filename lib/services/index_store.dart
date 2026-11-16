import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/indexed_file.dart';

/// Persists the index (metadata + extracted text) as gzipped JSON in app support storage.
class IndexStore {
  final Map<String, IndexedFile> files = {};
  final List<String> extraRoots = [];
  bool initialDone = false;
  bool backgroundEnabled = true;
  int ocrVersion = 0;
  DateTime? lastRun;

  File? _file;
  Future<void> _saving = Future.value();

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File(p.join(dir.path, 'smart_index_v1.json.gz'));
    if (!await _file!.exists()) return;
    try {
      final data = await compute(_decode, await _file!.readAsBytes());
      initialDone = data['initialDone'] as bool? ?? false;
      backgroundEnabled = data['bg'] as bool? ?? true;
      ocrVersion = data['ocr'] as int? ?? 0;
      final last = data['last'] as int?;
      lastRun = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
      extraRoots
        ..clear()
        ..addAll(((data['extra'] as List?) ?? const []).cast<String>());
      for (final j in (data['files'] as List).cast<Map<String, dynamic>>()) {
        final f = IndexedFile.fromJson(j);
        files[f.path] = f;
      }
    } catch (_) {
      files.clear(); // corrupt index → start fresh
    }
  }

  /// Saves are serialised so two never overlap.
  Future<void> save() {
    _saving = _saving.then((_) => _write()).catchError((Object _) {});
    return _saving;
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    final payload = <String, Object?>{
      'v': 1,
      'initialDone': initialDone,
      'bg': backgroundEnabled,
      'ocr': ocrVersion,
      'last': lastRun?.millisecondsSinceEpoch,
      'extra': List<String>.of(extraRoots),
      'files': [for (final f in files.values) f.toJson()],
    };
    final bytes = await compute(_encode, payload);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }
}

Map<String, dynamic> _decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;

List<int> _encode(Map<String, Object?> payload) => gzip.encode(utf8.encode(jsonEncode(payload)));
