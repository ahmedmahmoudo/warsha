import Foundation

/// Where things are. `build.sh` writes the checkout and node paths into Info.plist.
enum Config {
  /// The app's own server port, apart from dev (5179 / 8787) and the launchd service (5180) so all
  /// three can run at once. Mirrors APP_PORT in shared/ports.ts.
  static let port = 5181

  static let baseURL = URL(string: "http://127.0.0.1:\(port)/")!

  /// The Workbench checkout the server runs from (its server/, dist/, node_modules and .env.local).
  static var root: URL {
    URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "WorkbenchRoot") as? String ?? FileManager.default.currentDirectoryPath)
  }

  /// The node binary: the one found at build time, or, when that's gone (nvm switched versions),
  /// whatever your login shell finds now.
  static func node() -> URL? {
    if let built = Bundle.main.object(forInfoDictionaryKey: "WorkbenchNode") as? String,
       FileManager.default.isExecutableFile(atPath: built) {
      return URL(fileURLWithPath: built)
    }
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-lc", "command -v node"]
    let output = Pipe()
    shell.standardOutput = output
    shell.standardError = FileHandle.nullDevice
    guard (try? shell.run()) != nil else { return nil }
    shell.waitUntilExit()
    let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
  }

  static let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Workbench/server.log")

  /// The running server's pid, so a server left behind by a crash is stopped on the next launch.
  static let pidFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Workbench/server.pid")
}
