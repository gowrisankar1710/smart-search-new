import 'dart:io';

import 'package:flutter/material.dart';

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String formatDate(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// "12.4 s", "1 min 05 s".
String formatSeconds(Duration d) {
  if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  return '${d.inMinutes} min ${(d.inSeconds % 60).toString().padLeft(2, '0')} s';
}

/// "12 ms" below a second, otherwise seconds.
String formatMillis(Duration d) => d.inMilliseconds < 1000 ? '${d.inMilliseconds} ms' : formatSeconds(d);

String formatCount(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Replaces the home directory with "~" and the Android storage root with "Phone".
String friendlyPath(String path) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (Platform.isAndroid && path.startsWith('/storage/emulated/0')) {
    return 'Phone${path.substring('/storage/emulated/0'.length)}';
  }
  if (home != null && home.length > 1 && path.startsWith(home)) return '~${path.substring(home.length)}';
  return path;
}

/// Builds a span with every occurrence of [terms] highlighted (case-insensitive).
TextSpan highlightSpan(String text, Iterable<String> terms, TextStyle base, TextStyle hi) {
  final list = terms.where((t) => t.isNotEmpty).toList()..sort((a, b) => b.length.compareTo(a.length));
  if (list.isEmpty) return TextSpan(text: text, style: base);
  final re = RegExp(list.map(RegExp.escape).join('|'), caseSensitive: false);
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    spans.add(TextSpan(text: m.group(0), style: hi));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: spans);
}
