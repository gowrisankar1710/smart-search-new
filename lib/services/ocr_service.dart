import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Reads text embedded in images.
abstract class OcrEngine {
  String get name;
  int get parallelism;
  Future<bool> isAvailable();
  Future<String> recognize(String path);
}

/// Bump when the OCR engine/settings change so images already read get re-read.
const int kOcrVersion = 2;

OcrEngine createOcrEngine() {
  if (Platform.isAndroid || Platform.isIOS) return MlKitOcrEngine();
  if (Platform.isMacOS) return VisionOcrEngine(fallback: TesseractOcrEngine());
  return TesseractOcrEngine();
}

/// macOS: Apple Vision (the Live Text engine) via a native method channel.
/// Built into the OS – nothing to install – and much better on screenshots and photos.
class VisionOcrEngine implements OcrEngine {
  VisionOcrEngine({this.fallback});
  final OcrEngine? fallback;
  static const _channel = MethodChannel('smart_file_search/ocr');
  bool? _native;

  @override
  String get name => (_native ?? true) ? 'Apple Vision (on-device)' : (fallback?.name ?? 'none');
  @override
  int get parallelism => 3;

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
}

/// Google ML Kit – fully on-device, no network, bundled Latin model.
class MlKitOcrEngine implements OcrEngine {
  TextRecognizer? _recognizer;

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
}

/// Desktop OCR through the free Tesseract CLI, if it is installed.
class TesseractOcrEngine implements OcrEngine {
  String? _bin;
  bool? _available;

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
}
