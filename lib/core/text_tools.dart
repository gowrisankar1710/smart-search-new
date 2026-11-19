/// Tokenising, stemming and normalisation used by both the index and the query side.
/// Pure Dart so it runs inside extractor isolates.
library;

import 'dart:math';

/// Text kept per file. Large enough for long documents; anything beyond can't be searched.
const int kMaxIndexedChars = 200000;

// Marks (\p{M}) belong to the word: Hindi and Tamil vowel signs and viramas are marks,
// so "हिंदी" and "தமிழ்" stay one word. Zero-width (non-)joiners are dropped first.
final _splitter = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
final _joiners = RegExp('[\u200C\u200D]');
final _camel = RegExp(r'(?<=\p{Ll})(?=\p{Lu})|(?<=\p{L})(?=\p{N})|(?<=\p{N})(?=\p{L})', unicode: true);
final _ctrl = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F�]');
final _spaces = RegExp(r'[ \t\r\f\v ]+');
final _blankLines = RegExp(r'\n\s*\n+');
final _digits = RegExp(r'^\d+$');

const stopWords = <String>{
  'the', 'and', 'of', 'to', 'a', 'in', 'for', 'is', 'on', 'with', 'at', 'by', 'an', 'be',
  'this', 'that', 'it', 'from', 'or', 'as', 'are', 'was', 'were', 'will', 'can', 'has',
  'have', 'had', 'not', 'but', 'my', 'your', 'our', 'you', 'we', 'i',
};

bool isDigits(String s) => _digits.hasMatch(s);

String normalizeContent(String raw) {
  var s = raw.length > kMaxIndexedChars * 3 ? raw.substring(0, kMaxIndexedChars * 3) : raw;
  s = s.replaceAll(_ctrl, ' ').replaceAll(_spaces, ' ').replaceAll(_blankLines, '\n').trim();
  return s.length > kMaxIndexedChars ? s.substring(0, kMaxIndexedChars) : s;
}

/// Light English stemmer – makes "invoices", "invoiced" and "invoice" meet.
String stem(String w) {
  if (w.length <= 3 || isDigits(w)) return w;
  if (w.endsWith('ies') && w.length > 4) return '${w.substring(0, w.length - 3)}y';
  if (w.endsWith('sses')) return w.substring(0, w.length - 2);
  if (w.endsWith('ing') && w.length > 5) return w.substring(0, w.length - 3);
  if (w.endsWith('ed') && w.length > 4) return w.substring(0, w.length - 2);
  if (w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us') && !w.endsWith('is')) {
    return w.substring(0, w.length - 1);
  }
  return w;
}

Iterable<String> rawWords(String text) =>
    text.replaceAll(_joiners, '').split(_splitter).where((w) => w.isNotEmpty);

/// Tokens for a file or folder name. Splits camelCase and letter/digit
/// boundaries ("InvoiceMarch2024" → invoice, march, 2024) and keeps the compound.
Set<String> nameTokens(String name) {
  final out = <String>{};
  for (final w in rawWords(name)) {
    out.add(stem(w.toLowerCase()));
    for (final part in w.split(_camel)) {
      final lp = part.toLowerCase();
      if (lp.length >= 2 || isDigits(lp)) out.add(stem(lp));
    }
  }
  return out;
}

/// Every word of the text, lower-cased and unmodified (no stemming, nothing dropped
/// except single characters and absurdly long runs) – the search narrows candidates with it.
Map<String, int> contentTermFrequencies(String text) {
  final tf = <String, int>{};
  for (final w in rawWords(text.toLowerCase())) {
    if (w.length < 2 || w.length > 64) continue;
    tf[w] = (tf[w] ?? 0) + 1;
  }
  return tf;
}

List<String> queryTerms(String q) {
  final words = rawWords(q.toLowerCase()).toList();
  final meaningful = words.where((w) => !stopWords.contains(w)).toList();
  return (meaningful.isEmpty ? words : meaningful).map(stem).toSet().toList();
}

/// Levenshtein distance with early exit once it exceeds [maxD].
int boundedLevenshtein(String a, String b, int maxD) {
  if ((a.length - b.length).abs() > maxD) return maxD + 1;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    var rowMin = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      final v = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > maxD) return maxD + 1;
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}
