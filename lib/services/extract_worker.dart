import 'dart:async';
import 'dart:isolate';

import '../core/text_tools.dart';
import 'text_extractor.dart';

class ExtractJob {
  const ExtractJob(this.paths, this.exts, this.deadlineMs);
  final List<String> paths;
  final List<String> exts;
  final int deadlineMs;
}

class ExtractResult {
  const ExtractResult(this.path, this.text, this.termFreq, this.error, this.micros);
  final String path;
  final String? text;
  final Map<String, int>? termFreq; // computed off the UI thread
  final String? error;
  final int micros;
}

/// A long-lived background isolate that extracts and tokenises document text.
/// It can be killed instantly, which is what makes the 60-second limit a hard limit.
class ExtractWorker {
  ExtractWorker._(this._isolate, this._port);

  final Isolate _isolate;
  final ReceivePort _port;
  late final SendPort _send;
  Completer<List<ExtractResult>>? _pending;
  bool _dead = false;

  static Future<ExtractWorker> spawn() async {
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    final iso = await Isolate.spawn(_workerMain, port.sendPort, errorsAreFatal: false, debugName: 'extractor');
    final w = ExtractWorker._(iso, port);
    port.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final c = w._pending;
      w._pending = null;
      c?.complete((msg as List).cast<ExtractResult>());
    });
    w._send = await ready.future;
    return w;
  }

  Future<List<ExtractResult>> run(ExtractJob job) {
    if (_dead) return Future.value(const []);
    final c = Completer<List<ExtractResult>>();
    _pending = c;
    _send.send(job);
    return c.future;
  }

  void kill() {
    if (_dead) return;
    _dead = true;
    _isolate.kill(priority: Isolate.immediate);
    _port.close();
    final c = _pending;
    _pending = null;
    c?.complete(const []);
  }
}

void _workerMain(SendPort main) {
  final rp = ReceivePort();
  main.send(rp.sendPort);
  rp.listen((msg) {
    final job = msg as ExtractJob;
    final out = <ExtractResult>[];
    for (var i = 0; i < job.paths.length; i++) {
      if (DateTime.now().millisecondsSinceEpoch >= job.deadlineMs) break;
      final sw = Stopwatch()..start();
      try {
        final raw = extractText(job.paths[i], job.exts[i]);
        final text = raw == null ? '' : normalizeContent(raw);
        out.add(ExtractResult(job.paths[i], text, contentTermFrequencies(text), null, sw.elapsedMicroseconds));
      } catch (e) {
        out.add(ExtractResult(job.paths[i], null, null, '$e', sw.elapsedMicroseconds));
      }
    }
    main.send(out);
  });
}
