/// The first analysis after install (and any manual re-analysis) never runs longer than this.
const Duration kAnalysisBudget = Duration(seconds: 60);

/// Share of the budget the file-discovery phase may use before content reading starts.
/// If discovery finishes sooner, content reading automatically gets the rest.
const double kScanShare = 0.35;

/// Upper bound on files discovered per run.
const int kMaxFiles = 400000;

/// How often the automatic background re-scan walks the disk for new/changed files
/// once everything known has been read.
const Duration kAutoScanInterval = Duration(seconds: 30);
