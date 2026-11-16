import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_types.dart';
import '../core/indexed_file.dart';
import '../core/synonyms.dart';
import '../core/text_tools.dart';

enum MatchSource { name, folder, content, imageText }

class SearchHit {
  SearchHit(this.file, this.score, this.sources, this.snippet, this.highlights);
  final IndexedFile file;
  final double score;
  final Set<MatchSource> sources;
  final String? snippet;
  final List<String> highlights;
}

class SearchResult {
  const SearchResult(this.hits, this.total, this.took,
      {this.exact = true, this.kindCounts = const {}, this.more = false});
  static const empty = SearchResult([], 0, Duration.zero);
  final List<SearchHit> hits;
  final int total;
  final Duration took;

  /// True when every hit contains the typed words exactly; false for closest-match fallback.
  final bool exact;

  /// Matches per file kind, before the kind filter – drives the filter chip counts.
  final Map<FileKind, int> kindCounts;

  /// True when there were too many candidates to confirm them all within the time budget.
  final bool more;
  int get allKinds => kindCounts.values.fold(0, (a, b) => a + b);
}

/// In-memory inverted index with relevance ranking:
///  • three fields – file name, parent folders, document/image text
///  • BM25 scoring on content, IDF-weighted name/folder matches
///  • prefix completion, typo tolerance (edit distance), synonym/concept expansion
///  • whole-query substring match on file names ("nvoice" finds "Invoice_2024.pdf")
///  • exact-phrase and recency boosts
class SearchEngine {
  final List<IndexedFile?> _docs = [];
  final Map<String, int> _ids = {};
  final Map<String, Map<int, int>> _name = {};
  final Map<String, Map<int, int>> _folder = {};
  final Map<String, Map<int, int>> _content = {};
  final Map<int, _DocKeys> _keys = {};
  final Map<int, int> _len = {};
  int _totalLen = 0;

  // Sorted vocabulary for prefix completion, grown incrementally (never fully re-sorted).
  List<String> _vocab = [];
  final Set<String> _vocabSet = {};
  final Set<String> _newTerms = {};
  DateTime _vocabMerged = DateTime(2000);
  // Typo candidates bucketed by (length, first letter) and (length, second letter).
  final Map<int, List<String>> _byLenFirst = {};
  final Map<int, List<String>> _byLenSecond = {};

  int get docCount => _ids.length;

  // ------------------------------------------------------------------ indexing
  void upsert(IndexedFile f, {Map<String, int>? contentTf}) {
    final existing = _ids[f.path];
    final int id;
    if (existing == null) {
      id = _docs.length;
      _docs.add(f);
      _ids[f.path] = id;
    } else {
      id = existing;
      _removeKeys(id);
      _docs[id] = f;
    }
    final nameT = nameTokens(f.name);
    final folderT = _folderTokens(f.folder);
    final tf = contentTf ?? (f.content.isEmpty ? const <String, int>{} : contentTermFrequencies(f.content));
    for (final t in nameT) {
      _post(_name, t)[id] = 1;
    }
    for (final t in folderT) {
      _post(_folder, t)[id] = 1;
    }
    var len = 0;
    tf.forEach((t, c) {
      _post(_content, t)[id] = c;
      len += c;
    });
    if (len > 0) {
      _len[id] = len;
      _totalLen += len;
    }
    _keys[id] = _DocKeys(nameT.toList(), folderT.toList(), tf.keys.toList());
  }

  Map<int, int> _post(Map<String, Map<int, int>> m, String t) {
    final existing = m[t];
    if (existing != null) return existing;
    if (!_vocabSet.contains(t)) _newTerms.add(t);
    return m[t] = {};
  }

  void remove(String path) {
    final id = _ids.remove(path);
    if (id == null) return;
    _removeKeys(id);
    _docs[id] = null;
  }

  void clear() {
    _docs.clear();
    _ids.clear();
    _name.clear();
    _folder.clear();
    _content.clear();
    _keys.clear();
    _len.clear();
    _totalLen = 0;
    _vocab = [];
    _vocabSet.clear();
    _newTerms.clear();
    _byLenFirst.clear();
    _byLenSecond.clear();
    _vocabMerged = DateTime(2000);
  }

  /// Rebuilds from the stored index; tokenising of document text happens off the UI thread.
  Future<void> rebuild(Iterable<IndexedFile> files) async {
    clear();
    final withText = <IndexedFile>[];
    var n = 0;
    for (final f in files) {
      if (f.content.isNotEmpty) {
        withText.add(f);
      } else {
        upsert(f, contentTf: const {});
        if (++n % 3000 == 0) await Future<void>.delayed(Duration.zero);
      }
    }
    const chunk = 300;
    for (var i = 0; i < withText.length; i += chunk) {
      final part = withText.sublist(i, min(i + chunk, withText.length));
      final tfs = await compute(_tfBatch, [for (final f in part) f.content]);
      for (var j = 0; j < part.length; j++) {
        upsert(part[j], contentTf: tfs[j]);
      }
    }
    _vocabMerged = DateTime(2000);
    _ensureVocab(); // build now, not on the first keystroke
  }

  void _removeKeys(int id) {
    final k = _keys.remove(id);
    if (k == null) return;
    for (final t in k.name) {
      _drop(_name, t, id);
    }
    for (final t in k.folder) {
      _drop(_folder, t, id);
    }
    for (final t in k.content) {
      _drop(_content, t, id);
    }
    _totalLen -= _len.remove(id) ?? 0;
  }

  static void _drop(Map<String, Map<int, int>> m, String t, int id) {
    final post = m[t];
    if (post == null) return;
    post.remove(id);
    if (post.isEmpty) m.remove(t);
  }

  static Set<String> _folderTokens(String folder) {
    final parts = p.split(folder);
    final last = parts.length > 3 ? parts.sublist(parts.length - 3) : parts;
    return {for (final part in last) ...nameTokens(part)};
  }

  /// Merges words seen since the last call into the sorted vocabulary – O(new log new + n),
  /// throttled while indexing streams in so typing never waits on it.
  void _ensureVocab() {
    if (_newTerms.isEmpty) return;
    if (_vocab.isNotEmpty && DateTime.now().difference(_vocabMerged) < const Duration(seconds: 8)) return;
    final fresh = _newTerms.where(_vocabSet.add).toList()..sort();
    _newTerms.clear();
    _vocabMerged = DateTime.now();
    if (fresh.isEmpty) return;
    for (final t in fresh) {
      (_byLenFirst[_bucket(t.length, t.codeUnitAt(0))] ??= []).add(t);
      if (t.length > 1) (_byLenSecond[_bucket(t.length, t.codeUnitAt(1))] ??= []).add(t);
    }
    if (_vocab.isEmpty) {
      _vocab = fresh;
      return;
    }
    final merged = List<String>.filled(_vocab.length + fresh.length, '');
    var i = 0, j = 0, k = 0;
    while (i < _vocab.length && j < fresh.length) {
      merged[k++] = _vocab[i].compareTo(fresh[j]) <= 0 ? _vocab[i++] : fresh[j++];
    }
    while (i < _vocab.length) {
      merged[k++] = _vocab[i++];
    }
    while (j < fresh.length) {
      merged[k++] = fresh[j++];
    }
    _vocab = merged;
  }

  static int _bucket(int len, int unit) => len * 0x10000 + unit;

  // ------------------------------------------------------------------ querying
  /// What the search box uses: ONLY files whose name or inside text (documents and
  /// text read from images) contains exactly the typed words, in that order.
  /// Case, punctuation and line breaks are ignored. Words must be whole words, except
  /// the last one while it is still being typed ("wild th" → "wild things").
  /// No typos, synonyms, similar words or folder-name matches.
  SearchResult find(String query, {Set<FileKind>? kinds, String? under, int limit = 150}) {
    final sw = Stopwatch()..start();
    final words = rawWords(query.toLowerCase()).toList();
    if (words.isEmpty || _ids.isEmpty) return SearchResult.empty;
    _ensureVocab();

    // Is the last word finished (followed by a space/punctuation)?
    final lastDone = RegExp(r'[^\p{L}\p{N}]$', unicode: true).hasMatch(query);
    final full = lastDone ? words : words.sublist(0, words.length - 1);
    final partial = lastDone ? null : words.last;

    // ---- candidates from the index (cheap); the regex below is the real judge
    Set<int>? cand;
    void intersect(Iterable<int> ids) {
      cand = cand == null ? ids.toSet() : (cand!..retainAll(ids.toSet()));
    }

    for (final w in full) {
      final t = stem(w);
      final indexable = w.length >= 2 && !stopWords.contains(w);
      if (!indexable && !_name.containsKey(t)) continue; // let verification handle it
      intersect({...?_name[t]?.keys, if (indexable) ...?_content[t]?.keys});
      if (cand!.isEmpty) break;
    }
    if (cand == null && partial != null) {
      // Only an unfinished word so far: every indexed word starting with it.
      final prefix = partial.length > 3 ? stem(partial) : partial;
      final ids = <int>{};
      var i = _lowerBound(_vocab, prefix);
      for (var n = 0; i < _vocab.length && n < 3000 && _vocab[i].startsWith(prefix); i++, n++) {
        ids
          ..addAll(_name[_vocab[i]]?.keys ?? const <int>[])
          ..addAll(_content[_vocab[i]]?.keys ?? const <int>[]);
      }
      cand = ids;
    }
    if (cand == null || cand!.isEmpty) {
      return SearchResult(const [], 0, sw.elapsed, exact: true);
    }

    // ---- verify: the typed words must really appear, in order
    final body = words.map(RegExp.escape).join(r'[^\p{L}\p{N}]+');
    final re = RegExp('(?<![\\p{L}\\p{N}])$body${partial == null ? r'(?![\p{L}\p{N}])' : ''}', unicode: true);
    final ordered = [
      for (final id in cand!)
        if (_docs[id] case final f? when under == null || p.isWithin(under, f.path)) f,
    ]..sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs)); // recent first if the budget runs out

    final now = DateTime.now().millisecondsSinceEpoch;
    final found = <(IndexedFile, double, bool, bool)>[];
    var more = false;
    final clock = Stopwatch()..start();
    for (var i = 0; i < ordered.length; i++) {
      if (i >= 20000 || (i > 500 && clock.elapsedMilliseconds > 120)) {
        more = true;
        break;
      }
      final f = ordered[i];
      final inName = f.nameFlats.any(re.hasMatch);
      final inContent = f.content.isNotEmpty && re.hasMatch(f.contentLower);
      if (!inName && !inContent) continue;
      var s = 0.0;
      if (inName) s += 20;
      if (inContent) {
        s += f.source == ContentSource.ocr ? 14 : 8;
        s += min(5, re.allMatches(f.contentLower).take(5).length).toDouble();
      }
      s *= 1 + 0.15 * exp(-(max(0, now - f.modifiedMs) / 86400000) / 180);
      found.add((f, s, inName, inContent));
    }

    final kindCounts = <FileKind, int>{};
    for (final h in found) {
      kindCounts[h.$1.kind] = (kindCounts[h.$1.kind] ?? 0) + 1;
    }
    final shown = kinds == null ? found : found.where((h) => kinds.contains(h.$1.kind)).toList();
    shown.sort((a, b) => b.$2.compareTo(a.$2));

    final phrase = words.join(' ');
    final highlights = [phrase, ...words];
    final hits = [
      for (final (f, s, inName, inContent) in shown.take(limit))
        SearchHit(
          f,
          s,
          {
            if (inName) MatchSource.name,
            if (inContent) f.source == ContentSource.ocr ? MatchSource.imageText : MatchSource.content,
          },
          inContent ? _snippetAt(f, re) : null,
          highlights,
        ),
    ];
    return SearchResult(hits, shown.length, sw.elapsed, exact: true, kindCounts: kindCounts, more: more);
  }

  /// Snippet around the first real match of [re].
  static String? _snippetAt(IndexedFile f, RegExp re) {
    final m = re.firstMatch(f.contentLower);
    if (m == null) return null;
    final text = f.content;
    final best = m.start, len = m.end - m.start;
    if (best >= text.length) return null;
    var start = max(0, best - 60);
    var end = min(text.length, best + len + 140);
    if (start > 0) {
      final sp = text.indexOf(' ', start);
      if (sp >= 0 && sp < best) start = sp + 1;
    }
    if (end < text.length) {
      final sp = text.lastIndexOf(' ', end);
      if (sp > best + len) end = sp;
    }
    return '${start > 0 ? '… ' : ''}${text.substring(start, end).replaceAll('\n', ' ').trim()}${end < text.length ? ' …' : ''}';
  }

  /// [exact]: only files whose name or inside text contains the query's exact words
  /// (case- and punctuation-insensitive). No typos, synonyms, prefixes or folder matches.
  SearchResult search(String query,
      {Set<FileKind>? kinds, String? under, int limit = 150, bool exact = false}) {
    final sw = Stopwatch()..start();
    final q = query.trim();
    if (q.isEmpty || _ids.isEmpty) return SearchResult.empty;
    _ensureVocab();

    final terms = queryTerms(q);
    if (terms.isEmpty) return SearchResult.empty;
    final n = max(1, docCount);
    final avgLen = _len.isEmpty ? 1.0 : max(1.0, _totalLen / _len.length);
    final acc = <int, _Acc>{};
    _Acc a(int id) => acc[id] ??= _Acc(terms.length);

    for (var ti = 0; ti < terms.length; ti++) {
      (exact ? {terms[ti]: 1.0} : _expand(terms[ti])).forEach((tok, w) {
        final np = _name[tok];
        if (np != null) {
          final s = w * 4.0 * _idf(np.length, n);
          for (final id in np.keys) {
            final x = a(id);
            if (s > x.name[ti]) x.name[ti] = s;
          }
        }
        if (w < 0.5) return; // very short prefixes only match names
        final fp = exact ? null : _folder[tok];
        if (fp != null) {
          final s = w * 1.2 * _idf(fp.length, n);
          for (final id in fp.keys) {
            final x = a(id);
            if (s > x.folder[ti]) x.folder[ti] = s;
          }
        }
        final cp = _content[tok];
        if (cp != null) {
          final idf = _idf(cp.length, n);
          cp.forEach((id, tf) {
            final dl = _len[id] ?? 0;
            final s = w * idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * dl / avgLen));
            final x = a(id);
            if (s > x.content[ti]) x.content[ti] = s;
            x.hits.add(tok);
          });
        }
      });
    }

    // Whole-query substring against file names catches fragments and missing letters.
    final compactQ = compact(q);
    if (!exact && compactQ.length >= 3) {
      for (var id = 0; id < _docs.length; id++) {
        final f = _docs[id];
        if (f != null && f.compactName.contains(compactQ)) a(id).nameSub = true;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final scored = <_Scored>[];
    var bestMatched = 0;
    final flatQ = ' ${compactSpaces(q.toLowerCase())} ';
    final phraseRe = _phraseRegex(q);
    acc.forEach((id, x) {
      final f = _docs[id];
      if (f == null || (under != null && !p.isWithin(under, f.path))) return;
      var matched = 0;
      var s = 0.0;
      for (var i = 0; i < terms.length; i++) {
        final t = x.name[i] + x.folder[i] + x.content[i];
        if (t > 0) matched++;
        s += t;
      }
      if (x.nameSub) {
        s += 6.0;
        matched = terms.length;
      }
      if (matched == 0) return;
      final coverage = matched / terms.length;
      s *= coverage * coverage;
      final ageDays = max(0, now - f.modifiedMs) / 86400000;
      s *= 1 + 0.15 * exp(-ageDays / 180);
      bestMatched = max(bestMatched, matched);
      scored.add(_Scored(id, s, matched));
    });

    // If some files match every word, drop the ones matching less than half.
    if (terms.length > 1 && bestMatched == terms.length) {
      scored.removeWhere((h) => h.matched * 2 < terms.length);
    }
    var more = false;
    if (exact) {
      // Index lookups found candidates; confirm the exact words really appear, best first,
      // within a time budget so typing stays smooth on huge indexes.
      // An exact phrase needs every word, so files missing one can't qualify – skip them cheaply.
      scored.removeWhere((h) => h.matched < terms.length);
      scored.sort((a, b) => b.score.compareTo(a.score));
      final kept = <_Scored>[];
      final clock = Stopwatch()..start();
      for (var i = 0; i < scored.length; i++) {
        if (i >= 5000 || (i > 300 && clock.elapsedMilliseconds > 70)) {
          more = true;
          break;
        }
        final h = scored[i];
        final f = _docs[h.id]!;
        h.nameOk = f.nameHasExact(flatQ);
        h.contentOk = f.content.isNotEmpty && phraseRe.hasMatch(f.contentLower);
        if (!h.nameOk! && !h.contentOk!) continue;
        if (h.contentOk!) {
          h.score += f.source == ContentSource.ocr ? 14 : 8;
          h.phrase = true;
        }
        kept.add(h);
      }
      scored
        ..clear()
        ..addAll(kept);
    }
    final kindCounts = <FileKind, int>{};
    for (final h in scored) {
      final k = _docs[h.id]!.kind;
      kindCounts[k] = (kindCounts[k] ?? 0) + 1;
    }
    if (kinds != null) scored.removeWhere((h) => !kinds.contains(_docs[h.id]!.kind));
    scored.sort((a, b) => b.score.compareTo(a.score));

    final phrase = q.toLowerCase();
    if (!exact && terms.length > 1) {
      for (final h in scored.take(300)) {
        final f = _docs[h.id]!;
        if (f.content.isNotEmpty && phraseRe.hasMatch(f.contentLower)) {
          // Exact text found inside the file/image: this is almost certainly the one.
          h.score += f.source == ContentSource.ocr ? 14 : 8;
          h.phrase = true;
        }
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
    }

    final hits = [for (final h in scored.take(limit)) _toHit(h, acc[h.id]!, terms, phrase)];
    return SearchResult(hits, scored.length, sw.elapsed, exact: exact, kindCounts: kindCounts, more: more);
  }

  /// Whole-word, punctuation/line-break tolerant phrase matcher: "wild things" matches "Wild\nThings!".
  static RegExp _phraseRegex(String q) {
    final words = rawWords(q.toLowerCase()).map(RegExp.escape).toList();
    return RegExp('(?<![\\p{L}\\p{N}])${words.join('[^\\p{L}\\p{N}]+')}(?![\\p{L}\\p{N}])', unicode: true);
  }

  Map<String, double> _expand(String term) {
    final out = <String, double>{term: 1.0};
    for (final s in synonyms[term] ?? const <String>[]) {
      out.putIfAbsent(stem(s), () => 0.65);
    }
    if (term.length >= 2 && _vocab.isNotEmpty) { // one letter would expand to half the index
      final w = term.length >= 4 ? 0.85 : (term.length == 3 ? 0.6 : 0.45);
      var i = _lowerBound(_vocab, term);
      var count = 0;
      while (i < _vocab.length && count < 60 && _vocab[i].startsWith(term)) {
        out.putIfAbsent(_vocab[i], () => w);
        i++;
        count++;
      }
    }
    if (term.length >= 4 && !isDigits(term)) {
      final maxD = term.length >= 8 ? 2 : 1;
      var count = 0;
      outer:
      for (var l = term.length - maxD; l <= term.length + maxD; l++) {
        for (final cand in [
          ...?_byLenFirst[_bucket(l, term.codeUnitAt(0))],
          ...?_byLenSecond[_bucket(l, term.codeUnitAt(1))],
        ]) {
          if (out.containsKey(cand)) continue;
          final d = boundedLevenshtein(term, cand, maxD);
          if (d <= maxD) {
            out[cand] = d == 1 ? 0.7 : 0.5;
            if (++count >= 25) break outer;
          }
        }
      }
    }
    return out;
  }

  SearchHit _toHit(_Scored h, _Acc x, List<String> terms, String phrase) {
    final f = _docs[h.id]!;
    final sources = <MatchSource>{};
    if (h.nameOk ?? (x.nameSub || x.name.any((v) => v > 0))) sources.add(MatchSource.name);
    if (x.folder.any((v) => v > 0)) sources.add(MatchSource.folder);
    final inContent = h.contentOk ?? (h.phrase || x.content.any((v) => v > 0));
    if (inContent) sources.add(f.source == ContentSource.ocr ? MatchSource.imageText : MatchSource.content);

    String? snippet;
    if (inContent) {
      final words = x.hits.toList()..sort((a, b) => b.length.compareTo(a.length));
      final needles = h.phrase ? [phrase, ...words] : words;
      snippet = _snippet(f, needles);
    }
    final highlights = <String>{
      ...terms.where((t) => t.length >= 2),
      ...x.hits,
      if (h.phrase) phrase,
    }.toList();
    return SearchHit(f, h.score, sources, snippet, highlights);
  }

  static String? _snippet(IndexedFile f, List<String> needles) {
    final lower = f.contentLower;
    final text = f.content;
    var best = -1;
    var len = 0;
    for (final nd in needles.take(12)) {
      final i = lower.indexOf(nd);
      if (i >= 0 && (best < 0 || i < best)) {
        best = i;
        len = nd.length;
      }
    }
    if (best < 0 || best >= text.length) return null;
    var start = max(0, best - 60);
    var end = min(text.length, best + len + 140);
    if (start > 0) {
      final sp = text.indexOf(' ', start);
      if (sp >= 0 && sp < best) start = sp + 1;
    }
    if (end < text.length) {
      final sp = text.lastIndexOf(' ', end);
      if (sp > best + len) end = sp;
    }
    return '${start > 0 ? '… ' : ''}${text.substring(start, end).replaceAll('\n', ' ').trim()}${end < text.length ? ' …' : ''}';
  }

  static double _idf(int df, int n) => log(1 + (n - df + 0.5) / (df + 0.5));

  static int _lowerBound(List<String> list, String key) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

List<Map<String, int>> _tfBatch(List<String> contents) =>
    [for (final c in contents) contentTermFrequencies(c)];

class _DocKeys {
  const _DocKeys(this.name, this.folder, this.content);
  final List<String> name, folder, content;
}

class _Acc {
  _Acc(int n)
      : name = List.filled(n, 0.0),
        folder = List.filled(n, 0.0),
        content = List.filled(n, 0.0);
  final List<double> name, folder, content;
  final Set<String> hits = {};
  bool nameSub = false;
}

class _Scored {
  _Scored(this.id, this.score, this.matched);
  final int id;
  double score;
  final int matched;
  bool phrase = false;
  bool? nameOk, contentOk; // set by exact verification
}

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
String compactSpaces(String s) => s.replaceAll(_nonWord, ' ').trim();
