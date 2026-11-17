import Cocoa
import FlutterMacOS
import Vision
import AVFoundation
import Speech

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    // Roomy enough for sidebar + results + details panel; never larger than the screen.
    if let screen = NSScreen.main?.visibleFrame {
      let w = min(1360, screen.width * 0.92), h = min(860, screen.height * 0.9)
      windowFrame = NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 520, height: 480)
    self.title = "Smart Search"

    RegisterGeneratedPlugins(registry: flutterViewController)
    VisionOcr.register(with: flutterViewController.engine.binaryMessenger)
    VideoAnalysis.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// On-device OCR through Apple's Vision framework (same engine as Live Text).
/// Far more accurate than Tesseract on screenshots, photos and stylised text.
enum VisionOcr {
  private static let queue = DispatchQueue(label: "vision-ocr", qos: .utility, attributes: .concurrent)

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "smart_file_search/ocr", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        result(true)
      case "recognize":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path required", details: nil))
          return
        }
        queue.async {
          let text = recognize(path: path)
          DispatchQueue.main.async { result(text) }
        }
      case "analyzeImage":
        // Text + what the picture shows (objects, scenes, clothing…), in one pass.
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path required", details: nil))
          return
        }
        queue.async {
          let out = analyzeImage(path: path)
          DispatchQueue.main.async { result(out) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Labels below this are dropped. Calibrated on real photos: correct labels such as
  /// "koi" often score 0.3–0.5 because the classifier spreads confidence over related labels.
  private static let labelFloor: Float = 0.3
  /// Close-ups (people, salient objects) are classified too – at most this many.
  private static let maxCrops = 3

  private static func analyzeImage(path: String) -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "pdf" {
      return ["text": recognizePdf(url: url), "labels": [[Any]]()]
    }
    return autoreleasepool {
      guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
      else { return ["text": "", "labels": [[Any]]()] }
      let handler = VNImageRequestHandler(cgImage: image, orientation: orientation(src), options: [:])
      let text = textRequest()
      let classify = VNClassifyImageRequest()
      let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
      let people = VNDetectHumanRectanglesRequest()
      if #available(macOS 12.0, *) { people.upperBodyOnly = false }
      try? handler.perform([text, classify, salient, people])
      let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }

      // Whole picture first, then close-ups of people and the main objects: small
      // subjects (a bird on a rock, a saree on a person) score far higher on their own.
      var best: [String: Float] = [:]
      for o in classify.results ?? [] where o.confidence >= labelFloor { best[o.identifier] = o.confidence }
      let boxes = (people.results ?? []).map { $0.boundingBox }
        + (salient.results?.first?.salientObjects ?? []).map { $0.boundingBox }
      for box in cropRegions(boxes) {
        guard let part = crop(image, box, orientation: orientation(src)) else { continue }
        let r = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: part, orientation: orientation(src), options: [:]).perform([r])
        for o in r.results ?? [] {
          let c = o.confidence * 0.9 // a close-up is a little less sure than the whole view
          if c >= labelFloor { best[o.identifier] = max(best[o.identifier] ?? 0, c) }
        }
      }
      let labels = best.sorted { $0.value > $1.value }.prefix(20).map { [$0.key, Double($0.value)] as [Any] }
      return ["text": lines.joined(separator: "\n"), "labels": Array(labels)]
    }
  }

  private static func orientation(_ src: CGImageSource) -> CGImagePropertyOrientation {
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return CGImagePropertyOrientation(rawValue: raw) ?? .up
  }

  /// Padded, de-duplicated regions worth a close look (normalised, lower-left origin).
  private static func cropRegions(_ boxes: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for b in boxes {
      let r = b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.15)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      let area = r.width * r.height
      if area < 0.04 || area > 0.85 { continue } // too small to classify / same as the whole view
      if out.contains(where: { overlap($0, r) > 0.7 }) { continue }
      out.append(r)
      if out.count == maxCrops { break }
    }
    return out
  }

  private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    if i.isNull { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
  }

  /// Vision reports boxes in the image's displayed orientation; the pixels may be rotated.
  private static func crop(_ image: CGImage, _ r: CGRect, orientation: CGImagePropertyOrientation) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var box = r
    switch orientation {
    case .right, .rightMirrored: box = CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
    case .left, .leftMirrored: box = CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    case .down, .downMirrored: box = CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
    default: break
    }
    return image.cropping(to: CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h))
  }

  private static func textRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    if #available(macOS 13.0, *) {
      request.automaticallyDetectsLanguage = true
    }
    return request
  }

  /// Max pages read from a scanned / image-only PDF.
  private static let maxPdfPages = 30

  private static func recognize(path: String) -> String {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "pdf" {
      return recognizePdf(url: url)
    }
    return autoreleasepool { run(VNImageRequestHandler(url: url, options: [:])) }
  }

  /// Scanned or image-only PDFs have no text layer: render each page and read it.
  private static func recognizePdf(url: URL) -> String {
    guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return "" }
    var pages: [String] = []
    for i in 1...min(doc.numberOfPages, maxPdfPages) {
      autoreleasepool {
        guard let page = doc.page(at: i), let image = render(page) else { return }
        let text = run(VNImageRequestHandler(cgImage: image, options: [:]))
        if !text.isEmpty { pages.append(text) }
      }
    }
    return pages.joined(separator: "\n\n")
  }

  private static func render(_ page: CGPDFPage) -> CGImage? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = min(3.0, 2400 / max(box.width, box.height)) // ~2400 px on the long side
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page)
    return ctx.makeImage()
  }

  static func run(_ handler: VNImageRequestHandler) -> String {
    let request = textRequest()
    do {
      try handler.perform([request])
    } catch {
      return ""
    }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
  }
}

/// Reads a video's content with timestamps, entirely on-device:
///  • frames sampled through AVFoundation → Apple Vision reads the on-screen text
///  • the audio track → Apple's on-device Speech recogniser (never the server one)
/// Returns [{"t": seconds, "text": String}]: every spoken word timed on its own, then the
/// on-screen text. Each run is in time order; they are not interleaved, so a spoken phrase
/// stays contiguous (and searchable as a phrase) in the joined text.
enum VideoAnalysis {
  private static let queue = DispatchQueue(label: "video-analysis", qos: .utility)
  private static let lock = NSLock()
  private static var _cancelled = false
  private static var cancelled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _cancelled }
    set { lock.lock(); _cancelled = newValue; lock.unlock() }
  }

  /// At most this many frames are read per video; short videos get one every 2 s.
  private static let maxFrames = 400.0
  private static let minFrameStep = 2.0
  /// Audio is recognised in chunks of this length (keeps memory flat, allows stopping).
  private static let speechChunk = 60.0

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "smart_file_search/video", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        result(true)
      case "cancel":
        cancelled = true
        result(nil)
      case "analyze":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path required", details: nil))
          return
        }
        let budget = (args["budgetSeconds"] as? Double) ?? 600
        cancelled = false
        queue.async {
          let segments = analyze(path: path, budget: budget)
          DispatchQueue.main.async { result(segments) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func analyze(path: String, budget: Double) -> [[String: Any]] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0 else { return [] }
    let deadline = Date().addingTimeInterval(budget)
    func stop() -> Bool { cancelled || Date() > deadline }

    let frames = frameText(asset, duration: duration, stop: stop)
    let words = stop() ? [] : speech(asset, duration: duration, stop: stop)
    return words + frames
  }

  // ---------------------------------------------------------------- on-screen text

  private static func frameText(_ asset: AVURLAsset, duration: Double, stop: () -> Bool) -> [[String: Any]] {
    guard !asset.tracks(withMediaType: .video).isEmpty else { return [] }
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 1920, height: 1920)
    let step = max(minFrameStep, duration / maxFrames)
    let tolerance = CMTime(seconds: step / 4, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tolerance
    gen.requestedTimeToleranceAfter = tolerance

    var out: [[String: Any]] = []
    var previous = Set<String>()
    var t = min(0.5, duration / 2)
    while t < duration, !stop() {
      autoreleasepool {
        var actual = CMTime.zero
        guard let image = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: &actual)
        else { return }
        let lines = VisionOcr.run(VNImageRequestHandler(cgImage: image, options: [:]))
          .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Only lines that just appeared: a slide's text is timed to when it first shows.
        let fresh = lines.filter { !previous.contains($0) }
        if !fresh.isEmpty {
          let at = CMTimeGetSeconds(actual)
          out.append(["t": at.isFinite ? at : t, "text": fresh.joined(separator: "\n")])
        }
        previous = Set(lines)
      }
      t += step
    }
    return out
  }

  // ---------------------------------------------------------------- speech

  private static func authorized() -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return true
    case .notDetermined:
      let done = DispatchSemaphore(value: 0)
      var ok = false
      SFSpeechRecognizer.requestAuthorization { status in
        ok = status == .authorized
        done.signal()
      }
      _ = done.wait(timeout: .now() + 120)
      return ok
    default: return false
    }
  }

  private static func speech(_ asset: AVURLAsset, duration: Double, stop: () -> Bool) -> [[String: Any]] {
    guard !asset.tracks(withMediaType: .audio).isEmpty, authorized(),
          let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
          recognizer.supportsOnDeviceRecognition
    else { return [] }
    recognizer.queue = OperationQueue()

    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("sfs-audio-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var out: [[String: Any]] = []
    var start = 0.0
    while start < duration, !stop() {
      let length = min(speechChunk, duration - start)
      if exportAudio(asset, from: start, length: length, to: tmp) {
        out += recognize(tmp, offset: start, with: recognizer)
      }
      try? FileManager.default.removeItem(at: tmp)
      start += speechChunk
    }
    return out
  }

  private static func exportAudio(_ asset: AVURLAsset, from: Double, length: Double, to url: URL) -> Bool {
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return false }
    export.outputURL = url
    export.outputFileType = .m4a
    export.timeRange = CMTimeRange(
      start: CMTime(seconds: from, preferredTimescale: 600),
      duration: CMTime(seconds: length, preferredTimescale: 600))
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    if done.wait(timeout: .now() + 120) == .timedOut {
      export.cancelExport()
      return false
    }
    return export.status == .completed
  }

  /// Every recognised word with its own start time, so playback can start on the exact word.
  private static func recognize(_ url: URL, offset: Double, with recognizer: SFSpeechRecognizer) -> [[String: Any]] {
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    if #available(macOS 13.0, *) { request.addsPunctuation = true }

    let done = DispatchSemaphore(value: 0)
    var transcription: SFTranscription?
    let task = recognizer.recognitionTask(with: request) { result, error in
      if let result = result { transcription = result.bestTranscription }
      if error != nil || (result?.isFinal ?? false) { done.signal() }
    }
    if done.wait(timeout: .now() + 180) == .timedOut { task.cancel() }
    return (transcription?.segments ?? []).map { ["t": offset + $0.timestamp, "text": $0.substring] }
  }
}
