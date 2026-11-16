/// Text extraction for documents. Runs inside extractor isolates – no Flutter UI code here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../core/file_types.dart';

const _maxPdfPages = 40;
const _maxPlainBytes = 1 << 20; // 1 MB of a text file is plenty for search

/// Returns raw extracted text, or null when the type has no extractor.
String? extractText(String path, String ext) {
  final file = File(path);
  switch (ext) {
    case 'pdf':
      return _pdf(file);
    case 'docx':
    case 'docm':
    case 'dotx':
      return _zip(file, (n) =>
          n == 'word/document.xml' ||
          n == 'word/footnotes.xml' ||
          (n.startsWith('word/header') || n.startsWith('word/footer')) && n.endsWith('.xml'));
    case 'pptx':
      return _zip(file, (n) =>
          (n.startsWith('ppt/slides/slide') || n.startsWith('ppt/notesSlides/')) && n.endsWith('.xml'));
    case 'xlsx':
    case 'xlsm':
      return _zip(
        file,
        (n) => n == 'xl/sharedStrings.xml' || n == 'xl/workbook.xml' ||
            (n.startsWith('xl/worksheets/sheet') && n.endsWith('.xml')),
        transform: (name, xml) => name.startsWith('xl/worksheets/') ? _inlineCellText(xml) : xmlToText(xml),
      );
    case 'odt':
    case 'ods':
    case 'odp':
      return _zip(file, (n) => n == 'content.xml');
    case 'rtf':
      return _rtf(file);
    case 'doc':
    case 'xls':
    case 'ppt':
      return _binaryStrings(file);
  }
  if (textExtensions.contains(ext)) {
    final t = _plain(file);
    return (ext == 'html' || ext == 'htm' || ext == 'xml') ? xmlToText(t) : t;
  }
  return _sniffed(file, ext);
}

// ---------------------------------------------------------------- PDF
String _pdf(File f) {
  final doc = PdfDocument(inputBytes: f.readAsBytesSync());
  try {
    final count = doc.pages.count;
    if (count == 0) return '';
    return PdfTextExtractor(doc).extractText(startPageIndex: 0, endPageIndex: min(count, _maxPdfPages) - 1);
  } finally {
    doc.dispose();
  }
}

// ---------------------------------------------------------------- Office Open XML / ODF
String _zip(File f, bool Function(String name) want, {String Function(String name, String xml)? transform}) {
  final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
  final buf = StringBuffer();
  for (final entry in archive.files) {
    if (!entry.isFile || !want(entry.name)) continue;
    final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
    buf.writeln(transform != null ? transform(entry.name, xml) : xmlToText(xml));
    if (buf.length > 120000) break;
  }
  return buf.toString();
}

final _tag = RegExp(r'<[^>]+>');
final _blockEnd = RegExp(r'</(w:p|a:p|text:p|text:h|si|row|p|div|li|tr|h\d)>|<(w:br|w:tab|text:line-break|br)\s*/?>', caseSensitive: false);
final _odfSpace = RegExp(r'<text:s[^>]*/>|<w:tab/>');
final _script = RegExp(r'<(script|style)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true);
final _inlineT = RegExp(r'<t[^>]*>([^<]*)</t>');

String xmlToText(String xml) => decodeEntities(
      xml.replaceAll(_script, ' ').replaceAll(_odfSpace, ' ').replaceAll(_blockEnd, '\n').replaceAll(_tag, ''),
    );

String _inlineCellText(String sheetXml) => decodeEntities(_inlineT.allMatches(sheetXml).map((m) => m.group(1)).join(' '));

final _numEntity = RegExp(r'&#(x?)([0-9a-fA-F]+);');
String decodeEntities(String s) => s
    .replaceAllMapped(_numEntity, (m) {
      final code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
      return code == null || code > 0x10FFFF ? ' ' : String.fromCharCode(code);
    })
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

// ---------------------------------------------------------------- Plain text
/// Unknown extension: read it as text unless the first 8 KB look binary.
String _sniffed(File f, String ext) {
  final raf = f.openSync();
  final List<int> head;
  try {
    head = raf.readSync(min(raf.lengthSync(), 8192));
  } finally {
    raf.closeSync();
  }
  if (head.isEmpty || _looksBinary(head)) return '';
  final t = _plain(f);
  const markup = {'svg', 'xib', 'storyboard', 'plist', 'xcscheme', 'xcworkspacedata', 'iml', 'xaml', 'resx'};
  return markup.contains(ext) ? xmlToText(t) : t;
}

bool _looksBinary(List<int> b) {
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) return false;
  var odd = 0;
  for (final c in b) {
    if (c == 0) return true;
    if (c < 9 || (c > 13 && c < 32)) odd++;
  }
  return odd > b.length ~/ 20;
}

String _plain(File f) {
  final raf = f.openSync();
  try {
    final bytes = raf.readSync(min(raf.lengthSync(), _maxPlainBytes));
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16le(bytes, 2);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    raf.closeSync();
  }
}

String _utf16le(List<int> b, int start) {
  final codes = <int>[];
  for (var i = start; i + 1 < b.length; i += 2) {
    codes.add(b[i] | (b[i + 1] << 8));
  }
  return String.fromCharCodes(codes);
}

// ---------------------------------------------------------------- RTF
final _rtfHex = RegExp(r"\\'([0-9a-fA-F]{2})");
final _rtfGroupSkip = RegExp(r'\{\\\*[^{}]*\}');
final _rtfControl = RegExp(r'\\[a-zA-Z]+-?\d* ?');
String _rtf(File f) {
  var s = _plain(f);
  s = s.replaceAll(_rtfGroupSkip, ' ');
  s = s.replaceAllMapped(_rtfHex, (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
  s = s.replaceAll(RegExp(r'\\par\b'), '\n').replaceAll(_rtfControl, '').replaceAll(RegExp(r'[{}]'), '');
  return s;
}

// ---------------------------------------------------------------- Legacy binary (.doc/.xls/.ppt)
/// Pulls readable ASCII and UTF‑16LE runs out of legacy Office binaries.
String _binaryStrings(File f) {
  final raf = f.openSync();
  late List<int> b;
  try {
    b = raf.readSync(min(raf.lengthSync(), 8 << 20));
  } finally {
    raf.closeSync();
  }
  bool printable(int c) => (c >= 0x20 && c < 0x7F) || c == 0x0A || c == 0x0D || c == 0x09;
  final out = StringBuffer();
  final ascii = StringBuffer();
  final wide = StringBuffer();
  void flush(StringBuffer run) {
    if (run.length >= 4) out
      ..write(run)
      ..write(' ');
    run.clear();
  }

  for (var i = 0; i < b.length; i++) {
    final c = b[i];
    if (printable(c)) {
      ascii.writeCharCode(c);
    } else {
      flush(ascii);
    }
    if (i.isEven && i + 1 < b.length) {
      if (printable(c) && b[i + 1] == 0) {
        wide.writeCharCode(c);
      } else {
        flush(wide);
      }
    }
    if (out.length > 200000) break;
  }
  flush(ascii);
  flush(wide);
  return out.toString();
}
