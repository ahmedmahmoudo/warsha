import SwiftUI

// What's changed on your PRs and tickets since you last saw them. Each item's snapshot is kept in
// the store: the first time an item turns up becomes its baseline, opening a PR or marking it
// seen moves the baseline up, and any difference in between shows as a dot and a line of changes.

/// A PR or ticket as you last saw it: only what's worth telling you about when it changes.
struct Seen: Codable, Equatable, Sendable {
  var title: String
  var url: String
  var updatedAt: String?
  var status: String?
  var checks: String?
  var approvals: [String]?
  var changesRequested: [String]?
  var threadsToReply: Int?
  var size: String?
  var merged: Bool?
  /// Yours, so new commits aren't news.
  var mine: Bool?
  var state: String?
  var priority: String?

  init(_ pr: Pr, viewer: String) {
    title = pr.title
    url = pr.url
    updatedAt = pr.updatedAt
    status = pr.status.label
    checks = "\(pr.checks.state)"
    approvals = pr.approvals.map(\.name).sorted()
    changesRequested = pr.changesRequestedBy.map(\.name).sorted()
    threadsToReply = pr.threadsToReply
    size = "+\(pr.additions) −\(pr.deletions)"
    merged = pr.mergedAt != nil
    mine = pr.author.caseInsensitiveCompare(viewer) == .orderedSame
  }

  init(_ ticket: OpenTicket) {
    title = ticket.ticket.title
    url = ticket.ticket.url
    state = ticket.ticket.state
    priority = ticket.priorityLabel
  }
}

/// One item that's changed since you saw it, with what changed.
struct ItemUpdate: Identifiable {
  let ref: Ref
  let current: Seen
  let changes: [String]
  let pr: Pr?
  let ticket: OpenTicket?
  var id: Ref { ref }
}

enum Updates {
  /// What changed between two snapshots, in plain words; empty when nothing did.
  static func changes(from old: Seen, to new: Seen) -> [String] {
    var changes: [String] = []
    if new.merged == true && old.merged != true { changes.append("Merged") }
    if let status = new.status, status != old.status, new.merged != true { changes.append("Now \(status.lowercasedFirst)") }
    let approved = (new.approvals ?? []).filter { !(old.approvals ?? []).contains($0) }
    if !approved.isEmpty { changes.append("Approved by \(approved.joined(separator: ", "))") }
    let requested = (new.changesRequested ?? []).filter { !(old.changesRequested ?? []).contains($0) }
    if !requested.isEmpty { changes.append("Changes requested by \(requested.joined(separator: ", "))") }
    let threads = (new.threadsToReply ?? 0) - (old.threadsToReply ?? 0)
    if threads > 0 { changes.append("\(threads) new thread\(threads == 1 ? "" : "s") to reply to") }
    if new.size != old.size, new.mine != true { changes.append("New commits") }
    if new.checks != old.checks, new.status == old.status, let checks = new.checks { changes.append("Checks \(checks)") }
    if let state = new.state, state != old.state { changes.append("Moved to \(state)") }
    if let priority = new.priority, priority != old.priority { changes.append("Priority \(priority)") }
    if new.title != old.title { changes.append("Renamed") }
    if changes.isEmpty, let updated = new.updatedAt, updated != old.updatedAt { changes.append("New activity") }
    return changes
  }

  /// Every PR and ticket loaded so far, as it is now: your PRs and the ones you review, then your tickets.
  @MainActor
  static func current(prs: PullRequestsModel, today: TodayModel) -> [(ref: Ref, seen: Seen, pr: Pr?, ticket: OpenTicket?)] {
    var items: [(ref: Ref, seen: Seen, pr: Pr?, ticket: OpenTicket?)] = []
    var refs = Set<Ref>()
    for scope in [PrScope.mine, .reviewing] {
      guard let response = prs.responses[scope] else { continue }
      for pr in response.open + response.recentlyMerged where refs.insert(prRef(pr.repo, pr.number)).inserted {
        items.append((prRef(pr.repo, pr.number), Seen(pr, viewer: response.viewer), pr, nil))
      }
    }
    for ticket in today.data?.tickets ?? [] where refs.insert(ticketRef(ticket.key)).inserted {
      items.append((ticketRef(ticket.key), Seen(ticket), nil, ticket))
    }
    return items
  }

  /// What's changed since you last looked, most recently updated PRs first, then tickets.
  @MainActor
  static func list(store: Store, prs: PullRequestsModel, today: TodayModel) -> [ItemUpdate] {
    current(prs: prs, today: today).compactMap { item in
      guard let old = store.seen[item.ref] else { return nil }
      let changes = changes(from: old, to: item.seen)
      return changes.isEmpty ? nil : ItemUpdate(ref: item.ref, current: item.seen, changes: changes, pr: item.pr, ticket: item.ticket)
    }
  }
}

extension Store {
  /// What changed on a PR since you saw it; empty when nothing did or it's new to you.
  func changes(_ pr: Pr, viewer: String) -> [String] {
    seen[prRef(pr.repo, pr.number)].map { Updates.changes(from: $0, to: Seen(pr, viewer: viewer)) } ?? []
  }

  func markSeen(_ pr: Pr, viewer: String) { markSeen([prRef(pr.repo, pr.number): Seen(pr, viewer: viewer)]) }
}

private extension String {
  var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// The dot beside something updated since you saw it; hovering lists what changed.
struct UpdatedDot: View {
  let changes: [String]

  var body: some View {
    if !changes.isEmpty {
      Circle().fill(Tone.info.color).frame(width: 7, height: 7)
        .help("Updated: \(changes.joined(separator: ", "))")
        .accessibilityLabel("Updated: \(changes.joined(separator: ", "))")
    }
  }
}

/// What changed, under a row, with a link to mark it seen.
struct UpdateLine: View {
  let changes: [String]
  let markSeen: () -> Void

  var body: some View {
    if !changes.isEmpty {
      HStack(spacing: 6) {
        Text(changes.joined(separator: " · ")).foregroundStyle(Tone.info.color).lineLimit(1)
        Button("Seen", action: markSeen).buttonStyle(.link).clickable(underline: true).help("Mark as seen")
      }
      .scaledFont(.caption)
    }
  }
}

/// Today's list of PRs and tickets that changed since you last looked.
struct UpdatesSection: View {
  @Environment(Store.self) private var store
  @Environment(PullRequestsModel.self) private var prs
  @Environment(TodayModel.self) private var today
  @Environment(Navigation.self) private var navigation

  var body: some View {
    let updates = Updates.list(store: store, prs: prs, today: today)
    Panel("Updated since you looked") {
      if !updates.isEmpty {
        SmallLink(title: "Mark all seen") {
          store.markSeen(Dictionary(updates.map { ($0.ref, $0.current) }, uniquingKeysWith: { first, _ in first }))
        }
      }
    } content: {
      if updates.isEmpty { Text("Nothing has changed since you last looked.").foregroundStyle(.tertiary) }
      Capped(items: updates, limit: 8) { index, update in
        if index > 0 { Divider().overlay(Palette.border) }
        row(update)
      }
    }
  }

  private func row(_ update: ItemUpdate) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      UpdatedDot(changes: update.changes)
      VStack(alignment: .leading, spacing: 2) {
        Button {
          if let pr = update.pr {
            navigation.open(PrKey(pr))
          } else if let url = URL(string: update.current.url) {
            NSWorkspace.shared.open(url)
          }
          store.markSeen([update.ref: update.current])
        } label: {
          Text("\(Text(label(update)).foregroundStyle(.tertiary)) \(update.current.title)").lineLimit(1).truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .clickable(underline: true)
        .help(update.current.title)
        UpdateLine(changes: update.changes) { store.markSeen([update.ref: update.current]) }
      }
    }
    .scaledFont(.callout)
    .padding(.vertical, 4)
  }

  private func label(_ update: ItemUpdate) -> String {
    if let pr = update.pr { return "#\(pr.number)" }
    return update.ticket?.key ?? ""
  }
}
