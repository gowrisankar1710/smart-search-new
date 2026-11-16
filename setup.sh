#!/usr/bin/env bash
# Generates the native platform projects and applies the iOS / Android / macOS settings this app needs.
# Files already in android/, ios/ and macos/ (manifest, Podfile, entitlements) are kept – flutter create never overwrites them.
set -euo pipefail
cd "$(dirname "$0")"

flutter create --org com.smartsearch --project-name smart_file_search \
  --platforms=android,ios,macos,windows,linux .
flutter pub get

# ---- Android: ML Kit needs minSdk 21+, file access works best on targetSdk 34+
GRADLE=android/app/build.gradle.kts
[ -f "$GRADLE" ] || GRADLE=android/app/build.gradle
if [ -f "$GRADLE" ]; then
  sed -i.bak -E 's/minSdk( =|) flutter\.minSdkVersion/minSdk\1 24/' "$GRADLE" && rm -f "$GRADLE.bak"
fi

# ---- Apple platforms (only possible on a Mac)
if [[ "$(uname)" == "Darwin" ]]; then
  IOS=ios/Runner/Info.plist
  plutil -replace UIFileSharingEnabled -bool YES "$IOS"
  plutil -replace LSSupportsOpeningDocumentsInPlace -bool YES "$IOS"
  plutil -replace UISupportsDocumentBrowser -bool YES "$IOS"
  plutil -replace NSPhotoLibraryUsageDescription -string "Smart Search reads text in the images you choose so you can find them by their words." "$IOS"
  plutil -replace NSCameraUsageDescription -string "Not used for capturing; required by the file picker component." "$IOS"
  plutil -replace NSAppleMusicUsageDescription -string "Not used; required by the file picker component." "$IOS"
  plutil -replace CFBundleDisplayName -string "Smart Search" "$IOS"
  sed -i '' -E 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 15.5;/g' ios/Runner.xcodeproj/project.pbxproj

  MAC=macos/Runner/Info.plist
  plutil -replace NSDesktopFolderUsageDescription -string "Smart Search indexes your Desktop so you can find files by their content." "$MAC"
  plutil -replace NSDocumentsFolderUsageDescription -string "Smart Search indexes your Documents so you can find files by their content." "$MAC"
  plutil -replace NSDownloadsFolderUsageDescription -string "Smart Search indexes your Downloads so you can find files by their content." "$MAC"
  plutil -replace NSRemovableVolumesUsageDescription -string "Smart Search can index external drives you connect." "$MAC"
  plutil -replace NSNetworkVolumesUsageDescription -string "Smart Search can index network drives you connect." "$MAC"

  (cd ios && pod install --repo-update) || echo "pod install failed – run it manually inside ios/"
fi

echo
echo "Done. Run with:  flutter run   (add -d <device> to pick Android / iOS / desktop)"
