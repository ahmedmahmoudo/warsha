import SwiftUI

/// The Worktrees page: every clone on this Mac with worktrees, each worktree with its branch, its
/// PR, uncommitted changes and last commit, and cleaning them up one at a time or all the merged
/// ones at once.
struct WorktreesView: View {
  @Environment(AppSettings.self) private var settings
  @Environment(WorktreesModel.self) private var model
  @Environment(PullRequestsModel.self) private var prs
  @State private var pending: Removal?
  @State private var cleaningMerged = false

  struct Removal: Identifiable {
    let worktree: Worktree
    let repo: LocalRepo
    var id: String { worktree.path }
  }

  var body: some View {
    let withWorktrees = model.repos.filter { $0.worktrees.count > 1 }
    let merged = mergedRemovals
    PageScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header(merged)
        if let error = model.error {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.bad.color).textSelection(.enabled)
        }
        if model.scannedAt == nil {
          SkeletonPanel(title: "Looking for your clones", rows: 4)
        } else if withWorktrees.isEmpty {
          ContentUnavailableView(
            "No Worktrees", systemImage: "arrow.triangle.branch",
            description: Text(model.chosenRepos.isEmpty
              ? "None of the clones found here has extra worktrees. Clones are looked for in your code folders (~/dev, ~/Developer, ~/code, ~/src, ~/projects and the like) and under Settings → General → Local repos."
              : "Your repos' clones have no extra worktrees. Clones are looked for in your code folders (~/dev, ~/Developer, ~/code, ~/src, ~/projects and the like) and under Settings → General → Local repos.")
          )
        }
        ForEach(withWorktrees) { repo in RepoPanel(repo: repo, pr: pr, remove: { pending = Removal(worktree: $0, repo: repo) }) }
        let plain = model.repos.filter { $0.worktrees.count <= 1 }
        if model.scannedAt != nil && !model.notCloned.isEmpty {
          Text("Not cloned on this Mac: \(model.notCloned.joined(separator: ", ")). Add a clone's folder under Settings → General → Local repos if it's somewhere else.")
            .scaledFont(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        if !plain.isEmpty {
          Text("Also cloned, with no worktrees: \(plain.map(\.repo).joined(separator: ", "))")
            .scaledFont(.caption).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 24).padding(.vertical, 20)
      .frame(maxWidth: 1120, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .workbenchPage()
    .navigationTitle("Worktrees")
    .navigationSubtitle(model.scanning ? "Scanning…" : model.scannedAt.map { "Scanned at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    .toolbar {
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.scan(settings: settings, force: true) } }
          .clickable()
          .keyboardShortcut("r")
          .disabled(model.scanning)
      }
    }
    .task(id: settings.githubRepos) { await model.scan(settings: settings) }
    .confirmationDialog(
      pending.map { "Remove the worktree \($0.worktree.name)?" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { removal in
      let dirty = removal.worktree.changedFiles > 0
      Button(dirty ? "Remove and Discard Changes" : "Remove Worktree", role: dirty ? .destructive : nil) {
        Task { await model.remove(removal.worktree, in: removal.repo, force: dirty, deleteBranch: false, settings: settings) }
      }
      if let branch = removal.worktree.branch {
        Button("Remove and Delete Branch \(branch)", role: .destructive) {
          Task { await model.remove(removal.worktree, in: removal.repo, force: dirty, deleteBranch: true, settings: settings) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { removal in
      Text(
        removal.worktree.changedFiles > 0
          ? "Its folder is deleted, with \(removal.worktree.changedFiles) uncommitted change\(removal.worktree.changedFiles == 1 ? "" : "s") that can't be got back. Commits on the branch are kept unless you delete the branch too."
          : "Its folder is deleted. Commits on the branch are kept unless you delete the branch too."
      )
    }
    .confirmationDialog("Clean up \(merged.count) merged worktree\(merged.count == 1 ? "" : "s")?", isPresented: $cleaningMerged) {
      Button("Remove Worktrees and Branches", role: .destructive) {
        Task {
          for removal in merged {
            await model.remove(removal.worktree, in: removal.repo, force: false, deleteBranch: true, settings: settings)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("These have no uncommitted changes and their PRs have merged:\n\(merged.map { "\($0.worktree.name) (\($0.worktree.branch ?? ""))" }.joined(separator: "\n"))\n\nTheir folders and local branches are deleted.")
    }
  }

  private func header(_ merged: [Removal]) -> some View {
    let all = model.repos.flatMap { $0.worktrees.filter { !$0.isMain } }
    let withWorktrees = model.repos.filter { $0.worktrees.count > 1 }.count
    return HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Worktrees").scaledFont(.title2.weight(.semibold))
        Text("\(all.count) worktree\(all.count == 1 ? "" : "s") in \(withWorktrees) repo\(withWorktrees == 1 ? "" : "s") · \(all.filter { $0.changedFiles > 0 }.count) with uncommitted changes")
          .foregroundStyle(.secondary)
        Text(model.chosenRepos.isEmpty
          ? "Every clone found, as you follow all repos. Choose repos in Settings → Accounts to see just theirs."
          : "For your \(model.chosenRepos.count) chosen repo\(model.chosenRepos.count == 1 ? "" : "s"): \(model.chosenRepos.joined(separator: ", "))")
          .scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(2)
      }
      Spacer()
      if !merged.isEmpty {
        Button("Clean Up \(merged.count) Merged", systemImage: "sparkles") { cleaningMerged = true }
          .clickable()
          .help("Remove worktrees whose PR has merged and that have no uncommitted changes, with their local branches")
      }
    }
  }

  /// The PR for a branch, from whatever Pull Requests has loaded.
  private func pr(_ repo: String, _ branch: String?) -> Pr? {
    guard let branch else { return nil }
    return prs.responses.values.lazy.flatMap { $0.open + $0.recentlyMerged }
      .first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame && $0.headRef == branch }
  }

  /// Clean worktrees whose PR has merged: safe to remove along with their branch.
  private var mergedRemovals: [Removal] {
    model.repos.flatMap { repo in
      repo.worktrees.filter { worktree in
        !worktree.isMain && !worktree.locked && !worktree.prunable && worktree.changedFiles == 0
          && pr(repo.repo, worktree.branch)?.mergedAt != nil
      }
      .map { Removal(worktree: $0, repo: repo) }
    }
  }
}

private struct RepoPanel: View {
  let repo: LocalRepo
  let pr: (String, String?) -> Pr?
  let remove: (Worktree) -> Void
  @Environment(WorktreesModel.self) private var model
  @Environment(AppSettings.self) private var settings

  var body: some View {
    let prunable = repo.worktrees.filter(\.prunable).count
    Panel(repo.repo) {
      HStack(spacing: 8) {
        Text(abbreviated(repo.path)).foregroundStyle(.tertiary)
        if prunable > 0 {
          SmallLink(title: "Forget \(prunable) missing") { Task { await model.prune(repo, settings: settings) } }
        }
      }
    } content: {
      ForEach(Array(repo.worktrees.enumerated()), id: \.element.id) { index, worktree in
        if index > 0 { Divider().overlay(Palette.border) }
        WorktreeRow(worktree: worktree, pr: pr(repo.repo, worktree.branch), removing: model.removing.contains(worktree.path)) { remove(worktree) }
      }
    }
  }
}

private struct WorktreeRow: View {
  let worktree: Worktree
  let pr: Pr?
  let removing: Bool
  let remove: () -> Void
  @Environment(Navigation.self) private var navigation

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch").foregroundStyle(.secondary)
          Text(worktree.branch ?? "detached at \(worktree.head)").scaledFont(.callout.monospaced().weight(.medium)).lineLimit(1)
          if worktree.isMain { Chip(text: "main checkout", tone: .neutral) }
          if worktree.changedFiles > 0 { Chip(text: "\(worktree.changedFiles) uncommitted", tone: .warn) }
          if worktree.locked { Chip(text: "locked", tone: .neutral) }
          if worktree.prunable { Chip(text: "folder missing", tone: .bad) }
        }
        HStack(spacing: 10) {
          Text(abbreviated(worktree.path)).lineLimit(1).truncationMode(.middle).help(worktree.path)
          if let date = worktree.lastCommitAt { Text("last commit \(date, format: .relative(presentation: .named))") }
        }
        .scaledFont(.caption).foregroundStyle(.secondary)
        if let pr {
          Button { navigation.open(PrKey(pr)) } label: {
            HStack(spacing: 6) {
              Chip(text: pr.status.label, tone: pr.status.tone)
              Text("#\(String(pr.number)) \(pr.title)").lineLimit(1)
            }
          }
          .buttonStyle(.plain).clickable(underline: true)
          .scaledFont(.caption)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !worktree.prunable { WorktreeActions(worktree: worktree) }
      if !worktree.isMain {
        if removing {
          ProgressView().scaledControlSize(.small)
        } else {
          Button("Remove", systemImage: "trash", action: remove)
            .labelStyle(.iconOnly).buttonStyle(.borderless).clickable()
            .disabled(worktree.locked)
            .help(worktree.locked ? "Locked: unlock it with git first" : "Remove this worktree…")
        }
      }
    }
    .padding(.vertical, 6)
  }
}

/// Reveal in Finder, open in Terminal, copy the path: for a worktree here or beside its PR.
struct WorktreeActions: View {
  let worktree: Worktree

  var body: some View {
    HStack(spacing: 2) {
      Button("Reveal in Finder", systemImage: "folder") { worktree.reveal() }
        .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().help("Reveal in Finder")
      Button("Open in Terminal", systemImage: "terminal") { worktree.openInTerminal() }
        .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().help("Open in Terminal")
      Button("Copy Path", systemImage: "doc.on.doc") { copyToPasteboard(worktree.path) }
        .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().help("Copy the path")
    }
  }
}

/// A PR's local worktree, as a chip with its actions in a menu; nothing when there's none.
struct WorktreeChip: View {
  let pr: Pr
  @Environment(WorktreesModel.self) private var model
  @Environment(Navigation.self) private var navigation

  var body: some View {
    if let worktree = model.worktree(repo: pr.repo, branch: pr.headRef) {
      Menu {
        Button("Reveal in Finder") { worktree.reveal() }
        Button("Open in Terminal") { worktree.openInTerminal() }
        Button("Copy Path") { copyToPasteboard(worktree.path) }
        Divider()
        Button("Show in Worktrees") { navigation.show(.worktrees) }
      } label: {
        Label(worktree.changedFiles > 0 ? "Worktree · \(worktree.changedFiles) uncommitted" : "Worktree", systemImage: "arrow.triangle.branch")
          .scaledFont(.caption)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .foregroundStyle(worktree.changedFiles > 0 ? Tone.warn.color : .secondary)
      .chipBorder()
      .clickable()
      .help(worktree.path)
    }
  }
}

/// A path with your home folder as ~.
func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
