# Windows: generate platform projects and patch Android minSdk. (iOS/macOS setup must run on a Mac via setup.sh)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

flutter create --org com.smartsearch --project-name smart_file_search --platforms=android,ios,macos,windows,linux .
flutter pub get

$gradle = "android/app/build.gradle.kts"
if (-not (Test-Path $gradle)) { $gradle = "android/app/build.gradle" }
if (Test-Path $gradle) {
  (Get-Content $gradle) -replace 'minSdk( =|) flutter\.minSdkVersion', 'minSdk$1 24' | Set-Content $gradle
}

Write-Host "`nDone. Run with:  flutter run -d windows   (or pick an Android device)"
Write-Host "Optional: install Tesseract OCR (https://github.com/UB-Mannheim/tesseract/wiki) to read text inside images on Windows."
