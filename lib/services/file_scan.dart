import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/constants.dart';

/// Discovers files in a background isolate (breadth-first, so shallow, user-facing
/// files are found first). Emits flat batches: [path, size, modifiedMs, path, ...].
class FileScan {
  Isolate? _iso;
  ReceivePort? _port;
  StreamController<List<Object>>? _ctrl;
  bool _stopped = false;
  bool completed = false;

  Stream<List<Object>> start(List<String> roots, List<String> skipPaths) {
    final ctrl = StreamController<List<Object>>(onCancel: stop);
    _ctrl = ctrl;
    final port = ReceivePort();
    _port = port;
    port.listen((msg) {
      if (ctrl.isClosed) return;
      if (msg == 'done' || msg == null) {
        completed = msg == 'done';
        stop();
      } else {
        ctrl.add((msg as List).cast<Object>());
      }
    });
    Isolate.spawn(_scanMain, _ScanRequest(roots, skipPaths, port.sendPort), onExit: port.sendPort, debugName: 'scanner')
        .then((iso) {
      _iso = iso;
      if (_stopped) iso.kill(priority: Isolate.immediate);
    });
    return ctrl.stream;
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _iso?.kill(priority: Isolate.immediate);
    _port?.close();
    final c = _ctrl;
    if (c != null && !c.isClosed) c.close();
  }
}

class _ScanRequest {
  const _ScanRequest(this.roots, this.skipPaths, this.reply);
  final List<String> roots;
  final List<String> skipPaths;
  final SendPort reply;
}

const _skipDirNames = <String>{
  'node_modules', r'$recycle.bin', 'system volume information', 'pods', 'deriveddata',
  '__pycache__', 'site-packages', 'build', 'intermediates', 'cache', 'caches', 'thumbnails',
  'venv', 'bower_components', 'vendor',
};

/// Folders that are really app-internal packages: their files change constantly (the
/// Music app's database, app bundles) and hold nothing people search for.
const _skipDirExts = <String>{
  'musiclibrary', 'tvlibrary', 'app', 'appex', 'framework', 'bundle', 'plugin', 'kext',
  'xcarchive', 'dsym', 'noindex', 'photoslibrary-journal',
};

/// Files that churn while apps run and never contain searchable text: database
/// journals, locks, temp files and half-finished downloads.
const _skipFileExts = <String>{
  'db-wal', 'db-shm', 'db-journal', 'sqlite-wal', 'sqlite-shm', 'sqlite-journal', 'wal', 'shm',
  'journal', 'lock', 'lck', 'tmp', 'temp', 'crdownload', 'part', 'partial', 'download', 'swp',
  'swo', 'pid', 'sock',
};

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool _skipDir(String name) => _skipDirNames.contains(name.toLowerCase()) || _skipDirExts.contains(_extOf(name));
bool _skipFile(String name) => _skipFileExts.contains(_extOf(name)) || name.toLowerCase().endsWith('-journal');

/// Would the full scan include [path] (found under [root])? Same rules: no hidden or
/// Office lock files, nothing inside skipped folders. Used by the live folder watcher.
bool isScannablePath(String path, String root) {
  final rel = p.split(p.relative(path, from: root));
  if (rel.isEmpty || rel.first == '..') return false;
  for (var i = 0; i < rel.length; i++) {
    final name = rel[i];
    if (name.startsWith('.') || name.startsWith(r'~$')) return false;
    if (i < rel.length - 1 ? _skipDir(name) : _skipFile(name)) return false;
  }
  return true;
}

void _scanMain(_ScanRequest req) {
  final caseInsensitive = Platform.isWindows || Platform.isMacOS;
  String key(String s) => caseInsensitive ? s.toLowerCase() : s;
  final skip = req.skipPaths.map(key).toSet();
  final visited = <String>{};
  final queue = ListQueue<String>()..addAll(req.roots);
  var batch = <Object>[];
  var count = 0;
  final tick = Stopwatch()..start();

  void flush() {
    if (batch.isEmpty) return;
    req.reply.send(batch);
    batch = <Object>[];
  }

  while (queue.isNotEmpty && count < kMaxFiles) {
    final dir = queue.removeFirst();
    final k = key(dir);
    if (!visited.add(k) || skip.contains(k)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } catch (_) {
      continue; // no permission / vanished
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.') || name.startsWith(r'~$')) continue;
      if (e is Directory) {
        if (!_skipDir(name)) queue.add(e.path);
      } else if (e is File) {
        if (_skipFile(name)) continue;
        try {
          final st = e.statSync();
          batch
            ..add(e.path)
            ..add(st.size)
            ..add(st.modified.millisecondsSinceEpoch);
          count++;
        } catch (_) {}
        if (batch.length >= 1500) flush();
      }
    }
    if (tick.elapsedMilliseconds > 200) {
      flush();
      tick.reset();
    }
  }
  flush();
  req.reply.send('done');
}
