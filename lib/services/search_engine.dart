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
  const SearchResult(this.hits, this.total, this.took, {this.exact = true, this.kindCounts = const {}});
  static const empty = SearchResult([], 0, Duration.zero);
  final List<SearchHit> hits;
  final int total;
  final Duration took;

  /// True when every hit contains the typed words exactly; false for closest-match fallback.
  final bool exact;

  /// Matches per file kind, before the kind filter – drives the filter chip counts.
  final Map<FileKind, int> kindCounts;
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

  List<String> _vocab = const [];
  Map<int, List<String>> _byLen = const {};
  bool _vocabDirty = true;
  DateTime _vocabBuilt = DateTime(2000);

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
      (_name[t] ??= {})[id] = 1;
    }
    for (final t in folderT) {
      (_folder[t] ??= {})[id] = 1;
    }
    var len = 0;
    tf.forEach((t, c) {
      (_content[t] ??= {})[id] = c;
      len += c;
    });
    if (len > 0) {
      _len[id] = len;
      _totalLen += len;
    }
    _keys[id] = _DocKeys(nameT.toList(), folderT.toList(), tf.keys.toList());
    _vocabDirty = true;
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
    _vocabDirty = true;
    _vocab = const [];
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
    _vocabDirty = true;
    _vocabBuilt = DateTime(2000);
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

  void _ensureVocab() {
    if (!_vocabDirty) return;
    // While indexing is streaming in, don't re-sort the vocabulary on every keystroke.
    if (_vocab.isNotEmpty && DateTime.now().difference(_vocabBuilt) < const Duration(seconds: 4)) return;
    final set = <String>{..._name.keys, ..._folder.keys, ..._content.keys};
    _vocab = set.toList()..sort();
    final by = <int, List<String>>{};
    for (final t in _vocab) {
      (by[t.length] ??= []).add(t);
    }
    _byLen = by;
    _vocabDirty = false;
    _vocabBuilt = DateTime.now();
  }

  // ------------------------------------------------------------------ querying
  /// What the search box uses: files containing the exact words if there are any,
  /// otherwise the closest matches (typos, similar words, partial words).
  SearchResult find(String query, {Set<FileKind>? kinds, String? under, int limit = 150}) {
    final sw = Stopwatch()..start();
    final exact = search(query, kinds: kinds, under: under, limit: limit, exact: true);
    final r = exact.allKinds > 0 ? exact : search(query, kinds: kinds, under: under, limit: limit);
    return SearchResult(r.hits, r.total, sw.elapsed, exact: r.exact, kindCounts: r.kindCounts);
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
    final exactInContent = <int>{};
    acc.forEach((id, x) {
      final f = _docs[id];
      if (f == null || (under != null && !p.isWithin(under, f.path))) return;
      if (exact) {
        // Index lookups found candidates; now confirm the exact words really appear.
        final inName = f.nameHasExact(flatQ);
        final inContent = f.contentHasExact(flatQ);
        if (!inName && !inContent) return;
        if (!inName) x.name.fillRange(0, x.name.length, 0);
        if (!inContent) {
          x.content.fillRange(0, x.content.length, 0);
          x.hits.clear();
        } else {
          exactInContent.add(id);
          if (x.content.every((v) => v == 0)) x.content[0] = 1; // all-stop-word queries
        }
        if (inName && x.name.every((v) => v == 0)) x.name[0] = 4;
      }
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
    final kindCounts = <FileKind, int>{};
    for (final h in scored) {
      final k = _docs[h.id]!.kind;
      kindCounts[k] = (kindCounts[k] ?? 0) + 1;
    }
    if (kinds != null) scored.removeWhere((h) => !kinds.contains(_docs[h.id]!.kind));
    scored.sort((a, b) => b.score.compareTo(a.score));

    final phrase = q.toLowerCase();
    final flatPhrase = ' ${compactSpaces(phrase)} ';
    if (exact) {
      for (final h in scored) {
        if (exactInContent.contains(h.id)) {
          h.score += _docs[h.id]!.source == ContentSource.ocr ? 14 : 8;
          h.phrase = true;
        }
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
    } else if (terms.length > 1) {
      for (final h in scored.take(300)) {
        final f = _docs[h.id]!;
        if (f.content.isNotEmpty && f.contentFlat.contains(flatPhrase)) {
          // Exact text found inside the file/image: this is almost certainly the one.
          h.score += f.source == ContentSource.ocr ? 14 : 8;
          h.phrase = true;
        }
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
    }

    final hits = [for (final h in scored.take(limit)) _toHit(h, acc[h.id]!, terms, phrase)];
    return SearchResult(hits, scored.length, sw.elapsed, exact: exact, kindCounts: kindCounts);
  }

  Map<String, double> _expand(String term) {
    final out = <String, double>{term: 1.0};
    for (final s in synonyms[term] ?? const <String>[]) {
      out.putIfAbsent(stem(s), () => 0.65);
    }
    if (term.length >= 2 && _vocab.isNotEmpty) {
      final w = term.length >= 4 ? 0.85 : (term.length == 3 ? 0.6 : 0.4);
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
        for (final cand in _byLen[l] ?? const <String>[]) {
          if (cand.codeUnitAt(0) != term.codeUnitAt(0) && cand.codeUnitAt(1) != term.codeUnitAt(1)) continue;
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
    if (x.nameSub || x.name.any((v) => v > 0)) sources.add(MatchSource.name);
    if (x.folder.any((v) => v > 0)) sources.add(MatchSource.folder);
    final inContent = h.phrase || x.content.any((v) => v > 0);
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
}

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
String compactSpaces(String s) => s.replaceAll(_nonWord, ' ').trim();
