import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../core/imagenet_labels.dart';
import '../core/indexed_file.dart';

/// What was read from one image: its text and what it shows.
class ImageReading {
  const ImageReading(this.text, [this.labels = const []]);
  final String text;
  final List<ImageLabel> labels;
}

/// Reads text embedded in images.
abstract class OcrEngine {
  String get name;
  int get parallelism;

  /// Can read scanned / image-only PDFs (renders pages, then OCR).
  bool get readsPdf;
  Future<bool> isAvailable();
  Future<String> recognize(String path);

  /// Text plus objects/scenes. Engines without a classifier return text only.
  Future<ImageReading> analyzeImage(String path);
}

/// Bump when the OCR engine/settings change so images already read get re-read.
/// v3: images are also classified (objects, scenes, clothing).
/// v4: close-ups of people/objects are classified too, and a calibrated 0.3 cut-off.
/// Windows v5: built-in Windows OCR and the bundled object classifier.
final int kOcrVersion = Platform.isWindows ? 5 : 4;

OcrEngine createOcrEngine() {
  if (Platform.isAndroid || Platform.isIOS) return MlKitOcrEngine();
  if (Platform.isMacOS || Platform.isWindows) return NativeOcrEngine(fallback: TesseractOcrEngine());
  return TesseractOcrEngine();
}

/// The OS's own engines via a native method channel – nothing to install:
///  • macOS: Apple Vision (the Live Text engine) – text and objects/scenes
///  • Windows: Windows.Media.Ocr for text, the bundled MobileNetV2 (Windows ML) for objects
/// Tesseract, if installed, is the fallback when the native engine isn't available.
class NativeOcrEngine implements OcrEngine {
  NativeOcrEngine({this.fallback});
  final OcrEngine? fallback;
  static const _channel = MethodChannel('smart_file_search/ocr');
  bool? _native;

  @override
  String get name => (_native ?? true)
      ? (Platform.isWindows ? 'Windows OCR + Windows ML (on-device)' : 'Apple Vision (on-device)')
      : (fallback?.name ?? 'none');
  @override
  // Windows: matches the native image pool (half the cores, 2–4). macOS: Vision runs
  // partly on the Neural Engine / GPU; measured: 4 at once is the sweet spot.
  int get parallelism => Platform.isWindows
      ? (Platform.numberOfProcessors ~/ 2).clamp(2, 4)
      : (Platform.numberOfProcessors ~/ 2).clamp(3, 4);
  @override
  bool get readsPdf => _native ?? false;

  @override
  Future<bool> isAvailable() async {
    if (_native == null) {
      try {
        _native = await _channel.invokeMethod<bool>('isAvailable') ?? false;
      } catch (_) {
        _native = false;
      }
    }
    return _native! || (await fallback?.isAvailable() ?? false);
  }

  @override
  Future<String> recognize(String path) async {
    if (!await isAvailable()) return '';
    if (_native!) {
      return await _channel.invokeMethod<String>('recognize', {'path': path}) ?? '';
    }
    return fallback!.recognize(path);
  }

  @override
  Future<ImageReading> analyzeImage(String path) async {
    if (!await isAvailable()) return const ImageReading('');
    if (!_native!) return ImageReading(await fallback!.recognize(path));
    final r = await _channel.invokeMapMethod<String, Object?>('analyzeImage', {'path': path}) ?? const {};
    return ImageReading((r['text'] as String?) ?? '', parseNativeLabels((r['labels'] as List?) ?? const []));
  }
}

/// Native labels: Apple Vision's are search words already ([id, confidence]); Windows
/// sends raw model classes (["imagenet:<id>", p]), mapped onto the same search words.
List<ImageLabel> parseNativeLabels(List<Object?> raw) {
  final vision = <ImageLabel>[];
  final imagenet = <(int, double)>[];
  for (final l in raw) {
    if (l is! List || l.length < 2) continue;
    final id = l[0] as String;
    final p = (l[1] as num).toDouble();
    if (id.startsWith('imagenet:')) {
      final i = int.tryParse(id.substring(9));
      if (i != null) imagenet.add((i, p));
    } else {
      vision.add(ImageLabel(id, p));
    }
  }
  return imagenet.isEmpty ? vision : [...vision, ...labelsFromImagenet(imagenet)];
}

/// Google ML Kit – fully on-device, no network, bundled Latin model.
class MlKitOcrEngine implements OcrEngine {
  TextRecognizer? _recognizer;

  @override
  bool get readsPdf => false;
  @override
  String get name => 'ML Kit (on-device)';
  @override
  int get parallelism => 1;
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> recognize(String path) async {
    final r = _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
    final result = await r.processImage(InputImage.fromFilePath(path));
    return result.text;
  }

  @override
  Future<ImageReading> analyzeImage(String path) async => ImageReading(await recognize(path));
}

/// Desktop OCR through the free Tesseract CLI, if it is installed.
class TesseractOcrEngine implements OcrEngine {
  String? _bin;
  bool? _available;

  @override
  bool get readsPdf => false;
  @override
  String get name => 'Tesseract';
  @override
  int get parallelism => 2;

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    final candidates = <String>[
      'tesseract',
      if (Platform.isWindows) r'C:\Program Files\Tesseract-OCR\tesseract.exe',
      if (Platform.isMacOS) ...['/opt/homebrew/bin/tesseract', '/usr/local/bin/tesseract'],
      if (Platform.isLinux) '/usr/bin/tesseract',
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['--version']).timeout(const Duration(seconds: 3));
        if (r.exitCode == 0) {
          _bin = c;
          return _available = true;
        }
      } catch (_) {}
    }
    return _available = false;
  }

  @override
  Future<String> recognize(String path) async {
    if (!await isAvailable()) return '';
    final proc = await Process.start(_bin!, [path, 'stdout', '--psm', '3']);
    final out = proc.stdout.transform(utf8.decoder).join();
    unawaited(proc.stderr.drain<void>());
    final code = await proc.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
      proc.kill();
      return -1;
    });
    return code == 0 ? await out : '';
  }

  @override
  Future<ImageReading> analyzeImage(String path) async => ImageReading(await recognize(path));
}
