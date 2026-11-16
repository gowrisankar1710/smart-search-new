import Cocoa
import FlutterMacOS
import Vision

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func recognize(path: String) -> String {
    autoreleasepool {
      let url = URL(fileURLWithPath: path)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.minimumTextHeight = 0.008
      if #available(macOS 13.0, *) {
        request.automaticallyDetectsLanguage = true
      }
      let handler = VNImageRequestHandler(url: url, options: [:])
      do {
        try handler.perform([request])
      } catch {
        return ""
      }
      let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      return lines.joined(separator: "\n")
    }
  }
}
