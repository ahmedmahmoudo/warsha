import ImageIO
import SwiftUI

/// One PR: what it's waiting on, its tickets, its checks and who still has to review.
/// src/components/PrRow.tsx in SwiftUI.
struct PrRowView: View {
  let pr: Pr
  let viewer: String
  let stackParent: Pr?
  @Environment(Store.self) private var store
  @Environment(\.textScale) private var textScale

  private var itemRef: Ref { pr.tickets.first.map { ticketRef($0.key) } ?? prRef(pr.repo, pr.number) }
  private var changes: [String] { store.changes(pr, viewer: viewer) }
  private var controlTitle: String { pr.tickets.first.map { "\($0.key) \($0.title)" } ?? pr.title }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      main.frame(maxWidth: .infinity, alignment: .leading)
      ChecksColumn(checks: pr.checks).scaledFrame(width: 190, alignment: .leading)
      ReviewsColumn(pr: pr).scaledFrame(width: 210, alignment: .leading)
    }
    .padding(.vertical, 6)
  }

  private var main: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowLayout(spacing: 6) {
        Chip(text: pr.status.label, tone: pr.status.tone, strong: true)
        if let parked = store.parked(for: pr) {
          Chip(text: parked.until.map { "Parked until \($0.dropFirst(5).replacingOccurrences(of: "-", with: "/"))" } ?? "Parked", tone: .info)
            .help(parked.reason ?? "")
        }
        ForEach(pr.tickets, id: \.key) { TicketChip(ticket: $0) }
        if pr.tickets.isEmpty {
          ForEach(pr.ticketKeys, id: \.self) { Text($0).scaledFont(.caption.monospaced()).foregroundStyle(.secondary).chipBorder() }
        }
        ForEach(pr.mismatches, id: \.self) { Chip(text: $0.label, tone: .warn) }
      }

      HStack(spacing: 6) {
        UpdatedDot(changes: changes)
        // Double-click or Return opens the details; the list owns that, so the title is plain text.
        Text(pr.title).scaledFont(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
        // Pin, note and park follow the ticket when there is one, as on Today.
        ItemControls(ref: itemRef, title: controlTitle, url: pr.tickets.first?.url ?? pr.url, prs: [PrKey(pr)])
      }

      NoteLine(ref: itemRef)
      UpdateLine(changes: changes) { store.markSeen(pr, viewer: viewer) }

      if pr.author == viewer && pr.mergedAt == nil && TodayRules.prNeed(pr, ageMessage: nil)?.kind == .slowReview {
        NudgeLine(pr: pr)
      }

      HStack(spacing: 12) {
        Text("#\(String(pr.number))").scaledFont(.caption.monospaced())
        if pr.author != viewer {
          HStack(spacing: 4) {
            AvatarView(url: pr.authorAvatarUrl, size: 16)
            Text(pr.author)
          }
        }
        Text("→ \(Text(pr.baseRef).font(Typeface.caption.monospaced().font(textScale)))")
        WorktreeChip(pr: pr)
        if let stackParent {
          Link("stacked on #\(String(stackParent.number))", destination: URL(string: stackParent.url)!).clickable(underline: true)
        }
        HStack(spacing: 4) {
          Text("+\(pr.additions)").foregroundStyle(Tone.good.color)
          Text("−\(pr.deletions)").foregroundStyle(Tone.bad.color)
        }
        if let date = parseDate(pr.mergedAt ?? pr.updatedAt) {
          Text("\(pr.mergedAt == nil ? "updated" : "merged") \(date, format: .relative(presentation: .named))")
        }
      }
      .scaledFont(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

/// Your PR is short of approvals: copy its link to nudge the reviewers listed on the right, then
/// mark it nudged. It's left alone for the nudge interval after that, as on Today.
private struct NudgeLine: View {
  let pr: Pr
  @Environment(Store.self) private var store
  @Environment(AppSettings.self) private var settings

  var body: some View {
    let ping = store.pings[pr.url]
    if TodayRules.recentlyPinged(ping, kind: .slowReview, nudgeAgainHours: settings.nudgeAgainHours) {
      HStack(spacing: 4) {
        Image(systemName: "bell").scaledFont(.caption).foregroundStyle(.tertiary)
        PingLabel(ping: ping)
      }
    } else {
      HStack(spacing: 6) {
        Chip(text: "Nudge reviewers", tone: .warn)
        GlassEffectContainer(spacing: 4) {
          HStack(spacing: 4) {
            CopyLinkButton(url: pr.url)
            Button("Nudged", systemImage: "checkmark") { store.ping(pr.url, .nudged) }
              .buttonStyle(.pill(.warn)).clickable()
              .help("Mark the reviewers as nudged")
          }
        }
      }
    }
  }
}

private struct ChecksColumn: View {
  let checks: CheckSummary
  private let maxListed = 3

  var body: some View {
    // A failing required aggregate ("Required CI") says nothing on its own, so name what broke it.
    let showAdvisoryNames = checks.state == .failing && !checks.advisoryFailing.isEmpty
    VStack(alignment: .leading, spacing: 2) {
      Text("Checks").foregroundStyle(.tertiary)
      switch checks.state {
      case .failing: ForEach(checks.failing, id: \.name) { CheckLink(check: $0, color: Tone.bad.color) }
      case .pending: Text("\(checks.pending.count) required running").foregroundStyle(.secondary)
      case .passing: Text("Required pass").foregroundStyle(Tone.good.color)
      case .none: Text("None").foregroundStyle(.tertiary)
      }
      if showAdvisoryNames {
        ForEach(checks.advisoryFailing.prefix(maxListed), id: \.name) { CheckLink(check: $0, color: .secondary) }
      }
      if checks.advisoryFailing.count > (showAdvisoryNames ? maxListed : 0) {
        Text(
          showAdvisoryNames ? "+\(checks.advisoryFailing.count - maxListed) more failing" : "\(checks.advisoryFailing.count) advisory failing"
        )
        .foregroundStyle(.tertiary)
        .help(checks.advisoryFailing.map(\.name).joined(separator: "\n"))
      }
    }
    .scaledFont(.caption)
    .lineLimit(1)
  }
}

private struct CheckLink: View {
  let check: FailedCheck
  let color: Color

  var body: some View {
    if let url = check.url.flatMap(URL.init(string:)) {
      Link(check.name, destination: url).foregroundStyle(color).clickable(underline: true)
    } else {
      Text(check.name).foregroundStyle(color)
    }
  }
}

struct ReviewsColumn: View {
  let pr: Pr

  var body: some View {
    let gate = pr.reviewGate
    let blocking = gate.map { $0.codeOwners.count + ($0.approvalsNeeded > 0 ? 1 : 0) } ?? 0
    VStack(alignment: .leading, spacing: 4) {
      Text(blocking > 0 ? "Needs approval from" : "Reviews").foregroundStyle(.tertiary)

      if let gate {
        ForEach(gate.codeOwners, id: \.self) { group in
          ReviewLine(people: group, text: names(group, " or "), color: .primary)
            .help("Code owner: \(names(group, " or "))")
        }
        if gate.approvalsNeeded > 0 {
          HStack(spacing: 6) {
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.tertiary).frame(width: 18, height: 18)
            Text("\(gate.approvalsNeeded) \(gate.codeOwners.isEmpty ? "" : "more ")approval\(gate.approvalsNeeded == 1 ? "" : "s")")
          }
          .foregroundStyle(.secondary)
        }
        if !gate.complete { Text("Code owners may be incomplete").foregroundStyle(.tertiary) }
      }
      if !pr.changesRequestedBy.isEmpty {
        ReviewLine(people: pr.changesRequestedBy, text: "Changes requested", color: Tone.bad.color).help(names(pr.changesRequestedBy))
      }
      if !pr.approvals.isEmpty {
        ReviewLine(people: pr.approvals, text: "Approved", color: Tone.good.color).help(names(pr.approvals))
      }
      if let gate, !gate.optional.isEmpty {
        Text("+\(gate.optional.count) optional reviewer\(gate.optional.count == 1 ? "" : "s")")
          .foregroundStyle(.tertiary)
          .help("Requested, but not required to merge: \(names(gate.optional))")
      }
      Text(coderabbitLine).foregroundStyle(pr.coderabbit.review == .changesRequested ? AnyShapeStyle(Tone.warn.color) : AnyShapeStyle(.tertiary))
    }
    .scaledFont(.caption)
    .lineLimit(1)
  }

  private var coderabbitLine: String {
    let review = switch pr.coderabbit.review {
    case .approved: "approved"
    case .changesRequested: "wants changes"
    case .commented: "commented"
    case nil: "not reviewed"
    }
    return "CodeRabbit \(review)\(pr.coderabbit.unresolvedThreads > 0 ? ", \(pr.coderabbit.unresolvedThreads) open" : "")"
  }

  private func names(_ people: [Person], _ joiner: String = ", ") -> String {
    people.map(\.name).joined(separator: joiner)
  }
}

private struct ReviewLine: View {
  let people: [Person]
  let text: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: -5) {
        ForEach(people.prefix(4), id: \.id) { AvatarView(url: $0.avatarUrl, size: 18, team: $0.kind == .team) }
      }
      Text(text).foregroundStyle(color)
    }
  }
}

struct TicketChip: View {
  let ticket: Ticket

  var body: some View {
    Link(destination: URL(string: ticket.url)!) {
      HStack(spacing: 5) {
        Circle().fill(Color(hex: ticket.stateColor) ?? .gray).frame(width: 7, height: 7)
        Text(ticket.key).scaledFont(.caption.monospaced()).foregroundStyle(.primary)
        Text(ticket.state).scaledFont(.caption).foregroundStyle(.secondary)
      }
      .chipBorder()
    }
    .clickable()
    .help([ticket.title, ticket.assignee, ticket.project].compactMap { $0 }.joined(separator: " · "))
  }
}

struct Chip: View {
  let text: String
  let tone: Tone
  var strong = false

  var body: some View {
    Text(text)
      .scaledFont(.caption.weight(strong ? .medium : .regular))
      .foregroundStyle(tone == .neutral ? .secondary : tone.color)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(tone.soft, in: .capsule)
  }
}

struct AvatarView: View {
  let url: String?
  let size: CGFloat
  var team = false
  @Environment(\.displayScale) private var displayScale
  @State private var loaded: NSImage?

  var body: some View {
    // From memory when it's been seen before, so a row scrolled back in shows it at once instead
    // of the placeholder and then the picture.
    let image = loaded ?? url.flatMap { AvatarCache.shared.image(for: $0, pixels: pixels) }
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: team ? "person.2.fill" : "person.fill").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(.secondary)
          .background(Palette.fill)
      }
    }
    .frame(width: size, height: size)
    .clipShape(team ? AnyShape(.rect(cornerRadius: size * 0.2)) : AnyShape(.circle))
    .overlay(Circle().strokeBorder(.background, lineWidth: 1).opacity(team ? 0 : 1))
    .task(id: url) {
      guard let url, image == nil else { return }
      loaded = await AvatarCache.shared.load(url, pixels: pixels)
    }
  }

  private var pixels: Int { Int((size * displayScale).rounded(.up)) }
}

/// Avatars, downsized to the size they're drawn at and kept for the session. GitHub sends 460px
/// pictures; scaling those down on every frame of a scroll is what made lists stutter.
@MainActor
final class AvatarCache {
  static let shared = AvatarCache()
  private var images: [String: NSImage] = [:]
  private var loading: [String: Task<NSImage?, Never>] = [:]

  func image(for url: String, pixels: Int) -> NSImage? { images["\(pixels)@\(url)"] }

  func load(_ url: String, pixels: Int) async -> NSImage? {
    let key = "\(pixels)@\(url)"
    if let image = images[key] { return image }
    if let task = loading[key] { return await task.value }
    let task = Task.detached(priority: .utility) { () -> NSImage? in
      guard let address = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: address) else { return nil }
      return Self.downsized(data, pixels: pixels)
    }
    loading[key] = task
    let image = await task.value
    loading[key] = nil
    if let image { images[key] = image }
    return image
  }

  /// Fetches avatars before their rows scroll in, so none appears late. `size` is in points.
  func warm(_ avatars: [(url: String, size: CGFloat)]) {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    for avatar in avatars {
      let pixels = Int((avatar.size * scale).rounded(.up))
      Task { _ = await load(avatar.url, pixels: pixels) }
    }
  }

  /// Every avatar a PR's row shows: its author's, and the reviewers' (four per line at most).
  func warm(_ prs: [Pr]) {
    warm(prs.flatMap { pr -> [(url: String, size: CGFloat)] in
      let reviewers = (pr.reviewGate?.codeOwners ?? []).map { Array($0.prefix(4)) } + [pr.changesRequestedBy, pr.approvals].map { Array($0.prefix(4)) }
      return [pr.authorAvatarUrl.map { ($0, CGFloat(16)) }].compactMap { $0 }
        + reviewers.joined().compactMap { $0.avatarUrl.map { ($0, CGFloat(18)) } }
    })
  }

  private nonisolated static func downsized(_ data: Data, pixels: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1),
          ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}

extension View {
  func chipBorder() -> some View {
    padding(.horizontal, 7).padding(.vertical, 2)
      .overlay(Capsule().strokeBorder(Palette.border))
  }
}

/// GitHub's timestamps ("2026-10-17T03:04:05Z").
func parseDate(_ iso: String) -> Date? {
  try? Date(iso, strategy: .iso8601)
}

/// Lays children out in rows, wrapping when the row is full. Each child is measured once per
/// layout pass and kept in the cache, rather than again for every row and placement.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

  func updateCache(_ cache: inout [CGSize], subviews: Subviews) { cache = makeCache(subviews: subviews) }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, sizes: cache)
    return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, sizes: cache) {
      var x = bounds.minX
      for index in row.indices {
        let size = cache[index]
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private func arrange(width: CGFloat, sizes: [CGSize]) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
    var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
    for (index, size) in sizes.enumerated() {
      if let last = rows.last, last.width + spacing + size.width <= width {
        rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
      } else {
        rows.append(([index], size.width, size.height))
      }
    }
    return rows
  }
}
