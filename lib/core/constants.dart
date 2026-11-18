import 'dart:io';

/// Share of an indexing budget (when one is given) the file-discovery phase may use before content reading starts.
/// If discovery finishes sooner, content reading automatically gets the rest.
const double kScanShare = 0.35;

/// Upper bound on files discovered per run.
const int kMaxFiles = 400000;

/// How often the automatic background re-scan walks the disk for new/changed files
/// once everything known has been read.
const Duration kAutoScanInterval = Duration(seconds: 30);

/// With live folder watching on, the full re-scan is only a safety net for missed events.
/// Walking whole drives is heavy, so it's rare.
const Duration kWatchedRescanInterval = Duration(minutes: 60);

/// After start, the first full re-scan waits this long: the app is responsive first,
/// and the folder watcher reports anything that changes meanwhile.
const Duration kFirstRescanDelay = Duration(minutes: 1);

/// Bump when text extraction improves so files read by an older version are re-read.
/// v2: no 40k-character cut-off, 300 PDF pages (was 40), numbers in spreadsheet cells.
/// v3: scanned / image-only PDFs are read with OCR.
/// v4: videos are read (on-screen text, speech, subtitles) with timestamps.
/// v5: speech is timed per word (was per phrase), so videos are read again.
/// Windows v6: on-screen text in videos and scanned PDFs are read with Windows OCR.
/// Windows v7: OCR falls back to any installed language, small text is enlarged first,
/// and video frames are read at keyframes – videos and scanned PDFs are read again.
final int kContentVersion = Platform.isWindows ? 7 : 5;

/// Longest a single video may take to analyse before it is marked failed.
const Duration kVideoAnalysisLimit = Duration(minutes: 15);
