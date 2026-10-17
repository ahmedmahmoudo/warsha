import Foundation

/// Runs Workbench's Node server for as long as the app is open: starts it, waits until it answers,
/// restarts it if it dies (backing off when it keeps dying), and stops it on quit. Replaces the
/// launchd service.
@MainActor
final class ServerProcess {
  enum State: Equatable {
    case starting
    case running
    case failed(String)
  }

  private(set) var state: State = .starting {
    didSet { if state != oldValue { onStateChange?(state) } }
  }
  var onStateChange: ((State) -> Void)?

  private var process: Process?
  private var stopping = false
  private var crashes = 0
  private var startedAt = Date()

  func start() {
    stopping = false
    state = .starting
    stopLeftoverServer()

    guard let node = Config.node() else {
      state = .failed("Couldn't find node. Install it, or rebuild the app from a shell where `node` works.")
      return
    }

    let process = Process()
    process.executableURL = node
    process.arguments = ["--import", "tsx", "server/index.ts"]
    process.currentDirectoryURL = Config.root
    var environment = ProcessInfo.processInfo.environment
    environment["NODE_ENV"] = "production"
    environment["WORKBENCH_LOCAL"] = "1"
    environment["PORT"] = String(Config.port)
    // Apps start with a bare PATH: give the server node's folder plus the usual places for git and open.
    environment["PATH"] = [node.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
      .joined(separator: ":")
    process.environment = environment
    if let log = openLog() {
      process.standardOutput = log
      process.standardError = log
    }
    process.terminationHandler = { [weak self] ended in
      let status = ended.terminationStatus
      Task { @MainActor in self?.exited(ended, status: status) }
    }

    do {
      try process.run()
    } catch {
      state = .failed("Couldn't start the server: \(error.localizedDescription)")
      return
    }
    self.process = process
    startedAt = Date()
    try? String(process.processIdentifier).write(to: Config.pidFile, atomically: true, encoding: .utf8)
    Task { await waitUntilReady(process) }
  }

  func restart() {
    crashes = 0
    stop()
    start()
  }

  /// Asks the server to exit, and kills it if it hasn't within a few seconds.
  func stop() {
    stopping = true
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { usleep(50_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    self.process = nil
    try? FileManager.default.removeItem(at: Config.pidFile)
  }

  private func waitUntilReady(_ process: Process) async {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline, process.isRunning, self.process === process {
      if let (_, response) = try? await URLSession.shared.data(from: Config.baseURL),
         (response as? HTTPURLResponse)?.statusCode == 200 {
        state = .running
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    if process.isRunning, self.process === process {
      state = .failed("The server started but isn't answering on port \(Config.port).")
    }
  }

  private func exited(_ ended: Process, status: Int32) {
    guard ended === process, !stopping else { return }
    process = nil
    // A server that ran a while and then died is a fresh problem, not a crash loop.
    if Date().timeIntervalSince(startedAt) > 60 { crashes = 0 }
    crashes += 1
    if crashes > 5 {
      state = .failed("The server keeps exiting (status \(status)). See the server log.")
      return
    }
    state = .starting
    let delay = min(30, 1 << (crashes - 1))
    Task {
      try? await Task.sleep(for: .seconds(delay))
      if self.process == nil, !self.stopping { self.start() }
    }
  }

  /// If the app crashed, its server is still holding the port: stop it, but only if it's still node.
  private func stopLeftoverServer() {
    guard let text = try? String(contentsOf: Config.pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return }
    try? FileManager.default.removeItem(at: Config.pidFile)
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0, String(decoding: buffer.prefix(Int(length)), as: UTF8.self) == "node" else { return }
    kill(pid, SIGTERM)
    usleep(500_000)
  }

  private func openLog() -> FileHandle? {
    let files = FileManager.default
    try? files.createDirectory(at: Config.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.createDirectory(at: Config.pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !files.fileExists(atPath: Config.logFile.path) { files.createFile(atPath: Config.logFile.path, contents: nil) }
    guard let log = try? FileHandle(forWritingTo: Config.logFile) else { return nil }
    log.seekToEndOfFile()
    return log
  }
}
