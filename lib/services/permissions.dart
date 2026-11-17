import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Asks for the broadest file access the platform allows.
/// Returns false if the user refused (search still works on what is reachable).
Future<bool> requestStorageAccess() async {
  if (!Platform.isAndroid) return true; // desktop: OS prompts per folder; iOS: sandbox + picked folders

  // Android 11+: "All files access" – required to search every folder, not just media.
  var all = await Permission.manageExternalStorage.status;
  if (!all.isGranted) all = await Permission.manageExternalStorage.request();
  if (all.isGranted) return true;

  // Fallback: Android ≤ 10 storage permission, or Android 13+ media permissions.
  final res = await [Permission.storage, Permission.photos, Permission.videos].request();
  return res.values.any((s) => s.isGranted || s.isLimited);
}

// ------------------------------------------------------------------ macOS pop-ups

/// macOS asks the user before an app reads Desktop / Documents / Downloads, and before it
/// uses speech recognition. The app explains both on its own "Allow access" screen first
/// and brings the system prompts up only from there.
bool get hasSystemPrompts => Platform.isMacOS;

enum SpeechAccess { granted, denied, notAsked, unavailable }

const _video = MethodChannel('smart_file_search/video');

Future<SpeechAccess> speechAccess() async {
  if (!Platform.isMacOS) return SpeechAccess.unavailable;
  try {
    final s = await _video.invokeMethod<String>('speechStatus');
    return SpeechAccess.values.firstWhere((v) => v.name == s, orElse: () => SpeechAccess.unavailable);
  } catch (_) {
    return SpeechAccess.unavailable;
  }
}

Future<bool> requestSpeechAccess() async {
  try {
    return await _video.invokeMethod<bool>('requestSpeech') ?? false;
  } catch (_) {
    return false;
  }
}

/// Opens each folder once, one after another, so macOS shows its "access files in your
/// Documents folder" prompts now – right after the app's own screen – instead of
/// popping up one by one in the middle of the analysis. Returns the folders readable now.
Future<Set<String>> requestFolderAccess(List<String> paths) async {
  final ok = <String>{};
  for (final path in paths) {
    try {
      await Directory(path).list().first.timeout(const Duration(minutes: 2), onTimeout: () => Directory(path));
      ok.add(path);
    } on StateError {
      ok.add(path); // empty folder – readable
    } catch (_) {}
  }
  return ok;
}
