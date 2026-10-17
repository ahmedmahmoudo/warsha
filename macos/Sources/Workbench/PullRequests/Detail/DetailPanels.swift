import AppKit
import SwiftUI

// The details page's panels: Actions, Merge status, Checks, Activity and Screenshots.

// MARK: Actions

/// Shown only when there's something to do about the branch. src/components/PrActionsPanel.tsx.
struct ActionsPanel: View {
  let detail: PrDetail
  let model: PrDetailModel

  var body: some View {
    if detail.actions.conflicts != nil || detail.actions.updateBranch != nil {
      Panel("Actions") {
        if let conflicts = detail.actions.conflicts {
          ConflictAction(pr: detail.pr, conflicts: conflicts)
        }
        if detail.actions.conflicts != nil && detail.actions.updateBranch != nil { Divider() }
        if let update = detail.actions.updateBranch {
          UpdateBranchAction(pr: detail.pr, update: update, model: model)
        }
      }
    }
  }
}

/// What happened when an action ran, shown under its buttons.
private struct Outcome: Equatable {
  let good: Bool
  let text: String
}

private struct OutcomeLine: View {
  let outcome: Outcome?

  var body: some View {
    if let outcome {
      Text(outcome.text).scaledFont(.caption).foregroundStyle(outcome.good ? Tone.good.color : Tone.bad.color)
    }
  }
}

private struct ConflictAction: View {
  let pr: Pr
  let conflicts: PrActions.Conflicts
  @Environment(\.textScale) private var textScale
  @State private var outcome: Outcome?
  @State private var showPrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Merge conflicts with \(pr.baseRef)", systemImage: "exclamationmark.triangle.fill")
        .scaledFont(.callout.weight(.medium))
        .symbolRenderingMode(.multicolor)
        .foregroundStyle(Tone.bad.color)
      Text(
        "Opens a new Claude Code session in the Claude app with the prompt ready: it merges \(pr.baseRef) into the branch, resolves the conflicts, runs the checks and pushes. You confirm the folder and press send."
      )
      .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let checkout = conflicts.checkout {
        Text(
          "Runs in \(Text(checkout.path).font(Typeface.caption.monospaced().font(textScale)).foregroundStyle(.primary))\(checkout.kind == .worktree ? ", the branch's worktree." : "; the branch has no worktree yet, so Claude makes one beside it and leaves this checkout alone.")"
        )
        .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("No local clone of \(pr.repo) found. Add it under Settings → General → Local repos to run it from here, or copy the prompt.")
          .scaledFont(.caption).foregroundStyle(Tone.warn.color).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if conflicts.checkout != nil {
          Button("Open in Claude", systemImage: "sparkles") {
            do {
              try ClaudeHandoff.open(conflicts)
              outcome = Outcome(good: true, text: "Opened a Claude Code session. Confirm the folder, then press send.")
            } catch {
              outcome = Outcome(good: false, text: error.localizedDescription)
            }
          }
          .buttonStyle(.pill(.neutral, prominent: true))
          .clickable()
        }
        CopyButton(text: conflicts.prompt, label: "Copy Prompt")
        if let command = conflicts.command { CopyButton(text: command, label: "Copy Command") }
      }
      .scaledControlSize(.small)
      OutcomeLine(outcome: outcome)
      DisclosureGroup("Prompt", isExpanded: $showPrompt) {
        Text(conflicts.prompt)
          .scaledFont(.caption.monospaced())
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Palette.fill, in: .rect(cornerRadius: 6))
      }
      .scaledFont(.caption)
    }
  }
}

private struct UpdateBranchAction: View {
  let pr: Pr
  let update: PrActions.UpdateBranch
  let model: PrDetailModel
  @Environment(AppSettings.self) private var settings
  @Environment(\.textScale) private var textScale
  @Environment(PullRequestsModel.self) private var list
  @State private var confirming = false
  @State private var running = false
  @State private var outcome: Outcome?
  /// The head this updated from; once the page shows a newer head, the update has landed.
  @State private var updatedFrom: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("\(update.behindBy) commit\(update.behindBy == 1 ? "" : "s") behind \(update.base)", systemImage: "arrow.triangle.merge")
        .scaledFont(.callout.weight(.medium))
        .foregroundStyle(Tone.warn.color)
      Text("Updating merges \(update.base) into \(Text(pr.headRef).font(Typeface.caption.monospaced().font(textScale))) on GitHub")
        .scaledFont(.caption).foregroundStyle(.secondary)
      if let reason = update.reason {
        Text(reason).scaledFont(.caption).foregroundStyle(Tone.warn.color).fixedSize(horizontal: false, vertical: true)
      }
      if updatedFrom != update.headOid {
        Button("Update with \(update.base)", systemImage: "arrow.clockwise") { confirming = true }
          .buttonStyle(.pill)
          .disabled(!update.canUpdate || running)
          .clickable()
          .confirmationDialog("Update \(pr.headRef) with \(update.base)?", isPresented: $confirming) {
            Button("Update Branch") { Task { await run() } }
          } message: {
            Text("This pushes a merge commit to the PR branch. CI runs again, and branches that dismiss stale reviews lose their approvals.")
          }
      }
      if running { ProgressView().scaledControlSize(.small) }
      OutcomeLine(outcome: outcome)
    }
  }

  private func run() async {
    running = true
    defer { running = false }
    do {
      let settled = try await PrService.shared.updateBranch(PrKey(pr), expectedHeadOid: update.headOid, config: PrConfig(settings))
      updatedFrom = update.headOid
      outcome = Outcome(
        good: true,
        text: settled
          ? "Merged \(update.base) into the branch on GitHub. CI will run again."
          : "GitHub accepted the update and is still applying it; this page catches up on its next refresh."
      )
      await model.load(settings: settings)
      // The PR list shows this PR's status too.
      for scope in PrScope.allCases where list.responses[scope] != nil {
        await list.load(scope, settings: settings)
      }
    } catch {
      outcome = Outcome(good: false, text: error.localizedDescription)
    }
  }
}

private struct CopyButton: View {
  let text: String
  let label: String
  @State private var copied = false

  var body: some View {
    Button(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
    }
    .buttonStyle(.pill)
    .clickable()
  }
}

// MARK: Merge status

struct MergePanel: View {
  let detail: PrDetail

  var body: some View {
    let merge = detail.merge
    Panel("Merge status") {
      headline.scaledFont(.callout.weight(.medium))
      if !merge.blockers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(merge.blockers, id: \.kind) { blocker in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: symbol(blocker.kind))
                .foregroundStyle(blocker.kind == .ciPending || blocker.kind == .draft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.bad.color))
              VStack(alignment: .leading, spacing: 2) {
                Text(blocker.label).scaledFont(.callout)
                ForEach(blocker.items, id: \.self) { Text($0).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
              }
            }
          }
        }
      }
      if !merge.notes.isEmpty {
        Divider()
        ForEach(merge.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle").scaledFont(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var headline: some View {
    let merge = detail.merge
    switch detail.state {
    case .merged:
      Text("Merged \(relative(detail.pr.mergedAt))").foregroundStyle(Tone.good.color)
    case .closed:
      Text("Closed without merging \(relative(detail.closedAt))").foregroundStyle(Tone.bad.color)
    default:
      if let queue = merge.queue {
        Text("In the merge queue\(queue.position.map { ", position \($0)" } ?? "") · added \(relative(queue.enqueuedAt))")
          .foregroundStyle(Tone.warn.color)
      } else if merge.ready {
        Text("Ready to merge").foregroundStyle(Tone.good.color)
      } else {
        Text("Not ready to merge: \(merge.blockers.count) thing\(merge.blockers.count == 1 ? "" : "s") in the way")
      }
    }
  }

  private func symbol(_ kind: MergeBlocker.Kind) -> String {
    switch kind {
    case .draft: "circle.dashed"
    case .conflicts, .ciFailing, .changesRequested: "xmark.circle"
    case .behind: "minus.circle"
    case .ciPending: "circle.dotted"
    case .codeOwners, .approvals: "person.badge.plus"
    case .threads: "bubble.left"
    }
  }
}

private func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

func relative(_ iso: String?) -> String {
  guard let date = iso.flatMap(parseDate) else { return "" }
  return date.formatted(.relative(presentation: .named))
}

// MARK: Checks

struct ChecksPanel: View {
  let model: PrDetailModel
  @Environment(AppSettings.self) private var settings
  @State private var includeAll = false
  @State private var expanded = false
  private let maxShown = 6

  var body: some View {
    let (checks, fetchedAt) = model.checks
    let required = checks.filter(\.required).sorted(by: Self.byState)
    let advisory = checks.filter { !$0.required }.sorted(by: Self.byState)
    // Passed and skipped advisory checks are noise until asked for.
    let advisoryShown = includeAll ? advisory : advisory.filter { $0.state == .failed || $0.state == .pending }
    let hidden = advisory.count - advisoryShown.count
    let mainList = required.count < checks.count ? advisoryShown : required
    let visible = expanded ? mainList : Array(mainList.prefix(maxShown))
    let running = checks.contains { $0.state == .pending }

    Panel("Checks") {
      HStack(spacing: 8) {
        if let verdict = Self.verdict(checks) { Chip(text: verdict.label, tone: verdict.tone).help(verdict.detail) }
        count(checks, .passed, "passed", .good)
        count(checks, .failed, "failed", .bad)
        count(checks, .pending, "running", .warn)
        if !model.isFinished {
          Button("Check Now", systemImage: "arrow.clockwise") { Task { await model.pollChecks(settings: settings) } }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.checkingNow).clickable().help("Check now")
        }
      }
    } content: {
      if !model.isFinished {
        HStack(spacing: 0) {
          Text("Checked \(fetchedAt, format: .relative(presentation: .named)) · \(running ? "every 10s while checks run" : "every minute")")
          if let error = model.checksError { Text(" · last check failed: \(error.localizedDescription)").foregroundStyle(Tone.bad.color) }
        }
        .scaledFont(.caption).foregroundStyle(.tertiary)
      }
      if checks.isEmpty { Text("No checks on the latest commit.").foregroundStyle(.tertiary) }
      if !required.isEmpty && required.count < checks.count {
        Text("Required to merge").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
        ForEach(required, id: \.name) { CheckRow(check: $0) }
        Text("Advisory").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
      }
      ForEach(visible, id: \.name) { CheckRow(check: $0) }
      HStack(spacing: 12) {
        if mainList.count > maxShown {
          Button(expanded ? "Show Less" : "Show \(mainList.count - visible.count) More") { expanded.toggle() }
        }
        if hidden > 0 { Button("Include \(hidden) Passed or Skipped") { includeAll = true } }
        if includeAll && !advisory.isEmpty { Button("Hide Passed and Skipped") { includeAll = false } }
      }
      .buttonStyle(.link).scaledFont(.caption).clickable(underline: true)
    }
  }

  @ViewBuilder
  private func count(_ checks: [CheckItem], _ state: CheckState, _ label: String, _ tone: Tone) -> some View {
    let count = checks.filter { $0.state == state }.count
    if count > 0 || state == .passed { Text("\(count) \(label)").foregroundStyle(tone.color) }
  }

  private static func byState(_ a: CheckItem, _ b: CheckItem) -> Bool {
    let order: [CheckState] = [.failed, .pending, .passed, .skipped]
    let (left, right) = (order.firstIndex(of: a.state)!, order.firstIndex(of: b.state)!)
    return left != right ? left < right : a.name.localizedStandardCompare(b.name) == .orderedAscending
  }

  /// Whether the checks need anything from the author, at a glance.
  private static func verdict(_ checks: [CheckItem]) -> (label: String, tone: Tone, detail: String)? {
    let requiredFailing = checks.filter { $0.required && $0.state == .failed }.count
    let requiredRunning = checks.filter { $0.required && $0.state == .pending }.count
    let advisoryFailing = checks.filter { !$0.required && $0.state == .failed }.count
    let advisoryRunning = checks.filter { !$0.required && $0.state == .pending }.count
    if requiredFailing > 0 { return ("Blocking merge", .bad, "\(plural(requiredFailing, "required check")) failing: fix before merging") }
    if requiredRunning > 0 { return ("Required running", .warn, "\(plural(requiredRunning, "required check")) still running") }
    if advisoryFailing > 0 || advisoryRunning > 0 {
      let parts = ["Required checks pass"]
        + (advisoryFailing > 0 ? ["\(plural(advisoryFailing, "advisory check")) failing"] : [])
        + (advisoryRunning > 0 ? ["\(plural(advisoryRunning, "advisory check")) still running"] : [])
      return ("Not blocking", .neutral, parts.joined(separator: "; "))
    }
    return checks.isEmpty ? nil : ("All passing", .good, "Every check passes")
  }
}

private struct CheckRow: View {
  let check: CheckItem

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).foregroundStyle(color).scaledFont(.caption)
      if let url = check.url.flatMap(URL.init(string:)) {
        Link(check.name, destination: url).foregroundStyle(.primary).clickable(underline: true)
      } else {
        Text(check.name)
      }
      Spacer(minLength: 4)
      if check.expected { Text("waiting to report").foregroundStyle(.tertiary) }
      if check.state == .failed { Chip(text: check.required ? "blocks merge" : "advisory", tone: check.required ? .bad : .neutral) }
    }
    .scaledFont(.caption)
    .lineLimit(1)
    .help(check.name)
  }

  private var symbol: String {
    switch check.state {
    case .failed: "xmark.circle.fill"
    case .pending: "circle.dotted"
    case .passed: "checkmark.circle.fill"
    case .skipped: "minus.circle"
    }
  }

  private var color: Color {
    switch check.state {
    case .failed: Tone.bad.color
    case .pending: Tone.warn.color
    case .passed: Tone.good.color
    case .skipped: .secondary
    }
  }
}

// MARK: Activity

struct ActivityPanel: View {
  let detail: PrDetail
  @State private var showBots = false

  var body: some View {
    let summary = detail.activitySummary
    let claimed = Set(detail.changeRequests.flatMap(\.threadIds))
    let otherThreads = detail.openThreads.filter { !claimed.contains($0.id) }
    let humans = detail.activity.filter { !$0.isBot }
    let shown = showBots ? detail.activity : humans
    let botCount = detail.activity.count - humans.count
    let facts = [plural(summary.commits, "commit"), plural(summary.approvals, "approval")]
      + (summary.changeRequests > 0 ? [plural(summary.changeRequests, "change request")] : [])
      + [plural(summary.comments, "comment")]
      + (detail.openThreads.isEmpty ? [] : [plural(detail.openThreads.count, "open thread")])

    Panel("Activity", aside: "last activity \(relative(summary.lastActivityAt))") {
      Text(facts.joined(separator: " · ")).scaledFont(.callout).foregroundStyle(.secondary)

      if !detail.changeRequests.isEmpty || !otherThreads.isEmpty {
        Text("Needs a response").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 6)
        ForEach(detail.changeRequests, id: \.reviewer.id) { request in
          ChangeRequestCard(request: request, threads: detail.openThreads.filter { request.threadIds.contains($0.id) })
        }
        ForEach(otherThreads) { ThreadCard(thread: $0) }
      }

      HStack {
        Text("Timeline").scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
        Spacer()
        if botCount > 0 {
          Button("\(showBots ? "Hide" : "Show") \(botCount) bot event\(botCount == 1 ? "" : "s")") { showBots.toggle() }
            .buttonStyle(.link).scaledFont(.caption).clickable(underline: true)
        }
      }
      .padding(.top, 6)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
          ActivityRow(item: item, isLast: index == shown.count - 1)
        }
      }
    }
  }
}

private struct ActivityRow: View {
  let item: ActivityItem
  let isLast: Bool
  @State private var expanded = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 0) {
        Image(systemName: symbol)
          .scaledFont(.caption)
          .foregroundStyle(color)
          .scaledFrame(width: 24, height: 24)
          .background(.background, in: .circle)
          .overlay(Circle().strokeBorder(Palette.border))
        if !isLast { Rectangle().fill(Palette.border).frame(width: 1).frame(maxHeight: .infinity) }
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          if let actor = item.actor { AvatarView(url: actor.avatarUrl, size: 16) }
          Text(item.actor?.name ?? "Someone").fontWeight(.medium)
          Text(item.title).foregroundStyle(.secondary)
          if let url = item.url.flatMap(URL.init(string:)) {
            Link(relative(item.at), destination: url).scaledFont(.caption).foregroundStyle(.tertiary).clickable(underline: true)
          } else {
            Text(relative(item.at)).scaledFont(.caption).foregroundStyle(.tertiary)
          }
        }
        .scaledFont(.callout)
        .lineLimit(1)
        if let body = item.body {
          if item.kind == .commits {
            ForEach(Array(body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
              Text(line).scaledFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
          } else {
            Text(body)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(expanded ? nil : 3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(Palette.fill, in: .rect(cornerRadius: 6))
              .onTapGesture { expanded.toggle() }
              .help(expanded ? "Show less" : "Show more")
          }
        }
      }
      .padding(.top, 3)
      .padding(.bottom, isLast ? 0 : 14)
    }
  }

  private var symbol: String {
    switch item.kind {
    case .opened: "arrow.triangle.pull"
    case .commits: "point.topleft.down.to.point.bottomright.curvepath"
    case .approved: "checkmark"
    case .changesRequested: "exclamationmark.circle"
    case .reviewed: "doc.text.magnifyingglass"
    case .comment: "bubble.left"
    case .reviewRequested: "person.badge.plus"
    case .event: "circle.fill"
    }
  }

  private var color: Color {
    switch item.kind {
    case .opened: Tone.info.color
    case .approved: Tone.good.color
    case .changesRequested: Tone.bad.color
    default: .secondary
    }
  }
}

private struct ThreadCard: View {
  let thread: ReviewThread

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Link("\(thread.path)\(thread.line.map { ":\($0)" } ?? "")", destination: URL(string: thread.url)!)
          .scaledFont(.caption.monospaced()).foregroundStyle(Tone.info.color).lineLimit(1).truncationMode(.head)
          .clickable(underline: true)
        if thread.isOutdated { Chip(text: "outdated", tone: .neutral) }
        if thread.isBot { Chip(text: "bot", tone: .neutral) }
      }
      Text(thread.body).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(3)
      HStack(spacing: 5) {
        if let author = thread.author { AvatarView(url: author.avatarUrl, size: 14) }
        Text(
          "\(thread.author?.name ?? "Someone") · \(relative(thread.createdAt))\(thread.replies > 0 ? " · \(thread.replies) repl\(thread.replies == 1 ? "y" : "ies")" : "")"
        )
      }
      .scaledFont(.caption).foregroundStyle(.tertiary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }
}

private struct ChangeRequestCard: View {
  let request: ChangeRequest
  let threads: [ReviewThread]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        AvatarView(url: request.reviewer.avatarUrl, size: 18)
        Text(request.reviewer.name).fontWeight(.medium)
        Text("requested changes").foregroundStyle(Tone.bad.color)
        Link(relative(request.at), destination: URL(string: request.url)!).scaledFont(.caption).foregroundStyle(.tertiary)
          .clickable(underline: true)
      }
      .scaledFont(.callout)
      if !request.body.isEmpty { Text(request.body).scaledFont(.caption).textSelection(.enabled) }
      ForEach(threads) { ThreadCard(thread: $0) }
      if request.body.isEmpty && threads.isEmpty {
        Text("No message or open threads; see the review on GitHub.").scaledFont(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tone.bad.soft.opacity(0.6), in: .rect(cornerRadius: 8))
  }
}

// MARK: Screenshots

/// The description's images as thumbnails; clicking one opens it large, with the rest a click away.
struct GalleryView: View {
  let images: [GalleryImage]
  @State private var open: Int?

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
      ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
        Button { open = index } label: {
          VStack(alignment: .leading, spacing: 4) {
            GitHubImage(image: image)
              .frame(height: 100)
              .frame(maxWidth: .infinity)
              .clipShape(.rect(cornerRadius: 6))
              .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
            Text(image.caption).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .buttonStyle(.plain)
        .clickable()
      }
    }
    .sheet(item: Binding(get: { open.map { OpenImage(index: $0) } }, set: { open = $0?.index })) { current in
      ImageViewer(images: images, index: current.index)
    }
  }

  private struct OpenImage: Identifiable {
    let index: Int
    var id: Int { index }
  }
}

private struct ImageViewer: View {
  let images: [GalleryImage]
  @State var index: Int
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let image = images[index]
    VStack(spacing: 10) {
      GitHubImage(image: image, fit: true).frame(minWidth: 640, minHeight: 420)
      HStack {
        Button("Previous", systemImage: "chevron.left") { index -= 1 }
          .disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
        Text("\(image.caption) · \(index + 1) of \(images.count)").foregroundStyle(.secondary)
        Button("Next", systemImage: "chevron.right") { index += 1 }
          .disabled(index == images.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
        Spacer()
        Link("Open Original", destination: URL(string: image.original)!)
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(idealWidth: 960, idealHeight: 700)
  }
}

/// An image from a description: loaded directly, or through the API with the token for files
/// attached to a private repo's releases. Anything that can't load offers to open it on GitHub.
private struct GitHubImage: View {
  let image: GalleryImage
  var fit = false
  @Environment(AppSettings.self) private var settings
  @State private var loaded: NSImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      Palette.fill
      if let loaded {
        Image(nsImage: loaded).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
      } else if failed {
        Link(destination: URL(string: image.original)!) {
          Label("Open on GitHub", systemImage: "photo.badge.exclamationmark").scaledFont(.caption)
        }
      } else {
        ProgressView().scaledControlSize(.small)
      }
    }
    .task(id: image.src) {
      do {
        let data: Data
        if ReleaseImages.needsToken(image.src) {
          data = try await ReleaseImages.shared.data(for: image.src, token: settings.githubCredential)
        } else {
          data = try await URLSession.shared.data(from: URL(string: image.src)!).0
        }
        if let image = NSImage(data: data) { loaded = image } else { failed = true }
      } catch {
        failed = true
      }
    }
  }
}
