import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/file_types.dart';

/// App colours: sky blue and teal on white.
abstract final class Brand {
  /// Light sky blue.
  static const sky = Color(0xFF3EC1EA);

  /// Main accent: a touch deeper than the logo so white text and thin icons read well.
  static const blue = Color(0xFF169FD6);

  /// Text and icons on pale brand backgrounds.
  static const deep = Color(0xFF0B6E99);

  /// Bottom of the "V".
  static const teal = Color(0xFF2CC4A6);

  /// Pale tints for selected rows, badges and panels.
  static const tint = Color(0xFFE7F7FD);
  static const tintTeal = Color(0xFFE5F8F4);

  /// Matched words in names and snippets.
  static const highlight = Color(0xFFC6EEFA);

  static const gradient = LinearGradient(
    colors: [sky, teal],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Very light wash behind full-screen pages (onboarding, analysis).
  static const wash = LinearGradient(
    colors: [Color(0xFFEFF9FD), Colors.white, Color(0xFFEEFAF7)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// The app name in its own lettering, filled with the brand gradient.
class AppName extends StatelessWidget {
  const AppName({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => const LinearGradient(colors: [Brand.blue, Brand.teal]).createShader(r),
      child: Text(
        kAppName,
        maxLines: 1,
        style: TextStyle(fontFamily: 'Righteous', fontSize: size, height: 1.1, letterSpacing: 0.4, color: Colors.white),
      ),
    );
  }
}

/// The app mark: a rounded blue-to-teal tile with a search glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [BoxShadow(color: Brand.blue.withValues(alpha: 0.28), blurRadius: size * 0.35, offset: Offset(0, size * 0.15))],
      ),
      child: Icon(Icons.search_rounded, color: Colors.white, size: size * 0.58),
    );
  }
}

/// White canvas, white panels, soft blue-grey borders, sky-blue accent.
ThemeData buildTheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(seedColor: Brand.blue, brightness: Brightness.light);
  final scheme = base.copyWith(
    primary: Brand.blue,
    onPrimary: Colors.white,
    primaryContainer: Brand.tint,
    onPrimaryContainer: Brand.deep,
    secondary: Brand.teal,
    onSecondary: Colors.white,
    secondaryContainer: Brand.tintTeal,
    onSecondaryContainer: const Color(0xFF0D6B5A),
    surface: Colors.white,
    onSurface: const Color(0xFF16222B),
    onSurfaceVariant: const Color(0xFF627180),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF6FAFC),
    surfaceContainer: const Color(0xFFEEF4F7),
    surfaceContainerHigh: const Color(0xFFE6EEF2),
    surfaceContainerHighest: const Color(0xFFDDE7EC),
    outline: const Color(0xFFC9D6DE),
    outlineVariant: const Color(0xFFE3EBF0),
  );
  final text = ThemeData(brightness: Brightness.light).textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.white,
    visualDensity: VisualDensity.standard,
    textTheme: text,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Brand.blue,
      selectionColor: Brand.sky.withValues(alpha: 0.3),
      selectionHandleColor: Brand.blue,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: Colors.white,
      selectedColor: Brand.tint,
      labelStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      secondaryLabelStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Brand.deep),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      showCheckmark: false,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Brand.blue, linearTrackColor: Brand.tint),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.deep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Brand.deep)),
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
