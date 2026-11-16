import 'package:path/path.dart' as p;

import 'file_types.dart';

enum IndexStatus { pending, indexed, nameOnly, failed }

enum ContentSource { none, text, ocr }

class IndexedFile {
  IndexedFile({
    required this.path,
    required this.size,
    required this.modifiedMs,
    this.status = IndexStatus.pending,
    this.source = ContentSource.none,
    String content = '',
  })  : name = p.basename(path),
        ext = extensionOf(path),
        _content = content;

  final String path;
  final String name;
  final String ext;
  int size;
  int modifiedMs;
  IndexStatus status;
  ContentSource source;

  String _content;
  String? _lower;
  String? _flat;
  String? _compactName;
  List<String>? _nameFlats;

  String get content => _content;
  set content(String v) {
    _content = v;
    _lower = null;
    _flat = null;
  }

  /// Lower-cased content, cached for phrase matching and snippets.
  String get contentLower => _lower ??= _content.toLowerCase();

  /// Lower-cased content with every run of whitespace/punctuation collapsed to one space,
  /// so "Wild\nThings!" still matches the phrase "wild things".
  String get contentFlat =>
      _flat ??= ' ${contentLower.replaceAll(_nonAlnum, ' ').replaceAll(_multiSpace, ' ').trim()} ';

  /// File name lower-cased with separators removed: "Invoice_March-24.pdf" → "invoicemarch24pdf".
  String get compactName => _compactName ??= compact(name);

  /// File name as space-separated words, plain and with camelCase / digit
  /// boundaries split: "InvoiceMarch2024.pdf" → " invoicemarch2024 pdf ", " invoice march 2024 pdf ".
  List<String> get nameFlats => _nameFlats ??= () {
        final words = name.split(_nonAlnum).where((w) => w.isNotEmpty).toList();
        final plain = ' ${words.join(' ').toLowerCase()} ';
        final split = ' ${words.expand((w) => w.split(_camel)).join(' ').toLowerCase()} ';
        return plain == split ? [plain] : [plain, split];
      }();

  /// True when [flatQuery] (" word word ") appears as whole words in the name or the text inside.
  bool nameHasExact(String flatQuery) => nameFlats.any((n) => n.contains(flatQuery));
  bool contentHasExact(String flatQuery) => _content.isNotEmpty && contentFlat.contains(flatQuery);

  FileKind get kind => kindForExt(ext);
  String get folder => p.dirname(path);
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  bool get needsText => status == IndexStatus.pending && hasExtractableText(ext);
  bool get needsOcr => status == IndexStatus.pending && isOcrCandidate(ext);
  bool get isPending => needsText || needsOcr;

  Map<String, Object> toJson() => {
        'p': path,
        's': size,
        'm': modifiedMs,
        'st': status.index,
        'src': source.index,
        if (_content.isNotEmpty) 'c': _content,
      };

  factory IndexedFile.fromJson(Map<String, dynamic> j) => IndexedFile(
        path: j['p'] as String,
        size: j['s'] as int,
        modifiedMs: j['m'] as int,
        status: IndexStatus.values[j['st'] as int],
        source: ContentSource.values[j['src'] as int],
        content: (j['c'] as String?) ?? '',
      );
}

String extensionOf(String path) {
  final e = p.extension(path);
  return e.length <= 1 ? '' : e.substring(1).toLowerCase();
}

final _nonAlnum = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _multiSpace = RegExp(r' {2,}');
final _camel = RegExp(r'(?<=\p{Ll})(?=\p{Lu})|(?<=\p{L})(?=\p{N})|(?<=\p{N})(?=\p{L})', unicode: true);
String compact(String s) => s.toLowerCase().replaceAll(_nonAlnum, '');
