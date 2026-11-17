#include "native_analysis.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.AI.MachineLearning.h>
#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Editing.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace native_analysis {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

namespace wai = winrt::Windows::AI::MachineLearning;
namespace wgi = winrt::Windows::Graphics::Imaging;
namespace wst = winrt::Windows::Storage;
namespace wss = winrt::Windows::Storage::Streams;

constexpr UINT kReplyMessage = WM_APP + 0x51;

HWND g_window = nullptr;
std::mutex g_reply_mutex;
std::deque<std::function<void()>> g_replies;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_ocr_channel;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_video_channel;
std::atomic<bool> g_video_cancelled{false};

// ------------------------------------------------------------------ threading

// Flutter replies must be sent on the platform thread: queue them and wake the window.
void Reply(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lock(g_reply_mutex);
    g_replies.push_back(std::move(fn));
  }
  PostMessage(g_window, kReplyMessage, 0, 0);
}

// Each request runs on its own worker thread in the multi-threaded apartment, where
// blocking on WinRT async calls (.get()) is allowed.
void RunInBackground(std::function<void()> work) {
  std::thread([work = std::move(work)]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      work();
    } catch (...) {
    }
    winrt::uninit_apartment();
  }).detach();
}

std::shared_ptr<Result> Share(std::unique_ptr<Result> r) {
  return std::shared_ptr<Result>(std::move(r));
}

const std::string* StringArg(const flutter::MethodCall<EncodableValue>& call, const char* key) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (!args) return nullptr;
  auto it = args->find(EncodableValue(std::string(key)));
  if (it == args->end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

double DoubleArg(const flutter::MethodCall<EncodableValue>& call, const char* key, double fallback) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (!args) return fallback;
  auto it = args->find(EncodableValue(std::string(key)));
  if (it == args->end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return static_cast<double>(*i);
  return fallback;
}

// ------------------------------------------------------------------ images

// Decodes |stream|, upright (EXIF orientation applied), long side at most |max_side|.
wgi::SoftwareBitmap Decode(const wss::IRandomAccessStream& stream, uint32_t max_side) {
  auto decoder = wgi::BitmapDecoder::CreateAsync(stream).get();
  wgi::BitmapTransform transform;
  // Scaling happens before rotation, so it uses the stored (unrotated) size.
  const uint32_t w = decoder.PixelWidth();
  const uint32_t h = decoder.PixelHeight();
  const uint32_t long_side = (std::max)(w, h);
  if (max_side > 0 && long_side > max_side) {
    const double s = static_cast<double>(max_side) / static_cast<double>(long_side);
    transform.ScaledWidth((std::max)(1u, static_cast<uint32_t>(std::lround(w * s))));
    transform.ScaledHeight((std::max)(1u, static_cast<uint32_t>(std::lround(h * s))));
    transform.InterpolationMode(wgi::BitmapInterpolationMode::Fant);
  }
  return decoder
      .GetSoftwareBitmapAsync(wgi::BitmapPixelFormat::Bgra8, wgi::BitmapAlphaMode::Premultiplied,
                              transform, wgi::ExifOrientationMode::RespectExifOrientation,
                              wgi::ColorManagementMode::DoNotColorManage)
      .get();
}

wss::IRandomAccessStream OpenFile(const std::string& path) {
  auto file = wst::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
  return file.OpenAsync(wst::FileAccessMode::Read).get();
}

// ------------------------------------------------------------------ OCR

winrt::Windows::Media::Ocr::OcrEngine OcrEngineForThread() {
  thread_local winrt::Windows::Media::Ocr::OcrEngine engine{nullptr};
  thread_local bool tried = false;
  if (!tried) {
    tried = true;
    try {
      engine = winrt::Windows::Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    } catch (...) {
      engine = nullptr;
    }
  }
  return engine;
}

uint32_t OcrMaxSide() {
  try {
    return (std::min)(winrt::Windows::Media::Ocr::OcrEngine::MaxImageDimension(), 4000u);
  } catch (...) {
    return 2600u;
  }
}

std::string Ocr(const wgi::SoftwareBitmap& bitmap) {
  auto engine = OcrEngineForThread();
  if (!engine) return "";
  auto result = engine.RecognizeAsync(bitmap).get();
  std::wstring out;
  for (const auto& line : result.Lines()) {
    if (!out.empty()) out += L"\n";
    out += line.Text().c_str();
  }
  return winrt::to_string(out);
}

bool EndsWithPdf(const std::string& path) {
  if (path.size() < 4) return false;
  std::string ext = path.substr(path.size() - 4);
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return ext == ".pdf";
}

// Scanned / image-only PDFs have no text layer: render each page and read it.
std::string OcrPdf(const std::string& path) {
  constexpr uint32_t kMaxPages = 30;
  auto file = wst::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
  auto doc = winrt::Windows::Data::Pdf::PdfDocument::LoadFromFileAsync(file).get();
  std::string out;
  const uint32_t pages = (std::min)(doc.PageCount(), kMaxPages);
  for (uint32_t i = 0; i < pages; i++) {
    auto page = doc.GetPage(i);
    const auto size = page.Size();
    const double long_side = (std::max)(size.Width, size.Height);
    winrt::Windows::Data::Pdf::PdfPageRenderOptions options;
    if (long_side > 0) {
      const double s = 2400.0 / long_side;  // ~2400 px on the long side, like macOS
      options.DestinationWidth(static_cast<uint32_t>(std::lround(size.Width * s)));
      options.DestinationHeight(static_cast<uint32_t>(std::lround(size.Height * s)));
    }
    wss::InMemoryRandomAccessStream stream;
    page.RenderToStreamAsync(stream, options).get();
    stream.Seek(0);
    const std::string text = Ocr(Decode(stream, OcrMaxSide()));
    if (!text.empty()) {
      if (!out.empty()) out += "\n\n";
      out += text;
    }
  }
  return out;
}

// ------------------------------------------------------------------ objects (Windows ML)

// Pixels of an upright BGRA bitmap.
struct Pixels {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> bgra;
};

Pixels ReadPixels(const wgi::SoftwareBitmap& bitmap) {
  Pixels p;
  p.width = static_cast<uint32_t>(bitmap.PixelWidth());
  p.height = static_cast<uint32_t>(bitmap.PixelHeight());
  wss::Buffer buffer(p.width * p.height * 4);
  bitmap.CopyToBuffer(buffer);
  p.bgra.assign(buffer.data(), buffer.data() + static_cast<size_t>(p.width) * p.height * 4);
  return p;
}

constexpr uint32_t kSide = 224;

// Bilinear resample of the source rectangle (sx, sy, sw, sh) into a normalised
// 3x224x224 RGB tensor, as MobileNetV2 expects (ImageNet mean / std).
std::vector<float> ToTensor(const Pixels& p, double sx, double sy, double sw, double sh) {
  static const float kMean[3] = {0.485f, 0.456f, 0.406f};
  static const float kStd[3] = {0.229f, 0.224f, 0.225f};
  std::vector<float> t(3 * kSide * kSide);
  const auto at = [&](uint32_t x, uint32_t y, int c) -> float {
    const size_t i = (static_cast<size_t>(y) * p.width + x) * 4;
    return static_cast<float>(p.bgra[i + 2 - c]);  // BGRA → R, G, B
  };
  for (uint32_t y = 0; y < kSide; y++) {
    const double fy = (std::min)(sy + (y + 0.5) * sh / kSide - 0.5, static_cast<double>(p.height - 1));
    const double cy = (std::max)(0.0, fy);
    const uint32_t y0 = static_cast<uint32_t>(cy);
    const uint32_t y1 = (std::min)(y0 + 1, p.height - 1);
    const float wy = static_cast<float>(cy - y0);
    for (uint32_t x = 0; x < kSide; x++) {
      const double fx = (std::min)(sx + (x + 0.5) * sw / kSide - 0.5, static_cast<double>(p.width - 1));
      const double cx = (std::max)(0.0, fx);
      const uint32_t x0 = static_cast<uint32_t>(cx);
      const uint32_t x1 = (std::min)(x0 + 1, p.width - 1);
      const float wx = static_cast<float>(cx - x0);
      for (int c = 0; c < 3; c++) {
        const float top = at(x0, y0, c) * (1 - wx) + at(x1, y0, c) * wx;
        const float bottom = at(x0, y1, c) * (1 - wx) + at(x1, y1, c) * wx;
        const float v = (top * (1 - wy) + bottom * wy) / 255.0f;
        t[static_cast<size_t>(c) * kSide * kSide + static_cast<size_t>(y) * kSide + x] = (v - kMean[c]) / kStd[c];
      }
    }
  }
  return t;
}

class Classifier {
 public:
  static Classifier& Instance() {
    static Classifier c;
    return c;
  }

  bool Available() {
    std::lock_guard<std::mutex> lock(mutex_);
    return Load();
  }

  // Class probabilities: the best of the whole picture squashed to a square and its
  // centre crop (tested on real photos: neither view wins every time).
  std::vector<float> Classify(const Pixels& p) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<float> best;
    if (!Load() || p.width == 0 || p.height == 0) return best;
    const double w = p.width, h = p.height, s = (std::min)(w, h);
    for (const auto& view : {ToTensor(p, 0, 0, w, h), ToTensor(p, (w - s) / 2, (h - s) / 2, s, s)}) {
      std::vector<float> probs = Run(view);
      if (best.empty()) {
        best = probs;
      } else {
        for (size_t i = 0; i < best.size() && i < probs.size(); i++) best[i] = (std::max)(best[i], probs[i]);
      }
    }
    return best;
  }

 private:
  bool Load() {
    if (tried_) return session_ != nullptr;
    tried_ = true;
    try {
      wchar_t exe[MAX_PATH];
      const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
      std::wstring dir(exe, n);
      dir = dir.substr(0, dir.find_last_of(L"\\/"));
      auto model = wai::LearningModel::LoadFromFilePath(dir + L"\\data\\models\\mobilenetv2-7.onnx");
      session_ = wai::LearningModelSession(model, wai::LearningModelDevice(wai::LearningModelDeviceKind::Cpu));
      input_ = model.InputFeatures().GetAt(0).Name();
      output_ = model.OutputFeatures().GetAt(0).Name();
    } catch (...) {
      session_ = nullptr;
    }
    return session_ != nullptr;
  }

  std::vector<float> Run(const std::vector<float>& tensor) {
    wai::LearningModelBinding binding(session_);
    binding.Bind(input_, wai::TensorFloat::CreateFromArray({1, 3, kSide, kSide}, tensor));
    auto result = session_.Evaluate(binding, L"");
    auto out = result.Outputs().Lookup(output_).as<wai::TensorFloat>().GetAsVectorView();
    std::vector<float> logits(out.Size());
    out.GetMany(0, logits);
    // Softmax.
    const float top = *std::max_element(logits.begin(), logits.end());
    double sum = 0;
    for (auto& v : logits) {
      v = std::exp(v - top);
      sum += v;
    }
    for (auto& v : logits) v = static_cast<float>(v / sum);
    return logits;
  }

  std::mutex mutex_;
  bool tried_ = false;
  wai::LearningModelSession session_{nullptr};
  winrt::hstring input_;
  winrt::hstring output_;
};

// Top classes as [["imagenet:<id>", p], …]; Dart maps them onto search words.
EncodableList TopClasses(const std::vector<float>& probs, size_t count) {
  std::vector<size_t> order(probs.size());
  for (size_t i = 0; i < order.size(); i++) order[i] = i;
  const size_t n = (std::min)(count, order.size());
  std::partial_sort(order.begin(), order.begin() + n, order.end(),
                    [&](size_t a, size_t b) { return probs[a] > probs[b]; });
  EncodableList out;
  for (size_t k = 0; k < n; k++) {
    if (probs[order[k]] < 0.01f) break;
    out.push_back(EncodableList{EncodableValue("imagenet:" + std::to_string(order[k])),
                                EncodableValue(static_cast<double>(probs[order[k]]))});
  }
  return out;
}

EncodableValue AnalyzeImage(const std::string& path) {
  EncodableMap out{{EncodableValue("text"), EncodableValue(std::string())},
                   {EncodableValue("labels"), EncodableValue(EncodableList())}};
  if (EndsWithPdf(path)) {
    out[EncodableValue("text")] = EncodableValue(OcrPdf(path));
    return EncodableValue(out);
  }
  auto stream = OpenFile(path);
  try {
    out[EncodableValue("text")] = EncodableValue(Ocr(Decode(stream, OcrMaxSide())));
  } catch (...) {
  }
  try {
    stream.Seek(0);
    // ("small" is a macro in the Windows headers.)
    const Pixels preview = ReadPixels(Decode(stream, 448));
    out[EncodableValue("labels")] = EncodableValue(TopClasses(Classifier::Instance().Classify(preview), 20));
  } catch (...) {
  }
  return EncodableValue(out);
}

// ------------------------------------------------------------------ video frames

std::vector<std::string> SplitLines(const std::string& text) {
  std::vector<std::string> lines;
  std::stringstream ss(text);
  std::string line;
  while (std::getline(ss, line)) {
    const auto b = line.find_first_not_of(" \t\r");
    if (b == std::string::npos) continue;
    const auto e = line.find_last_not_of(" \t\r");
    lines.push_back(line.substr(b, e - b + 1));
  }
  return lines;
}

// Text shown on screen, each new line timed to the frame where it first appears.
EncodableList AnalyzeVideo(const std::string& path, double budget_seconds) {
  using winrt::Windows::Foundation::TimeSpan;
  constexpr double kMaxFrames = 400;
  constexpr double kMinStep = 2.0;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(static_cast<int64_t>(budget_seconds * 1000));

  EncodableList out;
  if (!OcrEngineForThread()) return out;
  auto file = wst::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
  auto clip = winrt::Windows::Media::Editing::MediaClip::CreateFromFileAsync(file).get();
  const double duration = std::chrono::duration<double>(clip.OriginalDuration()).count();
  if (!(duration > 0)) return out;

  winrt::Windows::Media::Editing::MediaComposition composition;
  composition.Clips().Append(clip);
  int32_t width = 1280, height = 720;
  try {
    const auto props = clip.GetVideoEncodingProperties();
    if (props.Width() > 0 && props.Height() > 0) {
      const double s = (std::min)(1.0, 1920.0 / (std::max)(props.Width(), props.Height()));
      width = static_cast<int32_t>(std::lround(props.Width() * s));
      height = static_cast<int32_t>(std::lround(props.Height() * s));
    }
  } catch (...) {
  }

  const double step = (std::max)(kMinStep, duration / kMaxFrames);
  std::set<std::string> previous;
  for (double t = (std::min)(0.5, duration / 2); t < duration; t += step) {
    if (g_video_cancelled || std::chrono::steady_clock::now() > deadline) break;
    try {
      const auto at = std::chrono::duration_cast<TimeSpan>(std::chrono::duration<double>(t));
      auto frame = composition
                       .GetThumbnailAsync(at, width, height,
                                          winrt::Windows::Media::Editing::VideoFramePrecision::NearestFrame)
                       .get();
      const auto lines = SplitLines(Ocr(Decode(frame, OcrMaxSide())));
      std::string fresh;
      for (const auto& l : lines) {
        if (previous.count(l)) continue;
        if (!fresh.empty()) fresh += "\n";
        fresh += l;
      }
      if (!fresh.empty()) {
        out.push_back(EncodableMap{{EncodableValue("t"), EncodableValue(t)},
                                   {EncodableValue("text"), EncodableValue(fresh)}});
      }
      previous = std::set<std::string>(lines.begin(), lines.end());
    } catch (...) {
      // An unreadable frame – try the next one.
    }
  }
  return out;
}

// ------------------------------------------------------------------ channels

void HandleOcr(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  if (method == "isAvailable") {
    auto r = Share(std::move(result));
    RunInBackground([r]() {
      bool ok = false;
      try {
        ok = OcrEngineForThread() != nullptr || Classifier::Instance().Available();
      } catch (...) {
      }
      Reply([r, ok]() { r->Success(EncodableValue(ok)); });
    });
    return;
  }
  if (method != "recognize" && method != "analyzeImage") {
    result->NotImplemented();
    return;
  }
  const std::string* path = StringArg(call, "path");
  if (!path) {
    result->Error("bad_args", "path required");
    return;
  }
  auto r = Share(std::move(result));
  const bool full = method == "analyzeImage";
  RunInBackground([r, p = *path, full]() {
    EncodableValue value = full ? EncodableValue(EncodableMap{}) : EncodableValue(std::string());
    try {
      if (full) {
        value = AnalyzeImage(p);
      } else {
        value = EncodableValue(EndsWithPdf(p) ? OcrPdf(p) : Ocr(Decode(OpenFile(p), OcrMaxSide())));
      }
    } catch (...) {
    }
    Reply([r, value]() { r->Success(value); });
  });
}

// One video at a time, like macOS.
std::mutex g_video_mutex;

void HandleVideo(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  if (method == "isAvailable") {
    auto r = Share(std::move(result));
    RunInBackground([r]() {
      bool ok = false;
      try {
        ok = OcrEngineForThread() != nullptr;
      } catch (...) {
      }
      Reply([r, ok]() { r->Success(EncodableValue(ok)); });
    });
    return;
  }
  if (method == "cancel") {
    g_video_cancelled = true;
    result->Success();
    return;
  }
  if (method != "analyze") {
    result->NotImplemented();
    return;
  }
  const std::string* path = StringArg(call, "path");
  if (!path) {
    result->Error("bad_args", "path required");
    return;
  }
  const double budget = DoubleArg(call, "budgetSeconds", 600);
  g_video_cancelled = false;
  auto r = Share(std::move(result));
  RunInBackground([r, p = *path, budget]() {
    std::lock_guard<std::mutex> lock(g_video_mutex);
    EncodableList segments;
    try {
      segments = AnalyzeVideo(p, budget);
    } catch (...) {
    }
    Reply([r, segments]() { r->Success(EncodableValue(segments)); });
  });
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  g_ocr_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "smart_file_search/ocr", &codec);
  g_ocr_channel->SetMethodCallHandler(HandleOcr);
  g_video_channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "smart_file_search/video", &codec);
  g_video_channel->SetMethodCallHandler(HandleVideo);
}

bool HandleMessage(UINT message) {
  if (message != kReplyMessage) return false;
  std::deque<std::function<void()>> ready;
  {
    std::lock_guard<std::mutex> lock(g_reply_mutex);
    ready.swap(g_replies);
  }
  for (auto& fn : ready) fn();
  return true;
}

}  // namespace native_analysis
