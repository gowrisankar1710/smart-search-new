/// File-type knowledge shared by the scanner, extractor workers and UI.
/// Pure Dart (no Flutter imports) so it can run inside background isolates.
library;

enum FileKind { pdf, document, spreadsheet, presentation, text, image, video, audio, archive, other }

const textExtensions = <String>{
  'txt', 'md', 'markdown', 'log', 'ini', 'cfg', 'conf', 'yaml', 'yml', 'json', 'xml',
  'html', 'htm', 'csv', 'tsv', 'srt', 'vtt', 'tex', 'sql', 'sh', 'bat', 'ps1', 'dart',
  'swift', 'kt', 'kts', 'java', 'py', 'js', 'ts', 'jsx', 'tsx', 'c', 'cc', 'cpp', 'h',
  'hpp', 'm', 'mm', 'cs', 'go', 'rb', 'php', 'rs', 'css', 'scss', 'gradle', 'plist',
  'properties', 'env', 'eml',
};

const ocrExtensions = <String>{'png', 'jpg', 'jpeg', 'webp', 'bmp', 'heic', 'heif', 'tif', 'tiff'};

const _documentExt = {'doc', 'docx', 'docm', 'dotx', 'odt', 'rtf', 'pages'};
const _sheetExt = {'xls', 'xlsx', 'xlsm', 'ods', 'csv', 'tsv', 'numbers'};
const _slideExt = {'ppt', 'pptx', 'odp', 'key'};
const _imageExt = {...ocrExtensions, 'gif', 'svg', 'raw', 'cr2', 'nef', 'ico'};
const _videoExt = {'mp4', 'mov', 'mkv', 'avi', 'wmv', 'm4v', 'webm', '3gp'};
const _audioExt = {'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'wma', 'opus'};
const _archiveExt = {'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'iso', 'dmg', 'apk', 'ipa'};

const _zipOfficeExt = {'docx', 'docm', 'dotx', 'pptx', 'xlsx', 'xlsm', 'odt', 'ods', 'odp'};
const _legacyBinaryExt = {'doc', 'xls', 'ppt'};
const _contentExt = {'pdf', 'rtf', ..._zipOfficeExt, ..._legacyBinaryExt, ...textExtensions};

FileKind kindForExt(String ext) {
  if (ext == 'pdf') return FileKind.pdf;
  if (_sheetExt.contains(ext)) return FileKind.spreadsheet;
  if (_documentExt.contains(ext)) return FileKind.document;
  if (_slideExt.contains(ext)) return FileKind.presentation;
  if (textExtensions.contains(ext)) return FileKind.text;
  if (_imageExt.contains(ext)) return FileKind.image;
  if (_videoExt.contains(ext)) return FileKind.video;
  if (_audioExt.contains(ext)) return FileKind.audio;
  if (_archiveExt.contains(ext)) return FileKind.archive;
  return FileKind.other;
}

/// Formats that never contain searchable text (media, archives, fonts, compiled code…).
const _binaryExt = <String>{
  ..._videoExt, ..._audioExt, ..._archiveExt,
  'gif', 'raw', 'cr2', 'nef', 'ico', 'icns', 'psd', 'ai', 'sketch', 'fig', 'ithmb',
  'ttf', 'otf', 'woff', 'woff2', 'eot',
  'jar', 'class', 'dex', 'so', 'dylib', 'a', 'o', 'obj', 'lib', 'dll', 'exe', 'bin', 'dat',
  'wasm', 'pyc', 'db', 'sqlite', 'sqlite3', 'realm', 'xcuserstate', 'car', 'nib', 'mlmodel',
  'pages', 'numbers', 'key', 'pkg', 'msi', 'deb', 'rpm', 'img', 'vmdk', 'qcow2', 'swp',
  'dill', 'snapshot', 'mp4v', 'ds_store',
};

/// Known document formats are parsed; any other non-binary file is sniffed and read
/// as plain text if it looks like text (.arb, .xcconfig, .gn, Makefile, …).
bool hasExtractableText(String ext) =>
    _contentExt.contains(ext) || (!_binaryExt.contains(ext) && !ocrExtensions.contains(ext));
bool isOcrCandidate(String ext) => ocrExtensions.contains(ext);

/// Videos whose content (on-screen text, speech, subtitle files) can be read.
bool isVideoCandidate(String ext) => _videoExt.contains(ext);

/// Videos larger than this are found by name only – never opened or analysed.
/// Reading a big video takes minutes of heavy work and made slower PCs freeze.
const int kMaxVideoBytes = 50 << 20; // 50 MB

/// A video small enough to read inside (see [kMaxVideoBytes]).
bool isReadableVideo(String ext, int size) => isVideoCandidate(ext) && size <= kMaxVideoBytes;

/// Subtitle files that sit next to a video ("talk.mp4" + "talk.srt" / "talk.en.vtt").
const subtitleExtensions = <String>{'srt', 'vtt'};

/// Relative CPU cost per byte of extracting text. Feeds the indexer's speed model.
double extractionCostFactor(String ext) {
  if (ext == 'pdf') return 6;
  if (_zipOfficeExt.contains(ext)) return 3;
  if (_legacyBinaryExt.contains(ext)) return 2;
  return 1;
}

/// Hard size caps: files above these are indexed by name only.
int maxExtractBytes(String ext) {
  if (ext == 'pdf') return 80 << 20;
  if (_zipOfficeExt.contains(ext)) return 60 << 20;
  if (_legacyBinaryExt.contains(ext)) return 20 << 20;
  return 50 << 20; // text files: only the first 1 MB is read anyway
}

/// Largest file the Timer screen's pass reads before Search opens; bigger ones are read
/// in the background right after, smallest first. Reading cost grows with size (pixels
/// to recognise, pages to render), so a handful of huge photos or scans would otherwise
/// hold Search back for minutes – most of all with Windows OCR.
int quickReadBytes(String ext, {bool ocr = false}) {
  if (ext == 'pdf') return ocr ? 3 << 20 : 25 << 20; // scanned PDF: every page is OCR'd
  if (ocr || ocrExtensions.contains(ext)) return 8 << 20;
  if (_zipOfficeExt.contains(ext)) return 20 << 20;
  if (_legacyBinaryExt.contains(ext)) return 10 << 20;
  return 10 << 20;
}

/// What kind of content a file holds, as the app reads it: documents first, images
/// next (text and objects inside them), videos last (in the background).
enum FileCategory {
  documents('Documents', 'document'),
  images('Images', 'image'),
  videos('Videos', 'video');

  const FileCategory(this.label, this.singular);
  final String label;
  final String singular;
}

/// The category whose content is read for [ext]; null for files known by name only.
FileCategory? categoryOf(String ext) {
  if (isVideoCandidate(ext)) return FileCategory.videos;
  if (isOcrCandidate(ext)) return FileCategory.images;
  if (hasExtractableText(ext)) return FileCategory.documents;
  return null;
}
