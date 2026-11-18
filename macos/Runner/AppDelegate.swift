import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  static func main() {
    ResponsibleProcess.becomeResponsibleForSelf()
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// macOS privacy checks (speech recognition, folders) ask "which app is responsible?".
/// Opened from Finder / the Dock it's this app. Started from a terminal or an editor
/// (`flutter run` from VS Code) it's that launcher: the system prompt would name it, and
/// it looks for the speech usage description in *its* Info.plist – which has none, so
/// the app is killed. Re-executing in place (same pid, so `flutter run` stays attached)
/// with responsibility disclaimed makes this app answer for itself, as Qt Creator and
/// Chromium do for the processes they launch.
enum ResponsibleProcess {
  private static let flag = "SMART_SEARCH_SELF_RESPONSIBLE"

  /// True when this app, not its launcher, is the one macOS asks about.
  static var isSelf: Bool { getppid() == 1 || getenv(flag) != nil }

  static func becomeResponsibleForSelf() {
    guard !isSelf, let path = Bundle.main.executablePath else { return }
    // Private but long-standing; if it is ever gone, speech is simply skipped (see isSelf).
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    let disclaim = unsafeBitCast(sym, to: Disclaim.self)

    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    defer { posix_spawnattr_destroy(&attr) }
    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0, disclaim(&attr, 1) == 0 else { return }
    setenv(flag, "1", 1)
    _ = posix_spawn(nil, path, nil, &attr, CommandLine.unsafeArgv, environ) // returns only on failure
    unsetenv(flag)
  }
}
