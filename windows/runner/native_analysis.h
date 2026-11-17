#ifndef RUNNER_NATIVE_ANALYSIS_H_
#define RUNNER_NATIVE_ANALYSIS_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Windows counterpart of the macOS Vision/AVFoundation code: reads images, scanned PDFs
// and video frames on-device with Windows' built-in OCR, and classifies images with the
// bundled MobileNetV2 model through Windows ML.
//
// Channels (same as macOS):
//   smart_file_search/ocr    isAvailable · recognize(path) · analyzeImage(path)
//   smart_file_search/video  isAvailable · analyze(path, budgetSeconds) · cancel
namespace native_analysis {

// Work runs on background threads; replies are posted back to |window| and delivered
// on the platform thread from its message loop (see HandleMessage).
void Register(flutter::BinaryMessenger* messenger, HWND window);

// Call from the window procedure. Returns true if |message| was ours.
bool HandleMessage(UINT message);

}  // namespace native_analysis

#endif  // RUNNER_NATIVE_ANALYSIS_H_
