import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/indexed_file.dart';

/// Persists the index (metadata + extracted text) as gzipped JSON lines in app support storage.
class IndexStore {
  final Map<String, IndexedFile> files = {};
  final List<String> extraRoots = [];
  bool initialDone = false;
  bool backgroundEnabled = true;

  /// The macOS system prompts were brought up once, so they are not asked again.
  bool permissionsAsked = false;

  /// Videos were read again once speech was allowed – never needed a second time.
  bool speechVideos = false;
  int ocrVersion = 0;
  int contentVersion = 0;
  DateTime? lastRun;

  /// How long the last time-boxed indexing pass took, and when it ran.
  Duration? lastIndexTime;
  DateTime? lastIndexAt;

  /// The last visit to the Search screen: time from opening it until a search began,
  /// and how long that search took.
  Duration? lastWaitBeforeSearch;
  Duration? lastSearchTook;

  File? _file;
  Future<void> _saving = Future.value();

  /// Something changed since the last save. Quitting saves only then – writing the
  /// whole index takes seconds, and most of the time it's already on disk.
  bool dirty = false;

  /// One line per file (gzipped JSON lines), read and written as a stream: a large
  /// index never sits in memory twice, and saving never holds up the app.
  static const _name = 'smart_index_v2.jsonl.gz';

  /// The older single-JSON format, read once and then replaced.
  static const _oldName = 'smart_index_v1.json.gz';

  /// Tests: save to / load from [file] instead of the app's folder.
  @visibleForTesting
  Future<void> loadFrom(File file) async {
    _file = file;
    if (!await file.exists()) return;
    final path = file.path;
    final (header, list) = await Isolate.run(() => _readLines(path));
    _apply(header, list);
  }

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File(p.join(dir.path, _name));
    final old = File(p.join(dir.path, _oldName));
    try {
      if (await _file!.exists()) {
        final path = _file!.path; // only the path goes to the isolate, not this store
        final (header, list) = await Isolate.run(() => _readLines(path));
        _apply(header, list);
      } else if (await old.exists()) {
        final data = await Isolate.run(() async => _decodeOld(await old.readAsBytes()));
        _apply(data, [
          for (final j in (data['files'] as List).cast<Map<String, dynamic>>()) IndexedFile.fromJson(j),
        ]);
        await save();
        await old.delete();
      }
    } catch (_) {
      files.clear(); // corrupt index → start fresh
    }
  }

  void _apply(Map<String, dynamic> data, List<IndexedFile> list) {
    initialDone = data['initialDone'] as bool? ?? false;
    backgroundEnabled = data['bg'] as bool? ?? true;
    permissionsAsked = data['pa'] as bool? ?? false;
    speechVideos = data['sv'] as bool? ?? false;
    ocrVersion = data['ocr'] as int? ?? 0;
    contentVersion = data['cv'] as int? ?? 0;
    final last = data['last'] as int?;
    lastRun = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    final t = (data['timing'] as Map?)?.cast<String, dynamic>() ?? const {};
    Duration? ms(String k) => t[k] == null ? null : Duration(milliseconds: t[k] as int);
    lastIndexTime = ms('index');
    lastWaitBeforeSearch = ms('wait');
    lastSearchTook = ms('took');
    lastIndexAt = t['indexAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(t['indexAt'] as int);
    extraRoots
      ..clear()
      ..addAll(((data['extra'] as List?) ?? const []).cast<String>());
    files.clear();
    for (final f in list) {
      files[f.path] = f;
    }
  }

  /// Saves are serialised so two never overlap.
  Future<void> save() {
    _saving = _saving.then((_) => _write()).catchError((Object _) {});
    return _saving;
  }

  Map<String, Object?> _header() => {
        'v': 2,
        'initialDone': initialDone,
        'bg': backgroundEnabled,
        'pa': permissionsAsked,
        'sv': speechVideos,
        'ocr': ocrVersion,
        'cv': contentVersion,
        'last': lastRun?.millisecondsSinceEpoch,
        'timing': {
          if (lastIndexTime != null) 'index': lastIndexTime!.inMilliseconds,
          if (lastIndexAt != null) 'indexAt': lastIndexAt!.millisecondsSinceEpoch,
          if (lastWaitBeforeSearch != null) 'wait': lastWaitBeforeSearch!.inMilliseconds,
          if (lastSearchTook != null) 'took': lastSearchTook!.inMilliseconds,
        },
        'extra': List<String>.of(extraRoots),
      };

  /// Hands the files to a helper isolate a few MB at a time; it encodes, compresses and
  /// writes them. Memory stays flat and the UI thread only copies small batches.
  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    dirty = false; // changes from here on are caught by the next save
    final list = List.of(files.values);
    final tmp = '${file.path}.tmp';
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    final iso = await Isolate.spawn(_saveWorker, [port.sendPort, tmp], onExit: port.sendPort, onError: port.sendPort);
    try {
      Future<void> ack() async {
        if (!await replies.moveNext() || replies.current != true) throw StateError('save failed');
      }

      if (!await replies.moveNext()) throw StateError('save failed');
      final worker = replies.current as SendPort;
      worker.send(jsonEncode(_header()));
      await ack();
      var batch = <Map<String, Object>>[];
      var size = 0;
      for (final f in list) {
        batch.add(f.toJson());
        size += f.content.length + 256;
        if (size >= 2 << 20) {
          worker.send(batch);
          await ack();
          batch = [];
          size = 0;
        }
      }
      worker.send(batch);
      await ack();
      worker.send(null); // finish
      await ack();
      await File(tmp).rename(file.path);
    } catch (_) {
      dirty = true; // try again next time
      iso.kill(priority: Isolate.immediate);
      try {
        await File(tmp).delete();
      } catch (_) {}
    } finally {
      await replies.cancel();
      port.close();
    }
  }
}

/// Save helper: header line, then one JSON line per file, gzipped straight to disk.
void _saveWorker(List<Object> args) {
  final main = args[0] as SendPort;
  final raf = File(args[1] as String).openSync(mode: FileMode.write);
  final gz = gzip.encoder.startChunkedConversion(_FileSink(raf));
  final rp = ReceivePort();
  main.send(rp.sendPort);
  rp.listen((msg) {
    if (msg == null) {
      gz.close();
      raf
        ..flushSync()
        ..closeSync();
      main.send(true);
      rp.close();
      return;
    }
    if (msg is String) {
      gz.add(utf8.encode('$msg\n'));
    } else {
      for (final m in msg as List) {
        gz.add(utf8.encode('${jsonEncode(m)}\n'));
      }
    }
    main.send(true);
  });
}

class _FileSink implements Sink<List<int>> {
  _FileSink(this.raf);
  final RandomAccessFile raf;
  @override
  void add(List<int> data) => raf.writeFromSync(data);
  @override
  void close() {}
}

/// Reads the index line by line (in a background isolate): never the whole text at once.
Future<(Map<String, dynamic>, List<IndexedFile>)> _readLines(String path) async {
  Map<String, dynamic>? header;
  final out = <IndexedFile>[];
  await for (final line
      in File(path).openRead().transform(gzip.decoder).transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final j = jsonDecode(line) as Map<String, dynamic>;
    if (header == null) {
      header = j;
    } else {
      out.add(IndexedFile.fromJson(j));
    }
  }
  return (header ?? const <String, dynamic>{}, out);
}

Map<String, dynamic> _decodeOld(Uint8List bytes) =>
    jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
