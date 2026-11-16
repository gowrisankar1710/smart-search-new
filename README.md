# Smart File Search (Flutter)

Find any file by **what's inside it**: file names, folder names, document text (PDF, Word, Excel, PowerPoint, ODF, RTF, text/code) and **text inside images** (OCR). Typos, partial names and related words all work. Everything runs on the device.

## Quick start

```bash
# macOS / Linux (on a Mac this also configures iOS + macOS)
./setup.sh
# Windows
powershell -ExecutionPolicy Bypass -File setup.ps1

flutter run              # pick an Android phone, iPhone, or desktop
```

`setup.sh` runs `flutter create` to generate the native projects. It keeps the files already in this repo (Android manifest, iOS Podfile, macOS entitlements) and then patches the generated ones (Android `minSdk`, iOS Info.plist keys and deployment target, macOS folder-access prompts).

## The 1-minute first analysis

The first analysis after install, and every manual re-analysis, is **hard-capped at 60 s** (`lib/core/constants.dart`):

| Phase | Budget | What happens |
|---|---|---|
| Discovery | up to 35 % (≈21 s), less if it finishes early | A background isolate walks folders breadth-first, so Desktop/Documents/Downloads come first. Every file is searchable by name straight away. |
| Content | the rest | Several extractor isolates read documents in **adaptive batches**, with an OCR lane alongside. Recent and cheap files go first. |
| Speed model | live | Measures how many bytes per second each worker gets through. A file that can't finish before the deadline is skipped and left queued. Batch size adjusts so each batch takes about 350 ms. |
| Deadline | 60 s | A timer **kills** every worker isolate, so the limit is guaranteed. The index is saved after the user can already search. |

Whatever didn't fit is read afterwards by one gentle background worker. You can pause it in the index settings sheet.

## Search ranking ("smart" part)

`lib/services/search_engine.dart` is an inverted index with three fields (name, folders, content):
BM25 on content, IDF-weighted name matches, prefix completion (`invo` → invoice), typo tolerance (edit distance 1–2), concept synonyms (`bill` ↔ invoice ↔ receipt, `cv` ↔ resume…), whole-query substring on file names (`nvoice2024`), exact-phrase boost, all-words coverage and recency boost. Results show the location, which part matched (Name / Folder / Inside file / Text in image) and a highlighted snippet.

## Platform notes

| Platform | What can be searched | OCR |
|---|---|---|
| **Android** | All of internal storage + SD card after **"All files access"** (`MANAGE_EXTERNAL_STORAGE`). If refused, photos and videos only (Android 13+). On Google Play, this permission needs a policy declaration; "file search" is an accepted use. | ML Kit, on-device |
| **iOS** | Sandbox rules: the app's own folder (shown in Files › *On My iPhone › Smart Search*) plus folders the user picks with **Add folder** (Files, iCloud Drive). iOS grants access to a picked folder for the current session, so re-pick after relaunch, or copy files into the app folder. | ML Kit, on-device (iOS 15.5+) |
| **Windows** | User folders, OneDrive, every drive letter (system folders skipped) | Install [Tesseract](https://github.com/UB-Mannheim/tesseract/wiki) |
| **macOS** | Home folders, iCloud Drive, `/Volumes/*`. Sandbox is disabled for direct distribution (not the Mac App Store); macOS asks once per protected folder. | `brew install tesseract` |
| **Linux** | Home, `/media`, `/mnt` | `apt install tesseract-ocr` |

The iOS simulator build excludes arm64 because ML Kit has no arm64-simulator slice. Use a real device or a Rosetta simulator.

## Project layout

```
lib/
  core/        file types, tokeniser/stemmer, synonyms, constants, IndexedFile model
  services/    file_scan (discovery isolate), extract_worker + text_extractor (document isolates),
               ocr_service, indexer (time-boxed pipeline), search_engine, index_store, locations, permissions
  ui/          onboarding, analysis (countdown), home/search, result tile, settings sheet, theme
android/app/src/main/AndroidManifest.xml   permissions + ML Kit bundled model
ios/Podfile                                 iOS 15.5, ML Kit simulator fix
macos/Runner/*.entitlements                 full-disk scanning
```

## Licences
`syncfusion_flutter_pdf` is free under the Syncfusion Community Licence (individuals / companies under $1M revenue); otherwise swap in `pdfrx`.
# smart-search-new
