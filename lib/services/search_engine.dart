import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_types.dart';
import '../core/indexed_file.dart';
import '../core/object_terms.dart';
import '../core/text_tools.dart';

enum MatchSource { name, folder, content, imageText, videoContent, objects }

class SearchHit {
  /// [snippet] and [moments] are worked out when first shown: a search can list
  /// hundreds of files, and only the rows on screen need them.
  SearchHit(this.file, this.score, this.sources, String? Function() snippet, this.highlights,
      {List<VideoSegment> Function()? moments, this.objects = const []})
      : _snippet = snippet,
        _moments = moments;
  final IndexedFile file;
  final double score;
  final Set<MatchSource> sources;
  final String? Function() _snippet;
  final List<VideoSegment> Function()? _moments;
  late final String? snippet = _snippet();
  final List<String> highlights;

  /// Videos: the moments where the searched text is shown or spoken, earliest first.
  late final List<VideoSegment> moments = _moments?.call() ?? const [];

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
  /// Lower-cased word → docs whose text contains it. A plain list per word (not a set):
  /// millions of entries, so it's the bulk of the index's memory. Entries left behind
  /// when a file is re-read or removed are harmless: every candidate is confirmed
  /// against the file's real text, and removed files are gone from [_docs].
  final Map<String, List<int>> _words = {};
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
        _words[w] = [id];
        if (_vocabSet.add(w)) _vocab.add(w);
      } else if (post.last != id) {
        post.add(id);
      }
    }
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
    _labelWords.clear();
    _labelKeys.clear();
    _vocab.clear();
    _vocabSet.clear();
    _tokCache.clear();
    _tokCacheVocabLen = 0;
  }

  /// Rebuilds from the stored index in two steps, so the app opens without waiting
  /// for the slow one:
  ///  1. names, folders and image labels – quick; [onNamesReady] fires once they're in.
  ///  2. the text inside files, tokenised off the UI thread in parallel lanes, recently
  ///     changed files first. Searches find a file's text once its batch is in;
  ///     [onContent] reports (done, total) as batches land.
  Future<void> rebuild(
    Iterable<IndexedFile> files, {
    void Function()? onNamesReady,
    void Function(int done, int total)? onContent,
  }) async {
    clear();
    final withText = <IndexedFile>[];
    var n = 0;
    final clock = Stopwatch()..start();
    for (final f in files) {
      upsert(f, contentTf: const {});
      if (f.content.isNotEmpty) withText.add(f);
      if (++n % 500 == 0 && clock.elapsedMilliseconds > 8) {
        await Future<void>.delayed(Duration.zero); // let a frame through
        clock.reset();
      }
    }
    onNamesReady?.call();
    if (withText.isEmpty) return;

    withText.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    final mobile = Platform.isAndroid || Platform.isIOS;
    // Half the cores at most: the rest stay free for the user while the app starts.
    final lanes = (Platform.numberOfProcessors ~/ 2).clamp(1, mobile ? 2 : 4);
    const chunk = 400;
    var next = 0;
    var done = 0;
    onContent?.call(0, withText.length);
    Future<void> lane() async {
      while (next < withText.length) {
        final part = withText.sublist(next, min(next + chunk, withText.length));
        next += part.length;
        final contents = [for (final f in part) f.content];
        final tfs = await compute(_tfBatch, contents);
        final slice = Stopwatch()..start();
        for (var j = 0; j < part.length; j++) {
          if (slice.elapsedMilliseconds > 8) {
            await Future<void>.delayed(Duration.zero); // let a frame through
            slice.reset();
          }
          final f = part[j];
          // Skip files read again or removed meanwhile – their newer entry stands.
          final id = _ids[f.path];
          if (id == null || !identical(_docs[id], f) || !identical(f.content, contents[j])) continue;
          upsert(f, contentTf: tfs[j]);
        }
        done += part.length;
        onContent?.call(done, withText.length);
      }
    }

    await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
  }

  void _removeKeys(int id) {
    for (final w in _labelKeys.remove(id) ?? const <String>[]) {
      final post = _labelWords[w];
      post?.remove(id);
      if (post != null && post.isEmpty) _labelWords.remove(w);
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
        onPartial(run.result(partial: true)); // first screenful only – snippets cost time
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
    final pattern = toks.isEmpty ? RegExp.escape(q) : toks.map(RegExp.escape).join(r'[^\p{L}\p{M}\p{N}]*');
    final re = RegExp(pattern, caseSensitive: false, unicode: true);
    final objWords = objectQueryWords(toks);
    final objKeys = [for (final w in objWords) objectKeys(w)];
    final objCand = _objectCandidates(objKeys);
    return _Run(this, re, toks.length == 1 ? toks.single.toLowerCase() : null, q, toks, _Candidates(this, toks), kinds,
        under, limit,
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

  // Word lists from the previous keystroke: "100 yea" → "100 year" only re-filters them.
  final Map<String, List<String>> _tokCache = {};
  int _tokCacheVocabLen = 0;

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

/// Docs whose text could contain the query: they must contain EVERY typed word (as part
/// of some indexed word). Intersecting all words keeps the set small, so the exact check
/// always reaches the right file. Scanning the vocabulary (hundreds of thousands of
/// words) is done in resumable slices, so typing stays smooth on slow machines too.
class _Candidates {
  _Candidates(this.e, List<String> words)
      : toks = words.map((w) => w.toLowerCase()).where((t) => t.length >= 2).toSet().toList();

  final SearchEngine e;
  final List<String> toks;
  bool done = false;
  bool scanAll = false; // no usable word: every file with text is checked
  Set<int>? result;

  final _perTok = <List<String>>[];
  final _sets = <Set<int>>[];
  int _t = 0;
  // Current word: where its matching vocabulary words come from, and progress.
  List<String>? _src; // last keystroke's list for a shorter word, or null = whole vocabulary
  int _tail = 0, _end = 0, _i = 0, _mi = 0;
  bool _scanning = true;
  var _matched = <String>[];
  var _ids = <int>{};

  String _wordAt(int i) {
    final src = _src;
    if (src == null) return e._vocab[i];
    return i < src.length ? src[i] : e._vocab[_tail + i - src.length];
  }

  void _startWord(String tok) {
    _src = null;
    for (final c in e._tokCache.entries) {
      if (tok.contains(c.key) && e._tokCacheVocabLen <= e._vocab.length) {
        _src = c.value;
        _tail = e._tokCacheVocabLen; // plus words indexed since
        break;
      }
    }
    // The vocabulary only grows; words added while scanning are caught next keystroke.
    _end = _src == null ? e._vocab.length : _src!.length + (e._vocab.length - _tail);
    _i = 0;
    _mi = 0;
    _scanning = true;
    _matched = [];
    _ids = {};
  }

  /// Does work until [out] says the slice is used up; true when finished.
  bool step(bool Function() out) {
    if (done) return true;
    if (toks.isEmpty) {
      scanAll = true;
      return done = true;
    }
    if (_t == 0 && _i == 0 && _mi == 0 && _scanning) _startWord(toks[0]);
    while (_t < toks.length) {
      final tok = toks[_t];
      if (_scanning) {
        while (_i < _end) {
          final w = _wordAt(_i++);
          if (w.contains(tok)) _matched.add(w);
          if ((_i & 4095) == 0 && out()) return false;
        }
        _scanning = false;
      }
      while (_mi < _matched.length) {
        final post = e._words[_matched[_mi++]];
        if (post != null) _ids.addAll(post);
        if (out()) return false; // a common word can list thousands of files
      }
      if (_ids.isEmpty) {
        result = const {};
        return done = true;
      }
      _perTok.add(_matched);
      _sets.add(_ids);
      if (++_t < toks.length) _startWord(toks[_t]);
    }
    e._tokCache
      ..clear()
      ..addAll({for (var i = 0; i < toks.length; i++) toks[i]: _perTok[i]});
    e._tokCacheVocabLen = e._vocab.length;
    // Start from the rarest word, then keep only docs that also have each other word.
    _sets.sort((a, b) => a.length.compareTo(b.length));
    final out0 = _sets.first;
    for (final s in _sets.skip(1)) {
      out0.retainWhere(s.contains);
      if (out0.isEmpty) break;
    }
    result = out0;
    return done = true;
  }
}

/// One search in progress: scans names, then confirms candidate files' text, in slices.
class _Run {
  _Run(this.e, this.re, this.single, this.query, this.toks, this.candidates, this.kinds, this.under, this.limit,
      {required this.objCand, required this.objKeys})
      : qLower = toks.isEmpty ? query.toLowerCase() : toks.join(' ').toLowerCase();

  final SearchEngine e;
  final RegExp re;
  final String? single; // one typed word → fast plain "contains" on names
  final String query;
  final List<String> toks;
  final _Candidates candidates; // built in slices – a keystroke never blocks typing
  Set<int>? cand; // null = check every file with text
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
        if (out()) return false; // its text was checked too – mind the time
      }
      if ((id & 1023) == 0 && out()) return false;
    }

    // One typed character: file names only. Nearly every file's text has it, so
    // checking them all would be slow and the list useless.
    if (query.trim().length < 2) _toCheck ??= const [];

    // phase 2a: which files can contain every typed word (from the word index)
    if (_toCheck == null && !candidates.done) {
      if (!candidates.step(out)) return false;
      cand = candidates.scanAll ? null : candidates.result;
    }

    // phase 2b: text inside files – only candidates from the word index, all of them
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
        // Among images, below exact text matches (≥ 8): a photo that shows a bird ranks after
        // a picture whose text says "bird". (Images list before other files – see kindGroup.)
        found.add(_Found(f, (1 + _objScore(objs) * 0.75) * (1 + 0.15 * exp(-age / 180)), false, false, objects: objs));
      }
    }
    return true;
  }

  /// Order of result groups: images, video & audio, documents (PDF, Word, sheets,
  /// slides), text & code, everything else.
  static int kindGroup(FileKind k) => switch (k) {
        FileKind.image => 0,
        FileKind.video || FileKind.audio => 1,
        FileKind.pdf || FileKind.document || FileKind.spreadsheet || FileKind.presentation => 2,
        FileKind.text => 3,
        _ => 4,
      };

  /// Surer labels rank higher: 0–8 points.
  static double _objScore(List<ImageLabel> objs) =>
      objs.isEmpty ? 0 : 8 * objs.map((l) => l.confidence).reduce(max);

  SearchResult result({bool partial = false}) {
    final limit = partial ? min(this.limit, 60) : this.limit;
    final kindCounts = <FileKind, int>{};
    for (final h in found) {
      kindCounts[h.f.kind] = (kindCounts[h.f.kind] ?? 0) + 1;
    }
    final shown = kinds == null ? List.of(found) : found.where((h) => kinds!.contains(h.f.kind)).toList();
    // Images first, then videos, then documents, then the rest; best matches first in each group.
    shown.sort((a, b) {
      final g = a.group.compareTo(b.group);
      return g != 0 ? g : b.score.compareTo(a.score);
    });
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
          () => h.inContent ? SearchEngine._snippetAt(h.f, re) : null,
          highlights,
          moments: h.inContent ? () => SearchEngine._momentsOf(h.f, re) : null,
          objects: h.objects,
        ),
    ];
    return SearchResult(hits, shown.length, sw.elapsed, kindCounts: kindCounts, more: partial);
  }
}

class _Found {
  _Found(this.f, this.score, this.inName, this.inContent, {this.objects = const []})
      : group = _Run.kindGroup(f.kind);
  final IndexedFile f;
  final int group; // images, videos, documents… – see _Run.kindGroup
  final double score;
  final bool inName, inContent;
  final List<ImageLabel> objects;
}

List<Map<String, int>> _tfBatch(List<String> contents) =>
    [for (final c in contents) contentTermFrequencies(c)];
