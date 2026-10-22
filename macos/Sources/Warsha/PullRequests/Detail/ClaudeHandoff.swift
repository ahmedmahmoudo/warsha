import AppKit
import Foundation

/// Hands a conflicted PR to Claude Code on this Mac: finds the checkout that has the PR's branch
/// (your per-ticket worktrees), writes the prompt, and opens a new session in the Claude desktop
/// app there. server/local/claude.ts in Swift.
enum ClaudeHandoff {
  struct ConflictPr: Sendable {
    let repo: String
    let number: Int
    let title: String
    let url: String
    let head: String
    let base: String
  }

  /// Folders in your home that never hold clones, skipped when looking for one.
  private static let notProjectFolders: Set = ["Library", "Applications", "Movies", "Music", "Pictures", "Public", "Downloads"]

  /// Where a repo named `name` might be cloned: ~/name, then ~/<any folder>/name.
  private static func candidates(_ name: String) -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let folders = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    let inside = folders
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !notProjectFolders.contains($0.lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { $0.appendingPathComponent(name).path }
    return [home.appendingPathComponent(name).path] + inside
  }

  static func git(_ cwd: String, _ args: String...) async throws -> String {
    try await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", cwd] + args
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw IntegrationError("git \(args.joined(separator: " ")) failed in \(cwd)") }
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }.value
  }

  private static func originMatches(_ url: String, repo: String) -> Bool {
    let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
    guard let match = trimmed.firstMatch(of: /github\.com[:\/](.+\/.+)$/) else { return false }
    return match.1.lowercased() == repo.lowercased()
  }

  /// The main clone of a repo: Settings → General → Local repos when it names one, otherwise a
  /// folder named after the repo in your home or one level in, if its origin is that repo.
  static func localClone(_ repo: String, localRepos: [String: String]) async -> String? {
    let name = String(repo.split(separator: "/").last ?? "")
    let paths = localRepos[repo.lowercased()].map { [$0] } ?? candidates(name)
    for candidate in paths where FileManager.default.fileExists(atPath: candidate) {
      if let origin = try? await git(candidate, "remote", "get-url", "origin"), originMatches(origin, repo: repo) { return candidate }
    }
    return nil
  }

  /// The worktree that has `branch` checked out, if any.
  private static func worktree(clone: String, branch: String) async -> String? {
    guard let porcelain = try? await git(clone, "worktree", "list", "--porcelain") else { return nil }
    for block in porcelain.components(separatedBy: "\n\n") {
      guard let path = block.firstMatch(of: /(?m)^worktree (.+)$/)?.1 else { continue }
      if block.contains("\nbranch refs/heads/\(branch)") { return String(path) }
    }
    return nil
  }

  /// Where a new worktree for the branch goes: beside the clone, named like the others ("ev-admin-mx-2481").
  private static func newWorktreePath(clone: String, pr: ConflictPr) -> String {
    let ticket = pr.head.firstMatch(of: /(?i)(?:^|[\/_-])([a-z]{2,6}-\d{1,6})(?=$|[\/_-])/).map { String($0.1).lowercased() }
    let url = URL(fileURLWithPath: clone)
    return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(ticket ?? "pr-\(pr.number)")").path
  }

  private static func prompt(_ pr: ConflictPr, checkout: (path: String, kind: PrActions.Conflicts.Kind)?, worktreePath: String?) -> String {
    let first =
      checkout?.kind == .worktree
        ? "You're in the worktree for `\(pr.head)`. If it has uncommitted changes, stop and tell me rather than stashing or discarding them."
        : worktreePath.map {
          "This is my main checkout; leave it alone. Make a worktree for the PR branch and do everything there: `git fetch origin \(pr.head)`, then `git worktree add \($0) \(pr.head)` (if that folder already exists, use it)."
        } ?? "Check out the PR branch with `gh pr checkout \(pr.number)`, in a worktree if my current checkout has work in progress."
    return [
      "PR \(pr.repo)#\(pr.number) \"\(pr.title)\" (\(pr.url)) has merge conflicts with its base branch `\(pr.base)`. Resolve them and update the PR.",
      "",
      "1. \(first)",
      "2. Run `git fetch origin`, then merge `origin/\(pr.base)` into `\(pr.head)`. Merge, don't rebase: the branch is pushed and under review.",
      "3. Resolve each conflict keeping the intent of both sides. Read the PR description (`gh pr view \(pr.number)`) and the \(pr.base) commits that touched the same code before choosing. If a conflict needs a product decision, stop and ask me.",
      "4. Run the typecheck and the tests for the packages you touched, and fix anything the merge broke.",
      "5. Commit the merge with the default merge message and push to `origin \(pr.head)`.",
      "6. Tell me which files conflicted and how you resolved each one.",
    ].joined(separator: "\n")
  }

  private static func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func conflictAction(_ pr: ConflictPr, localRepos: [String: String]) async -> PrActions.Conflicts {
    let clone = await localClone(pr.repo, localRepos: localRepos)
    let worktree = if let clone { await worktree(clone: clone, branch: pr.head) } else { String?.none }
    let checkout = clone.map { (path: worktree ?? $0, kind: worktree != nil ? PrActions.Conflicts.Kind.worktree : .newWorktree) }
    let text = prompt(pr, checkout: checkout, worktreePath: clone != nil && worktree == nil ? newWorktreePath(clone: clone!, pr: pr) : nil)
    return PrActions.Conflicts(
      prompt: text, checkout: checkout, command: checkout.map { "cd \(shellQuote($0.path)) && claude \(shellQuote(text))" }
    )
  }

  /// Claude desktop's documented link for a new Code session: folder plus a prefilled prompt.
  private static let promptLimit = 14_000

  /// Opens a new Claude Code session in the Claude desktop app, in the PR's checkout, with the prompt
  /// filled in. The app asks you to confirm the folder and you press send, so nothing runs unseen.
  /// https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link
  @MainActor
  static func open(_ conflicts: PrActions.Conflicts) throws {
    guard let checkout = conflicts.checkout else { throw IntegrationError("No local checkout of this repo to open Claude in") }
    guard conflicts.prompt.count <= promptLimit else { throw IntegrationError("The prompt is too long for a Claude desktop link; copy it instead") }
    // Spaces must be %20, as in the documented example, not "+".
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.~")
    let folder = checkout.path.addingPercentEncoding(withAllowedCharacters: allowed)!
    let prompt = conflicts.prompt.addingPercentEncoding(withAllowedCharacters: allowed)!
    guard let link = URL(string: "claude://code/new?folder=\(folder)&q=\(prompt)"),
          NSWorkspace.shared.urlForApplication(toOpen: link) != nil
    else { throw IntegrationError("Couldn't open the Claude app. Is it installed?") }
    NSWorkspace.shared.open(link)
  }
}
