import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_scan.dart';

/// Watches the search locations and reports paths that were created, changed, moved or
/// deleted, a moment after things settle. The OS does the watching (FSEvents on macOS,
/// ReadDirectoryChangesW on Windows), so it costs nothing while the disk is quiet.
///
/// Elsewhere (Linux, Android, iOS) recursive watching isn't available; [active] stays
/// false and the periodic re-scan picks up new files instead.
class FolderWatcher {
  FolderWatcher({required this.onChanges});

  /// Paths that changed – each may now be a file, a folder, or gone.
  final void Function(Set<String> paths) onChanges;

  static bool get supported => Platform.isMacOS || Platform.isWindows;

  /// Batches are reported this long after their first event.
  static const settle = Duration(milliseconds: 1500);

  /// A file written to less than this long ago is probably still being copied/saved –
  /// it's reported once it has been left alone.
  static const quiet = Duration(seconds: 2);

  final List<StreamSubscription<FileSystemEvent>> _subs = [];
  final Set<String> _changed = {};
  Timer? _flush;
  List<String> _roots = const [];
  List<String> _skip = const [];

  bool get active => _subs.isNotEmpty;

  /// (Re)starts watching [roots]. Roots inside another root are covered by it.
  void watch(List<String> roots, List<String> skipPaths) {
    stop();
    if (!supported) return;
    final norm = roots.map(p.normalize).toList();
    _roots = [
      for (final r in norm)
        if (!norm.any((o) => o != r && p.isWithin(o, r))) r,
    ];
    _skip = skipPaths.map((s) => _key(p.normalize(s))).toList();
    for (final r in _roots) {
      try {
        _subs.add(Directory(r).watch(recursive: true).listen(_onEvent, onError: (_) {}, cancelOnError: false));
      } catch (_) {
        // Unwatchable (permissions, network drive) – the periodic re-scan still covers it.
      }
    }
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _flush?.cancel();
    _flush = null;
    _changed.clear();
  }

  static String _key(String s) => (Platform.isMacOS || Platform.isWindows) ? s.toLowerCase() : s;

  bool _wanted(String path) {
    final k = _key(path);
    for (final s in _skip) {
      if (k == s || k.startsWith('$s${p.separator}')) return false;
    }
    for (final r in _roots) {
      if (p.isWithin(r, path)) return isScannablePath(path, r);
    }
    return false;
  }

  void _onEvent(FileSystemEvent e) {
    var any = false;
    for (final path in [e.path, if (e is FileSystemMoveEvent && e.destination != null) e.destination!]) {
      if (_wanted(path)) any = _changed.add(path) || any;
    }
    if (any) _flush ??= Timer(settle, _report);
  }

  /// Checks off the UI thread (async stat): with whole drives watched, a burst of
  /// changes can be hundreds of paths, and blocking checks froze typing.
  Future<void> _report() async {
    if (_changed.isEmpty) {
      _flush = null;
      return;
    }
    final batch = List.of(_changed);
    _changed.clear();
    final stats = await Future.wait(batch.map((path) async {
      try {
        return await FileStat.stat(path);
      } catch (_) {
        return null;
      }
    }));
    if (_subs.isEmpty) return; // stopped meanwhile
    final now = DateTime.now();
    final ready = <String>{};
    for (var i = 0; i < batch.length; i++) {
      final st = stats[i];
      if (st != null && st.type == FileSystemEntityType.file && now.difference(st.modified) < quiet) {
        _changed.add(batch[i]); // still being written – look again shortly
      } else {
        ready.add(batch[i]);
      }
    }
    // Events that came in while checking are in [_changed] too.
    _flush = _changed.isEmpty ? null : Timer(settle, _report);
    if (ready.isNotEmpty) onChanges(ready);
  }
}
