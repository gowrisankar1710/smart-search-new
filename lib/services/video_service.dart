import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/file_types.dart';
import '../core/indexed_file.dart';

/// Finds what is said and shown in a video, with the moment each piece appears.
abstract class VideoAnalyzer {
  String get name;

  /// Can read the picture and sound itself (not only subtitle files next to the video).
  Future<bool> readsMedia();

  /// Timestamped text of the video: one run per source (subtitles, speech, on-screen
  /// text), each in time order. Runs are never interleaved, so a phrase stays contiguous.
  /// Empty when nothing was found. [onProgress] gets how far reading has got, 0–1.
  Future<List<VideoSegment>> analyze(String path, {void Function(double fraction)? onProgress});

  /// Stops a running [analyze] early (it then returns what it has read so far).
  void cancel() {}
}

VideoAnalyzer createVideoAnalyzer() =>
    Platform.isMacOS || Platform.isWindows ? NativeVideoAnalyzer() : SubtitleVideoAnalyzer();

/// Every platform: reads subtitle files saved next to the video.
class SubtitleVideoAnalyzer implements VideoAnalyzer {
  @override
  String get name => 'Subtitle files';
  @override
  Future<bool> readsMedia() async => false;

  @override
  Future<List<VideoSegment>> analyze(String path, {void Function(double fraction)? onProgress}) async =>
      readSidecarSubtitles(path);

  @override
  void cancel() {}
}

/// macOS: AVFoundation samples frames → Apple Vision reads on-screen text, and the
/// on-device Speech recogniser transcribes the audio.
/// Windows: Windows.Media.Editing samples frames → Windows OCR reads on-screen text,
/// and the Windows speech engine (SAPI) transcribes the audio when installed.
/// Plus any subtitle files.
class NativeVideoAnalyzer implements VideoAnalyzer {
  static const _channel = MethodChannel('smart_file_search/video');
  bool? _native;

  /// The video being read and who wants its progress (the native side reads one at a time).
  String? _path;
  void Function(double)? _onProgress;

  NativeVideoAnalyzer() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      if (args['path'] == _path) _onProgress?.call((args['fraction'] as num).toDouble());
    });
  }

  /// AVFoundation can't open these containers – only their subtitle files are read.
  /// (Windows Media Foundation decides for itself; unreadable files just yield nothing.)
  static Set<String> get _unsupported => Platform.isMacOS ? const {'mkv', 'webm', 'avi', 'wmv'} : const {};

  @override
  String get name =>
      Platform.isWindows ? 'Windows OCR + Windows speech (on-device)' : 'Apple Vision + Speech (on-device)';

  @override
  Future<bool> readsMedia() async {
    if (_native != null) return _native!;
    try {
      _native = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      _native = false;
    }
    return _native!;
  }

  @override
  Future<List<VideoSegment>> analyze(String path, {void Function(double fraction)? onProgress}) async {
    final subs = await readSidecarSubtitles(path);
    if (_unsupported.contains(extensionOf(path)) || !await readsMedia()) return subs;
    _path = path;
    _onProgress = onProgress;
    final List<Map<Object?, Object?>> raw;
    try {
      raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
              'analyze', {'path': path, 'budgetSeconds': kVideoAnalysisLimit.inSeconds.toDouble()}) ??
          const [];
    } finally {
      if (_path == path) {
        _path = null;
        _onProgress = null;
      }
    }
    onProgress?.call(1);
    final media = [
      for (final m in raw)
        if ((m['text'] as String?)?.trim().isNotEmpty ?? false)
          VideoSegment((m['t'] as num).toDouble(), (m['text'] as String).trim()),
    ];
    return [...subs, ...media];
  }

  @override
  void cancel() {
    if (_native ?? false) unawaited(_channel.invokeMethod<void>('cancel').catchError((_) {}));
  }
}

/// Sorts by time and drops exact repeats of the line just before.
List<VideoSegment> mergeSegments(List<VideoSegment> all) {
  all.sort((a, b) => a.seconds.compareTo(b.seconds));
  final out = <VideoSegment>[];
  for (final s in all) {
    if (out.isNotEmpty && out.last.text == s.text) continue;
    out.add(s);
  }
  return out;
}

/// "talk.mp4" → "talk.srt", "talk.vtt", "talk.en.srt", … in the same folder.
Future<List<VideoSegment>> readSidecarSubtitles(String videoPath) async {
  final dir = Directory(p.dirname(videoPath));
  final stem = p.basenameWithoutExtension(videoPath).toLowerCase();
  final out = <VideoSegment>[];
  try {
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path).toLowerCase();
      if (!subtitleExtensions.contains(extensionOf(name))) continue;
      final base = p.basenameWithoutExtension(name);
      if (base != stem && !base.startsWith('$stem.')) continue;
      if (await e.length() > 8 << 20) continue;
      final bytes = await e.readAsBytes();
      // One run per file: two languages must not interleave.
      out.addAll(mergeSegments(parseSubtitles(utf8.decode(bytes, allowMalformed: true))));
    }
  } catch (_) {}
  return out;
}

final _cueTime = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->');
final _tags = RegExp(r'<[^>]*>|\{\\[^}]*\}');

/// Parses SRT and WebVTT cues into timestamped lines.
List<VideoSegment> parseSubtitles(String source) {
  final out = <VideoSegment>[];
  final lines = const LineSplitter().convert(source.replaceFirst('﻿', ''));
  for (var i = 0; i < lines.length; i++) {
    final m = _cueTime.firstMatch(lines[i]);
    if (m == null) continue;
    final h = int.tryParse(m.group(1) ?? '0') ?? 0;
    final mm = int.parse(m.group(2)!), ss = int.parse(m.group(3)!);
    final frac = m.group(4)!.padRight(3, '0');
    final secs = h * 3600 + mm * 60 + ss + int.parse(frac) / 1000;
    final text = <String>[];
    while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
      text.add(lines[++i].replaceAll(_tags, '').trim());
    }
    final t = text.where((l) => l.isNotEmpty).join(' ');
    if (t.isNotEmpty) out.add(VideoSegment(secs, t));
  }
  return out;
}

/// "1:02:05" / "4:07" for a moment in a video.
String formatTimestamp(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
