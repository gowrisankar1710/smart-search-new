#include "native_analysis.h"

#include <sapi.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.AI.MachineLearning.h>
#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Editing.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Media.Transcoding.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <condition_variable>
#include <chrono>
#include <cmath>
#include <deque>
#include <functional>
#include <map>
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
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_window_channel;
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
    // Below normal: the PC stays responsive while files are read.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      work();
    } catch (...) {
    }
    winrt::uninit_apartment();
  }).detach();
}

// Images: a few long-lived workers, so each keeps its OCR engine (created once per
// thread) instead of building one per picture. Sized to the CPU, like the Dart side.
class ImagePool {
 public:
  static ImagePool& Instance() {
    static ImagePool* pool = new ImagePool();  // never destroyed: threads run until exit
    return *pool;
  }

  void Post(std::function<void()> work) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      jobs_.push_back(std::move(work));
    }
    ready_.notify_one();
  }

 private:
  ImagePool() {
    const unsigned n = (std::max)(2u, (std::min)(4u, std::thread::hardware_concurrency() / 2));
    for (unsigned i = 0; i < n; i++) std::thread([this]() { Loop(); }).detach();
  }

  void Loop() {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    for (;;) {
      std::function<void()> work;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this]() { return !jobs_.empty(); });
        work = std::move(jobs_.front());
        jobs_.pop_front();
      }
      try {
        work();
      } catch (...) {
      }
    }
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<std::function<void()>> jobs_;
};

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
// With |min_side|, smaller pictures are enlarged (up to 2.5x) towards it: Windows OCR
// misses text only a few pixels tall – screenshots, scaled-down photos, video frames –
// which it reads reliably once enlarged.
wgi::SoftwareBitmap Decode(const wss::IRandomAccessStream& stream, uint32_t max_side, uint32_t min_side = 0) {
  auto decoder = wgi::BitmapDecoder::CreateAsync(stream).get();
  wgi::BitmapTransform transform;
  // Scaling happens before rotation, so it uses the stored (unrotated) size.
  const uint32_t w = decoder.PixelWidth();
  const uint32_t h = decoder.PixelHeight();
  const uint32_t long_side = (std::max)(w, h);
  double s = 1.0;
  if (max_side > 0 && long_side > max_side) {
    s = static_cast<double>(max_side) / static_cast<double>(long_side);
  } else if (min_side > 0 && long_side > 0 && long_side < min_side) {
    s = (std::min)(2.5, static_cast<double>(min_side) / static_cast<double>(long_side));
  }
  if (s != 1.0) {
    transform.ScaledWidth((std::max)(1u, static_cast<uint32_t>(std::lround(w * s))));
    transform.ScaledHeight((std::max)(1u, static_cast<uint32_t>(std::lround(h * s))));
    transform.InterpolationMode(s < 1 ? wgi::BitmapInterpolationMode::Fant : wgi::BitmapInterpolationMode::Cubic);
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

using winrt::Windows::Media::Ocr::OcrEngine;

// The user's display languages first. If none of them has Windows OCR installed (an
// Indian or other regional profile often hasn't), any installed OCR language –
// English preferred – instead of no text reading at all.
OcrEngine CreateOcrEngine() {
  try {
    if (auto e = OcrEngine::TryCreateFromUserProfileLanguages()) return e;
  } catch (...) {
  }
  try {
    const auto langs = OcrEngine::AvailableRecognizerLanguages();
    for (const auto& l : langs) {
      const std::wstring tag = l.LanguageTag().c_str();
      if (tag.rfind(L"en", 0) == 0) {
        if (auto e = OcrEngine::TryCreateFromLanguage(l)) return e;
      }
    }
    for (const auto& l : langs) {
      if (auto e = OcrEngine::TryCreateFromLanguage(l)) return e;
    }
  } catch (...) {
  }
  return nullptr;
}

OcrEngine OcrEngineForThread() {
  thread_local OcrEngine engine{nullptr};
  thread_local bool tried = false;
  if (!tried) {
    tried = true;
    engine = CreateOcrEngine();
  }
  return engine;
}

// ------------------------------------------------------------------ Hindi / Tamil (Tesseract)
//
// Windows OCR has no Hindi or Tamil. Tesseract (installed by the user) reads them with the
// models bundled in the app; Dart says where both are, and until then nothing runs. Only
// lines with a confidently read Devanagari or Tamil word are kept: Windows OCR already has
// the English, and Tesseract turns plain photos and Latin text into low-confidence noise.

struct IndicConfig {
  std::wstring bin;
  std::wstring tessdata;
  std::wstring languages;
};

std::mutex g_indic_mutex;
std::shared_ptr<const IndicConfig> g_indic;
std::atomic<uint32_t> g_indic_counter{0};

std::shared_ptr<const IndicConfig> IndicConfigNow() {
  std::lock_guard<std::mutex> lock(g_indic_mutex);
  return g_indic;
}

bool IndicReady() { return IndicConfigNow() != nullptr; }

void ConfigureIndic(const std::string& bin, const std::string& tessdata, const std::string& languages) {
  // One thread per Tesseract run: several pictures are read at once.
  SetEnvironmentVariableW(L"OMP_THREAD_LIMIT", L"1");
  auto c = std::make_shared<IndicConfig>();
  c->bin = std::wstring(winrt::to_hstring(bin));
  c->tessdata = std::wstring(winrt::to_hstring(tessdata));
  c->languages = std::wstring(winrt::to_hstring(languages));
  std::lock_guard<std::mutex> lock(g_indic_mutex);
  g_indic = c;
}

bool WritePng(const wgi::SoftwareBitmap& bitmap, const std::wstring& path) {
  const auto opaque =
      wgi::SoftwareBitmap::Convert(bitmap, wgi::BitmapPixelFormat::Bgra8, wgi::BitmapAlphaMode::Ignore);
  wss::InMemoryRandomAccessStream stream;
  auto encoder = wgi::BitmapEncoder::CreateAsync(wgi::BitmapEncoder::PngEncoderId(), stream).get();
  encoder.SetSoftwareBitmap(opaque);
  encoder.FlushAsync().get();
  const auto size = static_cast<uint32_t>(stream.Size());
  wss::Buffer buffer(size);
  stream.Seek(0);
  stream.ReadAsync(buffer, size, wss::InputStreamOptions::None).get();
  HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool ok = WriteFile(f, buffer.data(), buffer.Length(), &written, nullptr) && written == buffer.Length();
  CloseHandle(f);
  return ok;
}

// Runs |command| without a window and returns what it printed, or "" if it failed.
// A run that takes longer than 20 s is stopped.
std::string RunCapture(std::wstring command) {
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE read = nullptr, write = nullptr;
  if (!CreatePipe(&read, &write, &sa, 0)) return "";
  SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                           OPEN_EXISTING, 0, nullptr);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = nul;
  si.hStdOutput = write;
  si.hStdError = nul;
  PROCESS_INFORMATION pi{};
  const BOOL started = CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
                                      nullptr, &si, &pi);
  CloseHandle(write);
  if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  if (!started) {
    CloseHandle(read);
    return "";
  }
  HANDLE process = pi.hProcess;
  std::thread watchdog([process]() {
    if (WaitForSingleObject(process, 20000) == WAIT_TIMEOUT) TerminateProcess(process, 1);
  });
  std::string out;
  char chunk[4096];
  DWORD n = 0;
  while (ReadFile(read, chunk, sizeof(chunk), &n, nullptr) && n > 0) out.append(chunk, n);
  watchdog.join();
  DWORD code = 1;
  GetExitCodeProcess(process, &code);
  CloseHandle(read);
  CloseHandle(pi.hThread);
  CloseHandle(process);
  return code == 0 ? out : "";
}

// At least two Devanagari (U+0900–097F) or Tamil (U+0B80–0BFF) characters: a lone one
// is usually noise. In UTF-8 both blocks start E0 A4/A5 and E0 AE/AF.
bool IsIndicWord(const std::string& w) {
  int count = 0;
  for (size_t i = 0; i + 1 < w.size(); i++) {
    const auto b0 = static_cast<unsigned char>(w[i]);
    const auto b1 = static_cast<unsigned char>(w[i + 1]);
    if (b0 == 0xE0 && (b1 == 0xA4 || b1 == 0xA5 || b1 == 0xAE || b1 == 0xAF) && ++count >= 2) return true;
  }
  return false;
}

std::string WithoutJoiners(std::string w) {
  for (const char* j : {"\xE2\x80\x8C", "\xE2\x80\x8D"}) {  // zero-width (non-)joiner
    for (size_t at; (at = w.find(j)) != std::string::npos;) w.erase(at, 3);
  }
  return w;
}

// Tesseract TSV rows: level, page, block, paragraph, line, word, left, top, width,
// height, conf, text. Words below this confidence (0–100) are dropped: real text
// scores 80+, noise under 30.
std::vector<std::string> ParseIndicTsv(const std::string& tsv, bool indic_only) {
  constexpr double kMinConfidence = 60;
  std::vector<std::string> order;
  std::map<std::string, std::string> lines;
  std::set<std::string> indic;
  std::stringstream rows(tsv);
  std::string row;
  bool header = true;
  while (std::getline(rows, row)) {
    if (header) {
      header = false;
      continue;
    }
    if (!row.empty() && row.back() == '\r') row.pop_back();
    std::vector<std::string> c;
    std::stringstream cells(row);
    std::string cell;
    while (std::getline(cells, cell, '\t')) c.push_back(cell);
    if (c.size() < 12 || c[0] != "5") continue;
    double conf = -1;
    try {
      conf = std::stod(c[10]);
    } catch (...) {
      continue;
    }
    if (conf < kMinConfidence) continue;
    std::string word = WithoutJoiners(c[11]);
    const auto b = word.find_first_not_of(" \t");
    if (b == std::string::npos) continue;
    word = word.substr(b, word.find_last_not_of(" \t") - b + 1);
    const std::string key = c[2] + "." + c[3] + "." + c[4];
    auto it = lines.find(key);
    if (it == lines.end()) {
      order.push_back(key);
      lines[key] = word;
    } else {
      it->second += " " + word;
    }
    if (IsIndicWord(word)) indic.insert(key);
  }
  std::vector<std::string> out;
  for (const auto& k : order) {
    if (!indic_only || indic.count(k)) out.push_back(lines[k]);
  }
  return out;
}

// With |english|, there is no Windows OCR language on this PC: Tesseract reads English
// too, and every confident line is kept.
std::vector<std::string> IndicLines(const wgi::SoftwareBitmap& bitmap, bool english) {
  const auto c = IndicConfigNow();
  if (!c) return {};
  wchar_t dir[MAX_PATH];
  const DWORD n = GetTempPathW(MAX_PATH, dir);
  if (n == 0 || n > MAX_PATH) return {};
  const std::wstring png = std::wstring(dir, n) + L"sfs-ocr-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                           std::to_wstring(g_indic_counter.fetch_add(1)) + L".png";
  std::vector<std::string> out;
  try {
    if (WritePng(bitmap, png)) {
      const std::wstring command = L"\"" + c->bin + L"\" \"" + png + L"\" stdout -l " + (english ? L"eng+" : L"") + c->languages +
                                   L" --tessdata-dir \"" + c->tessdata + L"\" --psm 3 -c tessedit_create_tsv=1";
      out = ParseIndicTsv(RunCapture(command), !english);
    }
  } catch (...) {
  }
  DeleteFileW(png.c_str());
  return out;
}

// Pictures smaller than this are enlarged before OCR (see Decode).
constexpr uint32_t kOcrMinSide = 1800;

// Camera photos are 4000+ px; text stays readable at 2600 and OCR takes about half as long.
uint32_t OcrMaxSide() {
  try {
    return (std::min)(winrt::Windows::Media::Ocr::OcrEngine::MaxImageDimension(), 2600u);
  } catch (...) {
    return 2600u;
  }
}

// Windows OCR's lines, then any Hindi / Tamil lines Tesseract reads in the same picture.
std::string Ocr(const wgi::SoftwareBitmap& bitmap) {
  std::string text;
  auto engine = OcrEngineForThread();
  if (engine) {
    auto result = engine.RecognizeAsync(bitmap).get();
    std::wstring out;
    for (const auto& line : result.Lines()) {
      if (!out.empty()) out += L"\n";
      out += line.Text().c_str();
    }
    text = winrt::to_string(out);
  }
  for (const auto& l : IndicLines(bitmap, !engine)) {
    if (!text.empty()) text += "\n";
    text += l;
  }
  return text;
}

// Darker than this (0-255) turns black, the rest white. Measured on shopping-app
// screenshots: Windows OCR skipped the large bold prices (next to struck-out prices and
// coloured arrows) entirely, and read them in this black-and-white version.
constexpr uint32_t kBlackAndWhiteCut = 170;

wgi::SoftwareBitmap BlackAndWhite(const wgi::SoftwareBitmap& bitmap) {
  const uint32_t w = static_cast<uint32_t>(bitmap.PixelWidth());
  const uint32_t h = static_cast<uint32_t>(bitmap.PixelHeight());
  const uint32_t size = w * h * 4;
  wss::Buffer buffer(size);
  bitmap.CopyToBuffer(buffer);
  buffer.Length(size);
  uint8_t* px = buffer.data();
  for (uint32_t i = 0; i < size; i += 4) {
    const uint32_t v = (114 * px[i] + 587 * px[i + 1] + 299 * px[i + 2]) / 1000;  // BGRA
    const uint8_t bw = v < kBlackAndWhiteCut ? 0 : 255;
    px[i] = px[i + 1] = px[i + 2] = bw;
    px[i + 3] = 255;
  }
  return wgi::SoftwareBitmap::CreateCopyFromBuffer(buffer, wgi::BitmapPixelFormat::Bgra8, w, h,
                                                   wgi::BitmapAlphaMode::Premultiplied);
}

std::vector<std::string> SplitLines(const std::string& text);  // below

// Pictures: the normal reading, then lines a black-and-white look adds. Only when the
// first look found text – a photo without any is not read twice.
std::string OcrPicture(const wgi::SoftwareBitmap& bitmap) {
  std::string text = Ocr(bitmap);
  auto engine = OcrEngineForThread();
  if (text.empty() || !engine) return text;
  try {
    const auto lines = SplitLines(text);
    std::set<std::string> seen(lines.begin(), lines.end());
    auto result = engine.RecognizeAsync(BlackAndWhite(bitmap)).get();
    for (const auto& line : result.Lines()) {
      const std::string l = winrt::to_string(line.Text());
      if (l.empty() || !seen.insert(l).second) continue;
      text += "\n";
      text += l;
    }
  } catch (...) {
  }
  return text;
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
    out[EncodableValue("text")] = EncodableValue(OcrPicture(Decode(stream, OcrMaxSide(), kOcrMinSide)));
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

void SendVideoProgress(const std::string& path, double fraction);

// ------------------------------------------------------------------ speech (SAPI)
//
// Windows has no modern speech-to-text for files, but its desktop speech engine
// ("Microsoft Speech Recognizer", SAPI 5) can transcribe a WAV file offline. The audio
// is taken out of the video with Windows' own transcoder, then read word by word.

constexpr uint32_t kSpeechRate = 16000;  // 16 kHz, mono, 16-bit: what the engine works in

// The default speech recognizer installed on this PC, or null.
winrt::com_ptr<ISpObjectToken> DefaultRecognizerToken() {
  winrt::com_ptr<ISpObjectTokenCategory> category;
  if (FAILED(CoCreateInstance(__uuidof(SpObjectTokenCategory), nullptr, CLSCTX_ALL, IID_PPV_ARGS(category.put()))) ||
      FAILED(category->SetId(SPCAT_RECOGNIZERS, FALSE))) {
    return nullptr;
  }
  wchar_t* id = nullptr;
  if (FAILED(category->GetDefaultTokenId(&id)) || !id) return nullptr;
  winrt::com_ptr<ISpObjectToken> token;
  const bool ok = SUCCEEDED(CoCreateInstance(__uuidof(SpObjectToken), nullptr, CLSCTX_ALL, IID_PPV_ARGS(token.put()))) &&
                  SUCCEEDED(token->SetId(nullptr, id, FALSE));
  CoTaskMemFree(id);
  return ok ? token : nullptr;
}

// Can this PC transcribe speech at all? (Checked once.)
bool SpeechAvailable() {
  static const bool available = []() {
    try {
      return DefaultRecognizerToken() != nullptr;
    } catch (...) {
      return false;
    }
  }();
  return available;
}

std::wstring TempWavPath() {
  wchar_t dir[MAX_PATH];
  const DWORD n = GetTempPathW(MAX_PATH, dir);
  static std::atomic<int> counter{0};
  return std::wstring(dir, n) + L"sfs-speech-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
         std::to_wstring(counter++) + L".wav";
}

// The video's sound as a 16 kHz mono WAV file; false if it has none or can't be read.
bool ExtractAudio(const std::string& video, const std::wstring& wav) {
  namespace mp = winrt::Windows::Media::MediaProperties;
  auto src = wst::StorageFile::GetFileFromPathAsync(winrt::to_hstring(video)).get();
  const auto slash = wav.find_last_of(L"\\/");
  auto folder = wst::StorageFolder::GetFolderFromPathAsync(wav.substr(0, slash)).get();
  auto dst = folder.CreateFileAsync(wav.substr(slash + 1), wst::CreationCollisionOption::ReplaceExisting).get();
  auto profile = mp::MediaEncodingProfile::CreateWav(mp::AudioEncodingQuality::Low);
  profile.Audio(mp::AudioEncodingProperties::CreatePcm(kSpeechRate, 1, 16));
  profile.Video(nullptr);
  winrt::Windows::Media::Transcoding::MediaTranscoder transcoder;
  auto prepared = transcoder.PrepareFileTranscodeAsync(src, dst, profile).get();
  if (!prepared.CanTranscode()) return false;
  prepared.TranscodeAsync().get();
  return true;
}

void ReleaseEvent(SPEVENT& e) {
  if (e.elParamType == SPET_LPARAM_IS_OBJECT || e.elParamType == SPET_LPARAM_IS_TOKEN) {
    if (e.lParam) reinterpret_cast<IUnknown*>(e.lParam)->Release();
  } else if (e.elParamType == SPET_LPARAM_IS_POINTER || e.elParamType == SPET_LPARAM_IS_STRING) {
    if (e.lParam) CoTaskMemFree(reinterpret_cast<void*>(e.lParam));
  }
  e.lParam = 0;
}

// Every recognised word with its own start time, like macOS: [{"t": s, "text": word}].
// |progress| gets 0–1 as the audio is worked through.
EncodableList Transcribe(const std::wstring& wav, double duration, const std::function<bool()>& stop,
                         const std::function<void(double)>& progress) {
  EncodableList out;
  auto token = DefaultRecognizerToken();
  if (!token) return out;
  winrt::com_ptr<ISpRecognizer> recognizer;
  winrt::check_hresult(
      CoCreateInstance(__uuidof(SpInprocRecognizer), nullptr, CLSCTX_ALL, IID_PPV_ARGS(recognizer.put())));
  winrt::check_hresult(recognizer->SetRecognizer(token.get()));
  winrt::com_ptr<ISpStream> stream;
  winrt::check_hresult(CoCreateInstance(__uuidof(SpStream), nullptr, CLSCTX_ALL, IID_PPV_ARGS(stream.put())));
  // No format given: it is read from the WAV header.
  winrt::check_hresult(stream->BindToFile(wav.c_str(), SPFM_OPEN_READONLY, nullptr, nullptr, 0));
  winrt::check_hresult(recognizer->SetInput(stream.get(), FALSE));

  winrt::com_ptr<ISpRecoContext> context;
  winrt::check_hresult(recognizer->CreateRecoContext(context.put()));
  const ULONGLONG interest = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_END_SR_STREAM);
  winrt::check_hresult(context->SetInterest(interest, interest));
  winrt::check_hresult(context->SetNotifyWin32Event());
  const HANDLE ready = context->GetNotifyEventHandle();

  winrt::com_ptr<ISpRecoGrammar> grammar;
  winrt::check_hresult(context->CreateGrammar(1, grammar.put()));
  winrt::check_hresult(grammar->LoadDictation(nullptr, SPLO_STATIC));
  winrt::check_hresult(grammar->SetDictationState(SPRS_ACTIVE));
  recognizer->SetRecoState(SPRST_ACTIVE);

  const double bytes_per_second = kSpeechRate * 2.0;
  bool finished = false;
  while (!finished) {
    if (stop()) break;
    WaitForSingleObject(ready, 500);
    SPEVENT e{};
    ULONG fetched = 0;
    while (SUCCEEDED(context->GetEvents(1, &e, &fetched)) && fetched == 1) {
      if (e.eEventId == SPEI_END_SR_STREAM) finished = true;
      if (e.eEventId == SPEI_RECOGNITION && e.elParamType == SPET_LPARAM_IS_OBJECT && e.lParam) {
        auto* result = reinterpret_cast<ISpRecoResult*>(e.lParam);
        SPPHRASE* phrase = nullptr;
        if (SUCCEEDED(result->GetPhrase(&phrase)) && phrase) {
          const double start = static_cast<double>(phrase->ullAudioStreamPosition) / bytes_per_second;
          for (ULONG i = 0; i < phrase->Rule.ulCountOfElements; i++) {
            const auto& el = phrase->pElements[i];
            if (!el.pszDisplayText || !*el.pszDisplayText) continue;
            const double t = start + static_cast<double>(el.ulAudioTimeOffset) / 1e7;
            out.push_back(EncodableMap{{EncodableValue("t"), EncodableValue(t)},
                                       {EncodableValue("text"), EncodableValue(winrt::to_string(el.pszDisplayText))}});
          }
          if (duration > 0) progress((std::min)(1.0, start / duration));
          CoTaskMemFree(phrase);
        }
      }
      ReleaseEvent(e);
      fetched = 0;
    }
  }
  recognizer->SetRecoState(SPRST_INACTIVE);
  return out;
}

// What is said in the video, or nothing if speech can't be read here.
EncodableList VideoSpeech(const std::string& path, double duration, const std::function<bool()>& stop,
                          const std::function<void(double)>& progress) {
  if (!SpeechAvailable()) return {};
  const std::wstring wav = TempWavPath();
  EncodableList words;
  try {
    if (ExtractAudio(path, wav)) words = Transcribe(wav, duration, stop, progress);
  } catch (...) {
  }
  DeleteFileW(wav.c_str());
  return words;
}

// Text shown on screen, each new line timed to the frame where it first appears.
EncodableList AnalyzeVideo(const std::string& path, double budget_seconds) {
  using winrt::Windows::Foundation::TimeSpan;
  constexpr double kMaxFrames = 400;
  constexpr double kMinStep = 2.0;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(static_cast<int64_t>(budget_seconds * 1000));

  EncodableList out;
  if (!OcrEngineForThread() && !IndicReady()) return out;
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
  // With speech, frames are the first 40 % of the progress and speech the rest.
  const bool speaks = SpeechAvailable();
  const double frame_share = speaks ? 0.4 : 1.0;
  double reported = -1;
  const auto report = [&](double f) {
    if (f - reported >= 0.01 || f >= 1) {  // at most every 1 %
      reported = f;
      SendVideoProgress(path, f);
    }
  };
  const auto stop = [&]() { return g_video_cancelled.load() || std::chrono::steady_clock::now() > deadline; };
  report(0);
  for (double t = (std::min)(0.5, duration / 2); t < duration; t += step) {
    if (stop()) break;
    report(t / duration * frame_share);
    try {
      const auto at = std::chrono::duration_cast<TimeSpan>(std::chrono::duration<double>(t));
      auto frame = composition
                       .GetThumbnailAsync(at, width, height,
                                          // Keyframes decode directly – an exact frame
                                          // means decoding from the previous keyframe,
                                          // seconds per frame.
                                          winrt::Windows::Media::Editing::VideoFramePrecision::NearestKeyFrame)
                       .get();
      const auto lines = SplitLines(Ocr(Decode(frame, OcrMaxSide(), kOcrMinSide)));
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
  if (speaks && !stop()) {
    // Spoken words first, then on-screen text – each run in time order, as on macOS.
    EncodableList words = VideoSpeech(path, duration, stop, [&](double f) { report(frame_share + f * (1 - frame_share)); });
    words.insert(words.end(), out.begin(), out.end());
    return words;
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
        ok = OcrEngineForThread() != nullptr || IndicReady() || Classifier::Instance().Available();
      } catch (...) {
      }
      Reply([r, ok]() { r->Success(EncodableValue(ok)); });
    });
    return;
  }
  if (method == "configureIndic") {
    const std::string* bin = StringArg(call, "bin");
    const std::string* tessdata = StringArg(call, "tessdata");
    const std::string* languages = StringArg(call, "languages");
    if (!bin || !tessdata || !languages) {
      result->Error("bad_args", "bin, tessdata, languages required");
      return;
    }
    ConfigureIndic(*bin, *tessdata, *languages);
    result->Success();
    return;
  }
  if (method == "info") {
    // Which OCR language is in use ("" = none installed) and whether objects are recognised.
    auto r = Share(std::move(result));
    RunInBackground([r]() {
      std::string lang;
      bool objects = false;
      try {
        if (auto e = OcrEngineForThread()) lang = winrt::to_string(e.RecognizerLanguage().LanguageTag());
      } catch (...) {
      }
      try {
        objects = Classifier::Instance().Available();
      } catch (...) {
      }
      Reply([r, lang, objects]() {
        r->Success(EncodableValue(EncodableMap{{EncodableValue("ocrLanguage"), EncodableValue(lang)},
                                               {EncodableValue("objects"), EncodableValue(objects)}}));
      });
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
  ImagePool::Instance().Post([r, p = *path, full]() {
    EncodableValue value = full ? EncodableValue(EncodableMap{}) : EncodableValue(std::string());
    try {
      if (full) {
        value = AnalyzeImage(p);
      } else {
        value = EncodableValue(EndsWithPdf(p) ? OcrPdf(p) : OcrPicture(Decode(OpenFile(p), OcrMaxSide(), kOcrMinSide)));
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
        ok = OcrEngineForThread() != nullptr || IndicReady();
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
  if (method == "speechStatus") {
    // No permission prompt on Windows: speech is read whenever an engine is installed.
    auto r = Share(std::move(result));
    RunInBackground([r]() {
      const bool ok = SpeechAvailable();
      Reply([r, ok]() { r->Success(EncodableValue(std::string(ok ? "granted" : "unavailable"))); });
    });
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

// How far the video being read has got, 0–1: the Search screen shows it as a percentage.
void SendVideoProgress(const std::string& path, double fraction) {
  Reply([path, fraction]() {
    if (!g_video_channel) return;
    g_video_channel->InvokeMethod(
        "progress", std::make_unique<EncodableValue>(EncodableMap{
                        {EncodableValue("path"), EncodableValue(path)},
                        {EncodableValue("fraction"), EncodableValue(fraction)},
                    }));
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
  // Quitting: the window goes away at once while the index is saved behind it.
  g_window_channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "smart_file_search/window", &codec);
  g_window_channel->SetMethodCallHandler([](const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
    if (call.method_name() == "hide") {
      ShowWindow(g_window, SW_HIDE);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
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
