import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_file_search/core/indexed_file.dart';
import 'package:smart_file_search/services/index_store.dart';
import 'package:smart_file_search/services/indexer.dart';
import 'package:smart_file_search/services/locations.dart';
import 'package:smart_file_search/services/ocr_service.dart';
import 'package:smart_file_search/services/search_engine.dart';
import 'package:smart_file_search/services/video_service.dart';

void main() {
  test('SRT and VTT cues become timestamped lines', () {
    const srt = '1\n00:00:01,500 --> 00:00:03,000\nHello <i>world</i>\n\n'
        '2\n00:01:05,250 --> 00:01:07,000\nquarterly\nrevenue report\n';
    final s = parseSubtitles(srt);
    expect(s.map((e) => e.seconds), [1.5, 65.25]);
    expect(s.last.text, 'quarterly revenue report');
    expect(s.first.text, 'Hello world');

    const vtt = 'WEBVTT\n\n00:02.000 --> 00:04.000\nshort form\n\n1:00:00.100 --> 1:00:02.000\nan hour in\n';
    final v = parseSubtitles(vtt);
    expect(v.map((e) => e.seconds), [2.0, 3600.1]);
  });

  test('a match inside a video maps to the moment it appears', () {
    final f = IndexedFile(path: '/v/talk.mp4', size: 1, modifiedMs: 0)
      ..segments = const [
        VideoSegment(0, 'Welcome everyone'),
        VideoSegment(42.5, 'Our quarterly revenue grew'),
        VideoSegment(90, 'Questions'),
        VideoSegment(130, 'revenue again'),
      ]
      ..source = ContentSource.video
      ..status = IndexStatus.indexed;
    final engine = SearchEngine()..upsert(f);

    final hit = engine.find('revenue').hits.single;
    expect(hit.sources, contains(MatchSource.videoContent));
    expect(hit.moments.map((m) => m.seconds), [42.5, 130]);
    expect(hit.firstMoment!.at, const Duration(milliseconds: 42500));
    expect(engine.find('questions').hits.single.firstMoment!.seconds, 90);
    expect(engine.find('banana').hits, isEmpty);
  });

  test('a spoken word mid-sentence plays from that word, not the sentence start', () {
    // Speech arrives one word per segment; on-screen text follows as its own run.
    final words = ['so', 'we', 'wanted', 'to', 'say', 'thanks', 'to', 'everyone'];
    final f = IndexedFile(path: '/v/sample.mp4', size: 1, modifiedMs: 0)
      ..segments = [
        for (var i = 0; i < words.length; i++) VideoSegment(4.0 + i * 0.8, words[i]),
        const VideoSegment(2, 'THANK YOU SLIDE'),
      ]
      ..source = ContentSource.video
      ..status = IndexStatus.indexed;
    final engine = SearchEngine()..upsert(f);

    final hit = engine.find('thanks').hits.single;
    expect(hit.firstMoment!.seconds, 8.0); // the word itself – not 4.0
    expect(hit.firstMoment!.text, contains('say thanks to everyone'));
    // Phrases across word segments still match, timed to their first word.
    expect(engine.find('say thanks').hits.single.firstMoment!.seconds, closeTo(7.2, 1e-9));
    // Speech and on-screen text don't interleave: the slide doesn't break the phrase.
    expect(engine.find('thank you').hits.single.firstMoment!.seconds, 2);
  });

  test('video segments survive saving and loading the index', () {
    final f = IndexedFile(path: '/v/a.mov', size: 9, modifiedMs: 5)
      ..segments = const [VideoSegment(1.234, 'one'), VideoSegment(7, 'two')]
      ..source = ContentSource.video
      ..status = IndexStatus.indexed;
    final back = IndexedFile.fromJson(Map<String, dynamic>.from(f.toJson()));
    expect(back.content, 'one\ntwo');
    expect(back.segments.map((s) => s.seconds), [1.23, 7]);
    expect(back.segmentAt(back.content.indexOf('two'))!.text, 'two');
    expect(f.toJson().containsKey('c'), isFalse); // text is not stored twice
  });

  test('background indexing reads videos; time-boxed passes leave them queued', () async {
    final dir = await Directory.systemTemp.createTemp('video_test');
    addTearDown(() => dir.delete(recursive: true));
    final video = File('${dir.path}/demo.mp4')..writeAsBytesSync([0, 0, 0, 1]);
    File('${dir.path}/demo.en.srt').writeAsStringSync('1\n00:00:12,000 --> 00:00:14,000\nlaunch checklist\n');

    final store = IndexStore();
    final engine = SearchEngine();
    final indexer = Indexer(store, engine, _NoOcr(), video: _FakeVideo());

    await indexer.run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      budget: const Duration(seconds: 5),
      onProgress: (_) {},
    );
    expect(store.files[video.path]!.needsVideo, isTrue);

    await indexer.run(roots: const [], skipPaths: const [], scan: false, onProgress: (_) {});
    final f = store.files[video.path]!;
    expect(f.status, IndexStatus.indexed);
    expect(f.source, ContentSource.video);

    // Spoken words (fake native analyser) and the subtitle file are both searchable.
    expect(engine.find('budget review').hits.single.firstMoment!.seconds, 75);
    final sub = engine.find('launch checklist').hits.firstWhere((h) => h.file.path == video.path);
    expect(sub.firstMoment!.seconds, 12);
  });

  test('a full analysis (no time limit) leaves nothing unread, videos included', () async {
    final dir = await Directory.systemTemp.createTemp('full_test');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/a.mp4').writeAsBytesSync([0, 0, 0, 1]);
    File('${dir.path}/notes.txt').writeAsStringSync('hello');
    File('${dir.path}/pic.png').writeAsBytesSync([1, 2, 3]);
    final store = IndexStore();
    final summary = await Indexer(store, SearchEngine(), _NoOcr(), video: _FakeVideo()).run(
      roots: [ScanRoot(dir.path, 'test')],
      skipPaths: const [],
      onProgress: (_) {},
    );
    expect(summary.remaining, 0);
    expect(store.files.values.where((f) => f.isPending), isEmpty);
  });
}

class _FakeVideo implements VideoAnalyzer {
  @override
  String get name => 'fake';
  @override
  Future<bool> readsMedia() async => true;
  @override
  void cancel() {}
  @override
  Future<List<VideoSegment>> analyze(String path) async =>
      [...await readSidecarSubtitles(path), const VideoSegment(75, 'the budget review')];
}

class _NoOcr implements OcrEngine {
  @override
  String get name => 'none';
  @override
  int get parallelism => 1;
  @override
  bool get readsPdf => false;
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<String> recognize(String path) async => '';
  @override
  Future<ImageReading> analyzeImage(String path) async => const ImageReading('');
}
