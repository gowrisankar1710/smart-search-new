import 'dart:io';

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
