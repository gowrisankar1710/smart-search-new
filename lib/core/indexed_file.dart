import 'package:path/path.dart' as p;

import 'file_types.dart';

enum IndexStatus { pending, indexed, nameOnly, failed }

/// `video`: text read from a video (on-screen text, speech, subtitles) with timestamps.
/// New values go at the end – the index stores the position.
enum ContentSource { none, text, ocr, video }

/// Something the image classifier sees in a picture ("sari", "bird", "rocks"), 0–1 sure.
class ImageLabel {
  const ImageLabel(this.id, this.confidence);
  final String id;
  final double confidence;

  List<Object> toJson() => [id, double.parse(confidence.toStringAsFixed(2))];
  factory ImageLabel.fromJson(List<dynamic> j) => ImageLabel(j[0] as String, (j[1] as num).toDouble());
}

/// A piece of text found in a video, starting [seconds] into it.
class VideoSegment {
  const VideoSegment(this.seconds, this.text);
  final double seconds;
  final String text;

  Duration get at => Duration(milliseconds: (seconds * 1000).round());

  List<Object> toJson() => [double.parse(seconds.toStringAsFixed(2)), text];
  factory VideoSegment.fromJson(List<dynamic> j) => VideoSegment((j[0] as num).toDouble(), j[1] as String);
}

class IndexedFile {
  IndexedFile({
    required this.path,
    required this.size,
    required this.modifiedMs,
    this.status = IndexStatus.pending,
    this.source = ContentSource.none,
    String content = '',
    List<VideoSegment> segments = const [],
    this.labels = const [],
  })  : name = p.basename(path),
        ext = extensionOf(path),
        _content = content {
    if (segments.isNotEmpty) this.segments = segments;
  }

  final String path;
  final String name;
  final String ext;
  int size;
  int modifiedMs;
  IndexStatus status;
  ContentSource source;

  /// Images: what the picture shows (objects, scenes, clothing), most certain first.
  List<ImageLabel> labels;

  String _content;
  String? _lower;
  String? _nameLower;

  String get content => _content;
  set content(String v) {
    _content = v;
    _lower = null;
  }

  /// Lower-cased content, cached for phrase matching and snippets.
  String get contentLower => _lower ??= _content.toLowerCase();

  List<VideoSegment> _segments = const [];
  List<int> _segStarts = const [];

  /// Timestamped text of a video, in time order. Setting it also sets [content]
  /// (segments joined by line breaks), so search works on videos like on any file.
  List<VideoSegment> get segments => _segments;
  set segments(List<VideoSegment> v) {
    _segments = List.unmodifiable(v);
    final starts = <int>[];
    final b = StringBuffer();
    for (final s in _segments) {
      if (b.isNotEmpty) b.write('\n');
      starts.add(b.length);
      b.write(s.text);
    }
    _segStarts = starts;
    content = b.toString();
  }

  /// The video moment whose text contains character [offset] of [content].
  VideoSegment? segmentAt(int offset) {
    if (_segments.isEmpty || offset < 0) return null;
    var lo = 0, hi = _segStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_segStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _segments[lo];
  }

  String get nameLower => _nameLower ??= name.toLowerCase();

  FileKind get kind => kindForExt(ext);
  String get folder => p.dirname(path);
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  /// A PDF without a text layer (scanned / image-only): its pages are read with OCR.
  bool get isScannedPdf => ext == 'pdf' && source == ContentSource.ocr;

  bool get needsText => status == IndexStatus.pending && hasExtractableText(ext) && !isScannedPdf;
  bool get needsOcr => status == IndexStatus.pending && (isOcrCandidate(ext) || isScannedPdf);
  bool get needsVideo => status == IndexStatus.pending && isReadableVideo(ext, size);
  bool get isPending => needsText || needsOcr || needsVideo;

  Map<String, Object> toJson() => {
        'p': path,
        's': size,
        'm': modifiedMs,
        'st': status.index,
        'src': source.index,
        if (labels.isNotEmpty) 'lb': [for (final l in labels) l.toJson()],
        if (_segments.isNotEmpty)
          'vs': [for (final s in _segments) s.toJson()]
        else if (_content.isNotEmpty)
          'c': _content,
      };

  factory IndexedFile.fromJson(Map<String, dynamic> j) => IndexedFile(
        path: j['p'] as String,
        size: j['s'] as int,
        modifiedMs: j['m'] as int,
        status: IndexStatus.values[j['st'] as int],
        source: ContentSource.values[j['src'] as int],
        content: (j['c'] as String?) ?? '',
        segments: [
          for (final s in (j['vs'] as List?) ?? const []) VideoSegment.fromJson(s as List),
        ],
        labels: [
          for (final l in (j['lb'] as List?) ?? const []) ImageLabel.fromJson(l as List),
        ],
      );
}

String extensionOf(String path) {
  final e = p.extension(path);
  return e.length <= 1 ? '' : e.substring(1).toLowerCase();
}

final _nonAlnum = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
String compact(String s) => s.toLowerCase().replaceAll(_nonAlnum, '');
