import 'package:flutter/material.dart';

import '../core/file_types.dart';

/// Light, airy palette: off-white canvas, white panels, soft borders, indigo accent.
ThemeData buildTheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(seedColor: const Color(0xFF4F5BFF), brightness: Brightness.light);
  final scheme = base.copyWith(
    primary: const Color(0xFF4F5BFF),
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFEEF0FF),
    onPrimaryContainer: const Color(0xFF2B34B8),
    surface: const Color(0xFFF7F8FA),
    onSurface: const Color(0xFF1B1D24),
    onSurfaceVariant: const Color(0xFF6B7080),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF2F3F6),
    surfaceContainer: const Color(0xFFECEEF2),
    surfaceContainerHigh: const Color(0xFFE6E8ED),
    surfaceContainerHighest: const Color(0xFFDFE2E8),
    outline: const Color(0xFFCDD1DA),
    outlineVariant: const Color(0xFFE6E8EE),
  );
  final text = ThemeData(brightness: Brightness.light).textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    textTheme: text,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: Colors.white,
      labelStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

extension FileKindStyle on FileKind {
  IconData get icon => switch (this) {
        FileKind.pdf => Icons.picture_as_pdf_rounded,
        FileKind.document => Icons.description_rounded,
        FileKind.spreadsheet => Icons.table_chart_rounded,
        FileKind.presentation => Icons.slideshow_rounded,
        FileKind.text => Icons.article_rounded,
        FileKind.image => Icons.image_rounded,
        FileKind.video => Icons.movie_rounded,
        FileKind.audio => Icons.music_note_rounded,
        FileKind.archive => Icons.folder_zip_rounded,
        FileKind.other => Icons.insert_drive_file_rounded,
      };

  Color get color => switch (this) {
        FileKind.pdf => const Color(0xFFE53935),
        FileKind.document => const Color(0xFF1E88E5),
        FileKind.spreadsheet => const Color(0xFF2E7D32),
        FileKind.presentation => const Color(0xFFF4511E),
        FileKind.text => const Color(0xFF546E7A),
        FileKind.image => const Color(0xFF8E24AA),
        FileKind.video => const Color(0xFFD81B60),
        FileKind.audio => const Color(0xFF00897B),
        FileKind.archive => const Color(0xFF6D4C41),
        FileKind.other => const Color(0xFF757575),
      };
}

/// Filter chips shown above the results.
enum ResultFilter {
  all('All files', null),
  documents('Documents', {FileKind.document}),
  pdf('PDF', {FileKind.pdf}),
  sheets('Sheets', {FileKind.spreadsheet}),
  slides('Slides', {FileKind.presentation}),
  text('Text & code', {FileKind.text}),
  images('Images', {FileKind.image}),
  media('Video & audio', {FileKind.video, FileKind.audio}),
  other('Other', {FileKind.archive, FileKind.other});

  const ResultFilter(this.label, this.kinds);
  final String label;
  final Set<FileKind>? kinds;

  IconData get icon => switch (this) {
        ResultFilter.all => Icons.grid_view_rounded,
        ResultFilter.documents => Icons.description_outlined,
        ResultFilter.pdf => Icons.picture_as_pdf_outlined,
        ResultFilter.sheets => Icons.table_chart_outlined,
        ResultFilter.slides => Icons.slideshow_outlined,
        ResultFilter.text => Icons.code_rounded,
        ResultFilter.images => Icons.image_outlined,
        ResultFilter.media => Icons.play_circle_outline_rounded,
        ResultFilter.other => Icons.inventory_2_outlined,
      };
}
