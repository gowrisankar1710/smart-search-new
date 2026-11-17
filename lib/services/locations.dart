import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ScanRoot {
  const ScanRoot(this.path, this.label, {this.userAdded = false, this.wholeDrive = false});
  final String path;
  final String label;
  final bool userAdded;

  /// A whole drive (or everything under the user profile on Windows): read in the
  /// background after Search opens, not while the Timer screen waits.
  final bool wholeDrive;
}

/// Works out which folders/drives are reachable on this platform.
class Locations {
  static String get _home =>
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;

  static Future<List<ScanRoot>> roots(List<String> extra) async {
    final out = <ScanRoot>[];
    bool same(String a, String b) =>
        (Platform.isWindows || Platform.isMacOS) ? a.toLowerCase() == b.toLowerCase() : a == b;

    final skip = skipPaths();
    void add(String path, String label, {bool user = false, bool drive = false}) {
      final n = p.normalize(path);
      if (out.any((r) => same(r.path, n)) || skip.any((s) => same(s, n))) return;
      try {
        if (Directory(n).existsSync()) out.add(ScanRoot(n, label, userAdded: user, wholeDrive: drive));
      } catch (_) {}
    }

    // Folders the user picked come first: they are clearly what they care about.
    for (final e in extra) {
      add(e, p.basename(e).isEmpty ? e : p.basename(e), user: true);
    }

    if (Platform.isWindows) {
      final h = _home;
      for (final base in [h, p.join(h, 'OneDrive')]) {
        add(p.join(base, 'Desktop'), 'Desktop');
        add(p.join(base, 'Documents'), 'Documents');
        add(p.join(base, 'Pictures'), 'Pictures');
      }
      add(p.join(h, 'Downloads'), 'Downloads');
      add(p.join(h, 'Videos'), 'Videos');
      add(p.join(h, 'Music'), 'Music');
      add(p.join(h, 'OneDrive'), 'OneDrive');
      // Everything else under the profile and on the drives: read after Search opens.
      add(h, 'Home', drive: true);
      for (final l in 'DEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        add('$l:\\', 'Drive $l:', drive: true);
      }
      add(r'C:\', 'Drive C:', drive: true);
    } else if (Platform.isMacOS) {
      final h = _home;
      add(p.join(h, 'Desktop'), 'Desktop');
      add(p.join(h, 'Documents'), 'Documents');
      add(p.join(h, 'Downloads'), 'Downloads');
      add(p.join(h, 'Pictures'), 'Pictures');
      add(p.join(h, 'Movies'), 'Videos');
      add(p.join(h, 'Library', 'Mobile Documents', 'com~apple~CloudDocs'), 'iCloud Drive');
      add(h, 'Home');
      try {
        for (final v in Directory('/Volumes').listSync(followLinks: false)) {
          if (v is Directory) add(v.path, p.basename(v.path), drive: true);
        }
      } catch (_) {}
    } else if (Platform.isLinux) {
      final h = _home;
      for (final n in ['Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music']) {
        add(p.join(h, n), n);
      }
      add(h, 'Home');
      final user = Platform.environment['USER'] ?? '';
      for (final base in ['/media/$user', '/run/media/$user', '/mnt']) {
        try {
          for (final v in Directory(base).listSync(followLinks: false)) {
            if (v is Directory) add(v.path, p.basename(v.path), drive: true);
          }
        } catch (_) {}
      }
    } else if (Platform.isAndroid) {
      const base = '/storage/emulated/0';
      add('$base/Download', 'Downloads');
      add('$base/Documents', 'Documents');
      add('$base/DCIM', 'Camera');
      add('$base/Pictures', 'Pictures');
      add('$base/Movies', 'Videos');
      add('$base/Android/media/com.whatsapp/WhatsApp/Media', 'WhatsApp');
      add(base, 'Internal storage');
      try {
        final dirs = await getExternalStorageDirectories() ?? const <Directory>[];
        for (final d in dirs) {
          final i = d.path.indexOf('/Android/');
          if (i > 0 && !d.path.startsWith(base)) add(d.path.substring(0, i), 'SD card');
        }
      } catch (_) {}
    } else if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      add(docs.path, 'On My iPhone › Smart Search');
    }
    return out;
  }

  /// System / app-data folders that are never worth scanning.
  static List<String> skipPaths() {
    final h = _home;
    if (Platform.isWindows) {
      return [
        r'C:\Windows', r'C:\Program Files', r'C:\Program Files (x86)', r'C:\ProgramData',
        r'C:\$Recycle.Bin', r'C:\Recovery', r'C:\PerfLogs', p.join(h, 'AppData'),
      ];
    }
    if (Platform.isMacOS) {
      return [p.join(h, 'Library'), '/Volumes/Macintosh HD', '/System', '/Applications'];
    }
    if (Platform.isAndroid) return ['/storage/emulated/0/Android/data', '/storage/emulated/0/Android/obb'];
    if (Platform.isLinux) return [p.join(h, 'snap'), p.join(h, '.local'), p.join(h, '.cache')];
    return const [];
  }
}
