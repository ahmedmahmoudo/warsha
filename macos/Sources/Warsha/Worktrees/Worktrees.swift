import AppKit
import Foundation

/// One checkout of a repo: the main clone or one of its `git worktree`s.
struct Worktree: Identifiable, Equatable, Sendable {
  let path: String
  /// Nil when the HEAD is detached.
  let branch: String?
  let head: String
  let isMain: Bool
  let locked: Bool
  /// Git has lost the folder (deleted by hand); `git worktree prune` forgets it.
  let prunable: Bool
  /// Files with uncommitted changes, untracked ones included.
  var changedFiles = 0
  /// When its last commit was made.
  var lastCommitAt: Date?
  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A clone on this Mac and every worktree it has, the main checkout first.
struct LocalRepo: Identifiable, Equatable, Sendable {
  /// owner/name on GitHub.
  let repo: String
  let path: String
  var worktrees: [Worktree]
  var id: String { path }
}

/// Running git, with what it said when it fails.
enum Git {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  @discardableResult
  static func run(_ cwd: String, _ args: [String]) async throws -> String {
    try await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", cwd] + args
      let output = Pipe(), errors = Pipe()
      process.standardOutput = output
      process.standardError = errors
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let errorData = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let said = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure(message: said.isEmpty ? "git \(args.joined(separator: " ")) failed" : said)
      }
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }.value
  }

  /// owner/name from a GitHub remote URL (https or ssh).
  static func githubRepo(_ url: String) -> String? {
    let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
    return trimmed.firstMatch(of: /github\.com[:\/]([^\/]+\/[^\/]+)$/).map { String($0.1) }
  }

  /// `git worktree list --porcelain`, read into worktrees; the first is the main checkout.
  static func parseWorktrees(_ porcelain: String) -> [Worktree] {
    porcelain.components(separatedBy: "\n\n").enumerated().compactMap { index, block in
      let lines = block.split(separator: "\n").map(String.init)
      guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst(9) else { return nil }
      let branch = lines.first { $0.hasPrefix("branch ") }.map { String($0.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
      let head = lines.first { $0.hasPrefix("HEAD ") }.map { String($0.dropFirst(5).prefix(7)) } ?? ""
      return Worktree(
        path: String(path), branch: branch, head: head, isMain: index == 0,
        locked: lines.contains { $0 == "locked" || $0.hasPrefix("locked ") },
        prunable: lines.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }
      )
    }
  }
}

/// Your clones of the repos you follow and their worktrees, and cleaning them up. Clones are the ones
/// in Settings → General → Local repos, and any in the usual code folders in your home (~/dev,
/// ~/Developer, ~/code…), at their top level or one in. Other folders are left alone: reading
/// Documents or Desktop would ask for permission, and can hang while it does.
@MainActor
@Observable
final class WorktreesModel {
  nonisolated private static let codeFolders = ["dev", "Developer", "code", "src", "projects", "repos", "work", "git", "github", "workspace"]
  /// Rescanning is a few hundred git calls at most, so it's kept for a while.
  private static let maxAge: TimeInterval = 120

  private(set) var repos: [LocalRepo] = []
  private(set) var scannedAt: Date?
  private(set) var scanning = false
  private(set) var error: String?
  /// Paths being removed right now.
  private(set) var removing: Set<String> = []

  /// The worktree (not the main checkout) with the PR's branch checked out.
  func worktree(repo: String, branch: String) -> Worktree? {
    repos.first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }?
      .worktrees.first { !$0.isMain && $0.branch == branch }
  }

  /// The repos chosen in Settings → Accounts when the last scan ran; empty when all are followed.
  private(set) var chosenRepos: [String] = []
  /// Chosen repos with no clone found on this Mac.
  private(set) var notCloned: [String] = []

  /// Only the clones of the repos you follow (Settings → Accounts → Repos), or every clone found
  /// when you follow all of them. A change of repos rescans whatever the last scan's age.
  func scan(settings: AppSettings, force: Bool = false) async {
    let chosen = AppSettings.list(settings.githubRepos)
    let sameRepos = chosen.map { $0.lowercased() } == chosenRepos.map { $0.lowercased() }
    if !force, sameRepos, let scannedAt, -scannedAt.timeIntervalSinceNow < Self.maxAge { return }
    guard !scanning else { return }
    scanning = true
    defer { scanning = false }
    let wanted = Set(chosen.map { $0.lowercased() })
    let listed = settings.localRepos
    let clones = await Task.detached { Self.clones(listed: listed) }.value
    var found: [LocalRepo] = []
    for clone in clones {
      guard let origin = try? await Git.run(clone, ["remote", "get-url", "origin"]), let repo = Git.githubRepo(origin),
            wanted.isEmpty || wanted.contains(repo.lowercased()),
            !found.contains(where: { $0.path == clone }),
            let porcelain = try? await Git.run(clone, ["worktree", "list", "--porcelain"])
      else { continue }
      var worktrees = Git.parseWorktrees(porcelain)
      await withTaskGroup(of: (Int, Int, Date?).self) { group in
        for (index, worktree) in worktrees.enumerated() where !worktree.prunable {
          group.addTask {
            let status = (try? await Git.run(worktree.path, ["status", "--porcelain"])) ?? ""
            let date = (try? await Git.run(worktree.path, ["log", "-1", "--format=%cI"])).flatMap { try? Date($0, strategy: .iso8601) }
            return (index, status.isEmpty ? 0 : status.split(separator: "\n").count, date)
          }
        }
        for await (index, changed, date) in group {
          worktrees[index].changedFiles = changed
          worktrees[index].lastCommitAt = date
        }
      }
      found.append(LocalRepo(repo: repo, path: clone, worktrees: worktrees))
    }
    repos = found.sorted { ($0.worktrees.count > 1 ? 0 : 1, $0.repo.lowercased()) < ($1.worktrees.count > 1 ? 0 : 1, $1.repo.lowercased()) }
    chosenRepos = chosen
    notCloned = chosen.filter { name in !found.contains { $0.repo.caseInsensitiveCompare(name) == .orderedSame } }
    scannedAt = Date()
    error = nil
  }

  /// Removes a worktree's folder with git; the branch stays unless `deleteBranch`. `force` drops
  /// uncommitted changes.
  func remove(_ worktree: Worktree, in repo: LocalRepo, force: Bool, deleteBranch: Bool, settings: AppSettings) async {
    removing.insert(worktree.path)
    defer { removing.remove(worktree.path) }
    do {
      try await Git.run(repo.path, ["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path])
      if deleteBranch, let branch = worktree.branch { try await Git.run(repo.path, ["branch", "-D", branch]) }
      error = nil
    } catch {
      self.error = "\(worktree.name): \(error.localizedDescription)"
    }
    await scan(settings: settings, force: true)
  }

  /// Forgets worktrees whose folders are gone.
  func prune(_ repo: LocalRepo, settings: AppSettings) async {
    do {
      try await Git.run(repo.path, ["worktree", "prune"])
      error = nil
    } catch {
      self.error = "\(repo.repo): \(error.localizedDescription)"
    }
    await scan(settings: settings, force: true)
  }

  /// Main clones to look at: listed ones, then the code folders' clones (one level in, or two).
  nonisolated private static func clones(listed: String) -> [String] {
    var paths = AppSettings.list(listed).compactMap { pair -> String? in
      let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      return parts.count == 2 ? (parts[1] as NSString).expandingTildeInPath : nil
    }
    let manager = FileManager.default
    let home = manager.homeDirectoryForCurrentUser
    func folders(_ url: URL) -> [URL] {
      ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    func isClone(_ url: URL) -> Bool {
      var directory: ObjCBool = false
      return manager.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &directory) && directory.boolValue
    }
    for name in codeFolders {
      let root = home.appendingPathComponent(name)
      guard manager.fileExists(atPath: root.path) else { continue }
      for top in folders(root) {
        if isClone(top) { paths.append(top.path); continue }
        for inner in folders(top) where isClone(inner) { paths.append(inner.path) }
      }
    }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}

extension Worktree {
  func reveal() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

  func openInTerminal() {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}
