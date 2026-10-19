import SwiftUI

/// One pull request: what stops it merging, its checks (kept live), the description, and what
/// happened, newest first. src/routes/PrDetailPage.tsx in SwiftUI.
struct PrDetailView: View {
  let key: PrKey
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var model: PrDetailModel
  /// The page's width, to put the side column beside the main one when there's room, as the web
  /// version does from its `lg` breakpoint.
  @Environment(\.textScale) private var textScale
  @State private var width: CGFloat = 0

  init(key: PrKey) {
    self.key = key
    _model = State(initialValue: AppState.shared.prDetails.model(for: key))
  }

  var body: some View {
    PageScrollView {
      if let detail = model.detail {
        content(detail).padding(.horizontal, 24).padding(.vertical, 20)
      } else if let error = model.error {
        ContentUnavailableView("Couldn't Load This Pull Request", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
          .padding(.top, 80)
      } else {
        PrDetailSkeleton().padding(.horizontal, 24).padding(.vertical, 20)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .workbenchPage()
    .navigationTitle(model.detail?.pr.title ?? "\(key.repo)#\(key.number)")
    .navigationSubtitle(subtitle)
    .toolbar { toolbar }
    .task {
      while !Task.isCancelled {
        await model.load(settings: settings, maxAge: .seconds(15))
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
    // Plain toolbar buttons, all alike: a Link in the toolbar draws as text with its own hover.
    ToolbarItemGroup {
      Button("Copy Link", systemImage: "link") { copyToPasteboard(key.url) }
        .clickable()
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("Copy the PR's link (⇧⌘C)")
      Button("Open on GitHub", systemImage: "arrow.up.right.square") { openURL(URL(string: key.url)!) }
        .clickable()
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .help("Open on GitHub (⇧⌘O)")
    }
    ToolbarItem {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.load(settings: settings) }
      }
      .clickable()
      .keyboardShortcut("r")
      .disabled(model.loading)
    }
  }

  /// Notes and pins follow the ticket when there is one, so they match Today and the PR list.
  private func itemRef(_ pr: Pr) -> Ref {
    pr.tickets.first.map { ticketRef($0.key) } ?? prRef(pr.repo, pr.number)
  }

  /// The web's layout: the main column and a 22rem side column, side by side when there's room,
  /// otherwise the side column first. Content stops at the web's max-w-6xl and centres.
  private func content(_ detail: PrDetail) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      header(detail)
      if width >= 880 * textScale {
        HStack(alignment: .top, spacing: 20) {
          main(detail).frame(maxWidth: .infinity, alignment: .leading)
          side(detail).scaledFrame(width: 352)
        }
      } else {
        VStack(alignment: .leading, spacing: 20) {
          side(detail)
          main(detail)
        }
      }
    }
    .frame(maxWidth: 1120 * textScale, alignment: .leading)
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
        Text(pr.title).scaledFont(.title2.weight(.semibold)).textSelection(.enabled)
        Text("#\(String(pr.number))").scaledFont(.title2).foregroundStyle(.tertiary)
        ItemControls(
          ref: itemRef(pr), title: pr.tickets.first.map { "\($0.key) \($0.title)" } ?? pr.title,
          url: pr.tickets.first?.url ?? pr.url, prs: [PrKey(pr)]
        )
      }
      NoteLine(ref: itemRef(pr))
      HStack(spacing: 14) {
        HStack(spacing: 5) {
          AvatarView(url: pr.authorAvatarUrl, size: 16)
          Text(pr.author)
        }
        Text("\(pr.headRef) → \(pr.baseRef)").scaledFont(.caption.monospaced())
        HStack(spacing: 4) {
          Text("+\(pr.additions)").foregroundStyle(Tone.good.color)
          Text("−\(pr.deletions)").foregroundStyle(Tone.bad.color)
        }
        if let opened = parseDate(pr.createdAt) {
          Text("opened \(opened, format: .relative(presentation: .named))")
        }
        Text(pr.repo)
      }
      .scaledFont(.caption)
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

/// A section of the page as the web draws it: a card with a header row (a chevron to collapse it,
/// the title, and anything else on the right), then the content.
struct Panel<Accessory: View, Content: View>: View {
  let title: String
  let accessory: Accessory
  let content: Content
  @State private var expanded = true

  init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          withAnimation(.snappy) { expanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.down")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(expanded ? 0 : -90))
            Text(title).scaledFont(.callout.weight(.semibold))
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .clickable()
        .accessibilityHint(expanded ? "Collapses the section" : "Expands the section")
        Spacer(minLength: 8)
        accessory.scaledFont(.caption)
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      if expanded {
        Divider().overlay(Palette.border)
        LazyVStack(alignment: .leading, spacing: 10) { content }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      }
    }
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
  }
}

extension Panel where Accessory == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }
}

extension Panel where Accessory == Text {
  init(_ title: String, aside: String, @ViewBuilder content: () -> Content) {
    self.init(title, accessory: { Text(aside).foregroundStyle(.secondary) }, content: content)
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
      .scaledFont(.caption.weight(.medium))
      .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(tone.soft, in: .capsule)
  }
}

/// The details page's shape while it loads for the first time: the header, then the panels.
private struct PrDetailSkeleton: View {
  @Environment(\.textScale) private var textScale

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          SkeletonBar(width: 90, height: 18)
          SkeletonBar(width: 70, height: 18)
        }
        SkeletonBar(width: 420, height: 20)
        SkeletonBar(width: 260, height: 10)
      }
      HStack(alignment: .top, spacing: 20) {
        VStack(spacing: 20) {
          SkeletonPanel(title: "Merge status", rows: 2)
          SkeletonPanel(title: "Description", rows: 3)
        }
        SkeletonPanel(title: "Checks", rows: 4).scaledFrame(width: 352)
      }
    }
    .frame(maxWidth: 1120 * textScale, alignment: .leading)
    .frame(maxWidth: .infinity)
  }
}
