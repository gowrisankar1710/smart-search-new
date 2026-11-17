import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_types.dart';
import '../core/indexed_file.dart';
import '../core/object_terms.dart';
import '../core/text_tools.dart';

enum MatchSource { name, folder, content, imageText, videoContent, objects }

class SearchHit {
  SearchHit(this.file, this.score, this.sources, this.snippet, this.highlights,
      {this.moments = const [], this.objects = const []});
  final IndexedFile file;
  final double score;
  final Set<MatchSource> sources;
  final String? snippet;
  final List<String> highlights;

  /// Videos: the moments where the searched text is shown or spoken, earliest first.
  final List<VideoSegment> moments;

  /// Images: labels that matched the search ("sari", "bird"), most certain first.
  final List<ImageLabel> objects;

  /// Where playback starts when this result is opened.
  VideoSegment? get firstMoment => moments.isEmpty ? null : moments.first;
}

class SearchResult {
  const SearchResult(this.hits, this.total, this.took,
      {this.exact = true, this.kindCounts = const {}, this.more = false});
  static const empty = SearchResult([], 0, Duration.zero);
  final List<SearchHit> hits;
  final int total;
  final Duration took;

  /// Always true: results are literal text matches only.
  final bool exact;

  /// Matches per file kind, before the kind filter – drives the sidebar counts.
  final Map<FileKind, int> kindCounts;

  /// True when there were too many candidates to check them all within the time budget.
  final bool more;
  int get allKinds => kindCounts.values.fold(0, (a, b) => a + b);
}

/// Plain-text search: a file matches when its name, the text inside it, or the text
/// read from an image contains the typed text – anywhere, ignoring upper/lower case.
/// Between typed words the text may have spaces, line breaks, any punctuation or nothing.
///
/// Speed comes from a word index used only to *narrow down* candidates (vocabulary words
/// containing the most distinctive typed word); every result is confirmed against the
/// real text, so nothing unrelated is ever listed.
class SearchEngine {
  final List<IndexedFile?> _docs = [];
  final Map<String, int> _ids = {};
  final Map<String, Set<int>> _words = {}; // lower-cased word → docs whose text contains it
  final Map<int, List<String>> _keys = {};
  final List<String> _vocab = []; // every word ever indexed (append-only; stale entries are harmless)
  final Set<String> _vocabSet = {};
  final Map<String, Set<int>> _labelWords = {}; // image label word → docs showing it
  final Map<int, List<String>> _labelKeys = {};


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
    final words =
        contentTf?.keys ?? (f.content.isEmpty ? const <String>[] : contentTermFrequencies(f.content).keys);
    for (final w in words) {
      final post = _words[w];
      if (post == null) {
        _words[w] = {id};
        if (_vocabSet.add(w)) _vocab.add(w);
      } else {
        post.add(id);
      }
    }
    _keys[id] = words.toList();
    if (f.labels.isNotEmpty) {
      final keys = {for (final l in f.labels) ...labelWords(l.id)}.toList();
      for (final k in keys) {
        (_labelWords[k] ??= {}).add(id);
      }
      _labelKeys[id] = keys;
    }
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
    _words.clear();
    _keys.clear();
    _labelWords.clear();
    _labelKeys.clear();
    _vocab.clear();
    _vocabSet.clear();
    _tokCache.clear();
    _tokCacheVocabLen = 0;
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
        if (++n % 5000 == 0) await Future<void>.delayed(Duration.zero);
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
  }

  void _removeKeys(int id) {
    for (final w in _labelKeys.remove(id) ?? const <String>[]) {
      final post = _labelWords[w];
      post?.remove(id);
      if (post != null && post.isEmpty) _labelWords.remove(w);
    }
    final k = _keys.remove(id);
    if (k == null) return;
    for (final w in k) {
      final post = _words[w];
      if (post == null) continue;
      post.remove(id);
      if (post.isEmpty) _words.remove(w);
    }
  }

  // ------------------------------------------------------------------ querying
  /// Synchronous search (used by tests and small indexes): runs the whole job at once.
  SearchResult find(String query, {Set<FileKind>? kinds, String? under, int limit = 500}) {
    final run = _begin(query, kinds, under, limit);
    if (run == null) return SearchResult.empty;
    while (!run.step(null)) {}
    return run.result();
  }

  /// What the search box uses. Checks EVERY candidate file (no time limit, nothing skipped)
  /// but works in ~8 ms slices so typing and scrolling stay smooth. [onPartial] receives
  /// results as they are found; returns null if [cancelled] turned true (a newer query).
  Future<SearchResult?> findAsync(
    String query, {
    Set<FileKind>? kinds,
    String? under,
    int limit = 500,
    required bool Function() cancelled,
    void Function(SearchResult partial)? onPartial,
  }) async {
    final run = _begin(query, kinds, under, limit);
    if (run == null) return SearchResult.empty;
    final sinceEmit = Stopwatch()..start();
    while (!run.step(const Duration(milliseconds: 8))) {
      if (onPartial != null && sinceEmit.elapsedMilliseconds > 150) {
        onPartial(run.result(partial: true));
        sinceEmit.reset();
      }
      await Future<void>.delayed(Duration.zero);
      if (cancelled()) return null;
    }
    return run.result();
  }

  _Run? _begin(String query, Set<FileKind>? kinds, String? under, int limit) {
    final q = query.trim();
    if (q.isEmpty || _ids.isEmpty) return null;
    final toks = rawWords(q).toList();
    // Typed words must appear in this order. Between them the text may have spaces,
    // line breaks, any punctuation – or nothing ("100years" in PDFs). Case is ignored.
    final pattern = toks.isEmpty ? RegExp.escape(q) : toks.map(RegExp.escape).join(r'[^\p{L}\p{N}]*');
    final re = RegExp(pattern, caseSensitive: false, unicode: true);
    final cand = toks.isEmpty ? null : _contentCandidates(toks);
    final objWords = objectQueryWords(toks);
    final objKeys = [for (final w in objWords) objectKeys(w)];
    final objCand = _objectCandidates(objKeys);
    return _Run(this, re, toks.length == 1 ? toks.single.toLowerCase() : null, q, toks, cand, kinds, under, limit,
        objCand: objCand, objKeys: {for (final k in objKeys) ...k});
  }

  /// Images showing EVERY thing named in the query ("woman saree" → people AND sari).
  Set<int> _objectCandidates(List<Set<String>> perWord) {
    if (perWord.isEmpty || _labelWords.isEmpty) return const {};
    Set<int>? out;
    for (final keys in perWord) {
      final ids = <int>{};
      for (final k in keys) {
        ids.addAll(_labelWords[k] ?? const {});
      }
      out = out == null ? ids : (out..retainWhere(ids.contains));
      if (out.isEmpty) return const {};
    }
    return out ?? const {};
  }

  /// Docs whose text could contain the query: they must contain EVERY typed word
  /// (as part of some indexed word). Intersecting all words keeps the set small, so the
  /// exact check below always reaches the right file. null = can't narrow down (scan all).
  Set<int>? _contentCandidates(List<String> words) {
    final toks = words.map((w) => w.toLowerCase()).where((t) => t.length >= 2).toSet().toList();
    if (toks.isEmpty) return null;

    final perTok = [for (final t in toks) _wordsContaining(t)];
    _tokCache
      ..clear()
      ..addAll({for (var i = 0; i < toks.length; i++) toks[i]: perTok[i]});
    _tokCacheVocabLen = _vocab.length;

    // Start from the rarest word, then keep only docs that also have each other word.
    final sets = <Set<int>>[];
    for (final words in perTok) {
      final ids = <int>{};
      for (final w in words) {
        final post = _words[w];
        if (post != null) ids.addAll(post);
      }
      if (ids.isEmpty) return const {};
      sets.add(ids);
    }
    sets.sort((a, b) => a.length.compareTo(b.length));
    final out = sets.first;
    for (final s in sets.skip(1)) {
      out.retainWhere(s.contains);
      if (out.isEmpty) break;
    }
    return out;
  }

  // Word lists from the previous keystroke: "100 yea" → "100 year" only re-filters them.
  final Map<String, List<String>> _tokCache = {};
  int _tokCacheVocabLen = 0;

  /// Every indexed word that contains [tok].
  List<String> _wordsContaining(String tok) {
    for (final e in _tokCache.entries) {
      if (tok.contains(e.key) && _tokCacheVocabLen <= _vocab.length) {
        return [
          for (final w in e.value)
            if (w.contains(tok)) w,
          for (var i = _tokCacheVocabLen; i < _vocab.length; i++)
            if (_vocab[i].contains(tok)) _vocab[i],
        ];
      }
    }
    return [
      for (final w in _vocab)
        if (w.contains(tok)) w,
    ];
  }

  static double _score(IndexedFile f, bool inName, bool inContent, RegExp re, String qLower, int now) {
    var s = 0.0;
    if (inName) {
      s += 20;
      if (f.nameLower.startsWith(qLower)) s += 4; // name begins with the typed text
    }
    if (inContent) {
      s += switch (f.source) {
        ContentSource.ocr => 14,
        ContentSource.video => 12,
        _ => 8,
      };
      s += re.allMatches(f.content).take(5).length;
    }
    final ageDays = max(0, now - f.modifiedMs) / 86400000;
    return s * (1 + 0.15 * exp(-ageDays / 180));
  }

  /// Up to [max] video moments containing a match, earliest first. Each is timed to the
  /// segment holding the match's first character (for speech: the exact word) and carries
  /// the surrounding words as its text.
  static List<VideoSegment> _momentsOf(IndexedFile f, RegExp re, {int max = 8}) {
    if (f.segments.isEmpty) return const [];
    final text = f.content;
    final out = <VideoSegment>[];
    VideoSegment? last;
    for (final m in re.allMatches(text)) {
      final seg = f.segmentAt(m.start);
      if (seg == null || identical(seg, last)) continue;
      last = seg;
      out.add(VideoSegment(seg.seconds, _around(text, m.start, m.end)));
      if (out.length >= 40) break;
    }
    out.sort((a, b) => a.seconds.compareTo(b.seconds));
    return out.length > max ? out.sublist(0, max) : out;
  }

  /// A short, single-line piece of [text] around [start]..[end], cut at spaces.
  static String _around(String text, int start, int end) {
    var a = (start - 50).clamp(0, text.length);
    var b = (end + 70).clamp(0, text.length);
    final flat = text.replaceAll('\n', ' ');
    if (a > 0) {
      final sp = flat.indexOf(' ', a);
      if (sp >= 0 && sp < start) a = sp + 1;
    }
    if (b < flat.length) {
      final sp = flat.lastIndexOf(' ', b);
      if (sp > end) b = sp;
    }
    return '${a > 0 ? '… ' : ''}${flat.substring(a, b).trim()}${b < flat.length ? ' …' : ''}';
  }

  /// Snippet around the first real match.
  static String? _snippetAt(IndexedFile f, RegExp re) {
    final text = f.content;
    final m = re.firstMatch(text);
    if (m == null) return null;
    final best = m.start, len = m.end - m.start;
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
}

/// One search in progress: scans names, then confirms candidate files' text, in slices.
class _Run {
  _Run(this.e, this.re, this.single, this.query, this.toks, this.cand, this.kinds, this.under, this.limit,
      {required this.objCand, required this.objKeys})
      : qLower = toks.isEmpty ? query.toLowerCase() : toks.join(' ').toLowerCase();

  final SearchEngine e;
  final RegExp re;
  final String? single; // one typed word → fast plain "contains" on names
  final String query;
  final List<String> toks;
  final Set<int>? cand; // null = check every file with text
  final Set<int> objCand; // images whose labels name everything typed
  final Set<String> objKeys; // label words the query asks for
  final Set<FileKind>? kinds;
  final String? under;
  final int limit;
  final String qLower;
  final now = DateTime.now().millisecondsSinceEpoch;
  final sw = Stopwatch()..start();

  final found = <_Found>[];
  final seen = <int>{};
  int _nameId = 0; // phase 1 cursor
  List<IndexedFile>? _toCheck; // phase 2 work list
  int _ci = 0;
  final _textIds = <int>{}; // found by name or text – object matches are added to them
  bool _objectsDone = false;

  List<ImageLabel> _matchedLabels(IndexedFile f) => [
        for (final l in f.labels)
          if (labelWords(l.id).any(objKeys.contains)) l,
      ];

  bool _inScope(IndexedFile f) => under == null || p.isWithin(under!, f.path);
  bool _nameHas(IndexedFile f) => single != null ? f.nameLower.contains(single!) : re.hasMatch(f.name);

  /// Does a slice of work; returns true when finished. [slice] null = run to the end.
  bool step(Duration? slice) {
    final clock = Stopwatch()..start();
    bool out() => slice != null && clock.elapsed > slice;
    final docs = e._docs;

    // phase 1: file names (cheap, every file)
    while (_nameId < docs.length) {
      final id = _nameId++;
      final f = docs[id];
      if (f != null && _inScope(f) && _nameHas(f)) {
        seen.add(id);
        final inContent = f.content.isNotEmpty && re.hasMatch(f.content);
        final objs = objCand.contains(id) ? _matchedLabels(f) : const <ImageLabel>[];
        found.add(_Found(f, SearchEngine._score(f, true, inContent, re, qLower, now) + _objScore(objs), true, inContent,
            objects: objs));
        _textIds.add(id);
      }
      if ((id & 1023) == 0 && out()) return false;
    }

    // phase 2: text inside files – only candidates from the word index, all of them
    final list = _toCheck ??= [
      if (cand == null)
        for (var id = 0; id < docs.length; id++)
          if (docs[id] case final f? when f.content.isNotEmpty && !seen.contains(id) && _inScope(f)) f,
      if (cand != null)
        for (final id in cand!)
          if (!seen.contains(id))
            if (docs[id] case final f? when f.content.isNotEmpty && _inScope(f)) f,
    ]..sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs)); // newest first → shows up first
    while (_ci < list.length) {
      final f = list[_ci++];
      if (re.hasMatch(f.content)) {
        final id = e._ids[f.path]!;
        final objs = objCand.contains(id) ? _matchedLabels(f) : const <ImageLabel>[];
        found.add(_Found(f, SearchEngine._score(f, false, true, re, qLower, now) + _objScore(objs), false, true,
            objects: objs));
        _textIds.add(id);
      }
      if (out()) return false; // phase 3 still to come
    }

    // phase 3: pictures that SHOW what was typed (objects, scenes, clothing)
    if (!_objectsDone) {
      _objectsDone = true;
      for (final id in objCand) {
        if (_textIds.contains(id)) continue;
        final f = docs[id];
        if (f == null || !_inScope(f)) continue;
        final objs = _matchedLabels(f);
        if (objs.isEmpty) continue;
        final age = max(0, now - f.modifiedMs) / 86400000;
        // Below exact text matches (≥ 8): a photo that shows a bird ranks after a file that says "bird".
        found.add(_Found(f, (1 + _objScore(objs) * 0.75) * (1 + 0.15 * exp(-age / 180)), false, false, objects: objs));
      }
    }
    return true;
  }

  /// Surer labels rank higher: 0–8 points.
  static double _objScore(List<ImageLabel> objs) =>
      objs.isEmpty ? 0 : 8 * objs.map((l) => l.confidence).reduce(max);

  SearchResult result({bool partial = false}) {
    final kindCounts = <FileKind, int>{};
    for (final h in found) {
      kindCounts[h.f.kind] = (kindCounts[h.f.kind] ?? 0) + 1;
    }
    final shown = kinds == null ? List.of(found) : found.where((h) => kinds!.contains(h.f.kind)).toList();
    shown.sort((a, b) => b.score.compareTo(a.score));
    final highlights = [query, ...toks];
    final hits = [
      for (final h in shown.take(limit))
        SearchHit(
          h.f,
          h.score,
          {
            if (h.inName) MatchSource.name,
            if (h.objects.isNotEmpty) MatchSource.objects,
            if (h.inContent)
              switch (h.f.source) {
                ContentSource.ocr => MatchSource.imageText,
                ContentSource.video => MatchSource.videoContent,
                _ => MatchSource.content,
              },
          },
          h.inContent ? SearchEngine._snippetAt(h.f, re) : null,
          highlights,
          moments: h.inContent ? SearchEngine._momentsOf(h.f, re) : const [],
          objects: h.objects,
        ),
    ];
    return SearchResult(hits, shown.length, sw.elapsed, kindCounts: kindCounts, more: partial);
  }
}

class _Found {
  _Found(this.f, this.score, this.inName, this.inContent, {this.objects = const []});
  final IndexedFile f;
  final double score;
  final bool inName, inContent;
  final List<ImageLabel> objects;
}

List<Map<String, int>> _tfBatch(List<String> contents) =>
    [for (final c in contents) contentTermFrequencies(c)];
