import SwiftUI

/// One pull request: what stops it merging, its checks (kept live), the description, and what
/// happened, newest first. src/routes/PrDetailPage.tsx in SwiftUI.
struct PrDetailView: View {
  let key: PrKey
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @State private var model: PrDetailModel

  init(key: PrKey) {
    self.key = key
    _model = State(initialValue: PrDetailModel(key: key))
  }

  var body: some View {
    ScrollView {
      if let detail = model.detail {
        content(detail).padding(20)
      } else if let error = model.error {
        ContentUnavailableView("Couldn't Load This Pull Request", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
          .padding(.top, 80)
      } else {
        ProgressView("Loading pull request…").padding(.top, 120)
      }
    }
    .workbenchPage()
    .navigationTitle(model.detail?.pr.title ?? "\(key.repo)#\(key.number)")
    .navigationSubtitle(subtitle)
    .toolbar { toolbar }
    .task {
      while !Task.isCancelled {
        await model.load(settings: settings)
        try? await Task.sleep(for: PrDetailModel.refreshInterval)
      }
    }
    .task(id: model.detail == nil) {
      guard model.detail != nil else { return }
      while !Task.isCancelled && !model.isFinished {
        try? await Task.sleep(for: model.checksInterval)
        await model.pollChecks(settings: settings)
      }
    }
  }

  private var subtitle: String {
    if model.loading { return "Updating…" }
    guard let detail = model.detail else { return "" }
    return "\(key.repo)#\(key.number) · updated at \(detail.fetchedAt.formatted(date: .omitted, time: .shortened))"
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      if let pr = model.detail?.pr {
        let ref = itemRef(pr)
        let pinned = store.pins.contains { $0.ref == ref }
        Button(pinned ? "Unpin" : "Pin to Focus", systemImage: pinned ? "pin.slash" : "pin") {
          if pinned {
            store.unpin(ref)
          } else {
            store.pin(ref, title: pr.tickets.first.map { "\($0.key) \($0.title)" } ?? pr.title, url: pr.tickets.first?.url ?? pr.url)
          }
        }
        Link(destination: URL(string: pr.url)!) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
      }
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.load(settings: settings) }
      }
      .keyboardShortcut("r")
      .disabled(model.loading)
    }
  }

  /// Notes and pins follow the ticket when there is one, so they match Today and the PR list.
  private func itemRef(_ pr: Pr) -> Ref {
    pr.tickets.first.map { ticketRef($0.key) } ?? prRef(pr.repo, pr.number)
  }

  private func content(_ detail: PrDetail) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      header(detail)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          main(detail).frame(minWidth: 460)
          side(detail).frame(width: 340)
        }
        VStack(alignment: .leading, spacing: 20) {
          side(detail)
          main(detail)
        }
      }
    }
    .frame(maxWidth: 1180, alignment: .leading)
    .frame(maxWidth: .infinity)
  }

  private func header(_ detail: PrDetail) -> some View {
    let pr = detail.pr
    return VStack(alignment: .leading, spacing: 8) {
      FlowLayout(spacing: 6) {
        StateBadge(detail: detail)
        ForEach(pr.tickets, id: \.key) { TicketChip(ticket: $0) }
        if let parked = store.parked(for: pr) {
          Chip(text: parked.until.map { "Parked until \($0)" } ?? "Parked", tone: .info).help(parked.reason ?? "")
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(pr.title).font(.title2.weight(.semibold)).textSelection(.enabled)
        Text("#\(pr.number)").font(.title2).foregroundStyle(.tertiary)
      }
      if let note = store.notes.first(where: { $0.ref == itemRef(pr) }) {
        Label(note.body, systemImage: "note.text").font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 14) {
        HStack(spacing: 5) {
          AvatarView(url: pr.authorAvatarUrl, size: 16)
          Text(pr.author)
        }
        Text("\(pr.headRef) → \(pr.baseRef)").font(.caption.monospaced())
        HStack(spacing: 4) {
          Text("+\(pr.additions)").foregroundStyle(Tone.good.color)
          Text("−\(pr.deletions)").foregroundStyle(Tone.bad.color)
        }
        if let opened = parseDate(pr.createdAt) {
          Text("opened \(opened, format: .relative(presentation: .named))")
        }
        Text(pr.repo)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func main(_ detail: PrDetail) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      Panel("Description") {
        if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("No description.").foregroundStyle(.tertiary)
        } else {
          MarkdownView(detail.body)
        }
      }
      if !detail.images.isEmpty {
        Panel("Screenshots", aside: "\(detail.images.count) image\(detail.images.count == 1 ? "" : "s")") {
          GalleryView(images: detail.images)
        }
      }
      ActivityPanel(detail: detail)
    }
  }

  private func side(_ detail: PrDetail) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      ActionsPanel(detail: detail, model: model)
      MergePanel(detail: detail)
      ChecksPanel(model: model)
      if !model.isFinished {
        Panel("Reviewers") { ReviewsColumn(pr: detail.pr).lineLimit(nil) }
      }
    }
  }
}

/// A titled section of the page, as a native group box.
struct Panel<Content: View>: View {
  let title: String
  var aside: String?
  @ViewBuilder let content: Content

  init(_ title: String, aside: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.aside = aside
    self.content = content()
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) { content }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    } label: {
      HStack {
        Text(title).font(.headline)
        Spacer()
        if let aside { Text(aside).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }
}

private struct StateBadge: View {
  let detail: PrDetail

  var body: some View {
    let (label, symbol, tone): (String, String, Tone) = switch detail.state {
    case .draft: ("Draft", "circle.dashed", .neutral)
    case .open: ("Open", "arrow.triangle.pull", .info)
    case .ready: ("Ready to merge", "checkmark.circle", .good)
    case .queued: ("Queued\(detail.merge.queue?.position.map { " · #\($0)" } ?? "")", "list.bullet.indent", .warn)
    case .merged: ("Merged", "arrow.triangle.merge", .good)
    case .closed: ("Closed", "xmark.circle", .bad)
    }
    Label(label, systemImage: symbol)
      .font(.caption.weight(.medium))
      .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(tone.soft, in: .capsule)
  }
}
