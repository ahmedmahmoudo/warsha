import SwiftUI

/// The Pull Requests page: your open PRs grouped by who they're waiting on, with each one's real
/// gate state, plus the last week's merged ones. src/routes/PullRequestsPage.tsx in SwiftUI.
struct PullRequestsView: View {
  /// A filter bar choice: one waiting-on group, or ticket mismatches.
  enum Filter: Hashable {
    case waitingOn(WaitingOn)
    case mismatches
    /// Changed since you last saw them.
    case updated
  }

  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(PullRequestsModel.self) private var model
  @Environment(Navigation.self) private var navigation
  @AppStorage("prScope") private var scope: PrScope = .mine
  @State private var filter: Filter?
  @State private var search = ""
  @State private var selection = Set<Pr.ID>()
  @State private var showParked = false
  /// Which page of the list, from 0; back to the first whenever what's listed changes.
  @State private var page = 0
  private static let pageSize = 20

  var body: some View {
    let data = model.responses[scope]
    list(data)
      .listStyle(.inset)
      .workbenchPage()
      .contextMenu(forSelectionType: Pr.ID.self) { ids in
        menu(for: prs(ids, in: data))
      } primaryAction: { ids in
        // One PR opens its details here; several open on GitHub.
        let chosen = prs(ids, in: data)
        if chosen.count == 1 {
          navigation.open(PrKey(chosen[0]))
        } else {
          for pr in chosen { NSWorkspace.shared.open(URL(string: pr.url)!) }
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) { topBar(data) }
      .overlay { placeholder(data) }
      .searchable(text: $search, placement: .toolbar, prompt: "Title, number, ticket or author")
      .navigationTitle("Pull Requests")
      .navigationSubtitle(subtitle(data))
      .toolbar { toolbar }
      .task(id: data?.fetchedAt) {
        // Avatars ready before their rows scroll in, so none appears late.
        if let data { AvatarCache.shared.warm(data.open + data.recentlyMerged) }
      }
      .onChange(of: filter) { page = 0 }
      .onChange(of: search) { page = 0 }
      .onChange(of: scope) {
        filter = nil
        page = 0
        selection = []
      }
      .task(id: scope) {
        while !Task.isCancelled {
          await model.load(scope, settings: settings, maxAge: .seconds(15))
          try? await Task.sleep(for: PullRequestsModel.refreshInterval)
        }
      }
  }

  // MARK: The list

  private func list(_ data: PrsResponse?) -> some View {
    let paged = paginate(data.map(grouped) ?? Groups())
    return List(selection: $selection) {
      if let error = model.errors[scope] {
        Section {
          Label(error is NotConfigured ? "Setup needed: \(error.localizedDescription)" : error.localizedDescription,
                systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Tone.bad.color)
            .textSelection(.enabled)
        }
      }
      if let warnings = data?.warnings, !warnings.isEmpty {
        Section {
          ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.color) }
        }
      }
      if let data {
        ForEach(paged.blocks, id: \.id) { block in
          if block.id == Block.parkedID {
            Section(isExpanded: $showParked) {
              rows(block.prs, all: data.open, viewer: data.viewer)
            } header: {
              SectionHeader(title: block.title, count: block.count)
            }
          } else {
            Section {
              rows(block.prs, all: block.id == Block.mergedID ? data.recentlyMerged : data.open, viewer: data.viewer)
            } header: {
              SectionHeader(title: block.title, count: block.count)
            }
          }
        }
        if paged.pages > 1 {
          Section {
            PageBar(page: paged.page, pages: paged.pages, range: paged.range, total: paged.total) { page = $0 }
          }
        }
      }
    }
    // A new page starts at its top.
    .id(paged.page)
  }

  /// A section as one page shows it: its rows on this page, and its full count.
  private struct Block {
    static let parkedID = "parked", mergedID = "merged"
    let id: String
    let title: String
    let count: Int
    var prs: [Pr]
  }

  /// Splits the list into pages of `pageSize` rows, in order: the waiting-on groups, Parked (when
  /// open) and merged. A section shows on each page that has some of its rows, with its whole count
  /// in the header; folded Parked shows on the page where it falls.
  private func paginate(_ groups: Groups) -> (blocks: [Block], page: Int, pages: Int, range: Range<Int>, total: Int) {
    var all = groups.sections.map { Block(id: "\($0.waitingOn)", title: $0.waitingOn.title(scope), count: $0.prs.count, prs: $0.prs) }
    if !groups.parked.isEmpty { all.append(Block(id: Block.parkedID, title: "Parked", count: groups.parked.count, prs: groups.parked)) }
    if !groups.merged.isEmpty { all.append(Block(id: Block.mergedID, title: "Merged in the last 7 days", count: groups.merged.count, prs: groups.merged)) }
    let listed = { (block: Block) in block.id == Block.parkedID && !showParked ? [] : block.prs }
    let total = all.map { listed($0).count }.reduce(0, +)
    let pages = max(1, (total + Self.pageSize - 1) / Self.pageSize)
    let current = min(page, pages - 1)
    let range = current * Self.pageSize ..< min((current + 1) * Self.pageSize, total)
    var offset = 0
    var shown: [Block] = []
    for block in all {
      let prs = listed(block)
      let slice = prs.indices.filter { range.contains(offset + $0) }.map { prs[$0] }
      let folded = prs.isEmpty && (range.contains(offset) || (offset == total && current == pages - 1))
      if !slice.isEmpty || folded {
        var block = block
        block.prs = slice
        shown.append(block)
      }
      offset += prs.count
    }
    return (shown, current, pages, range, total)
  }

  private func rows(_ prs: [Pr], all: [Pr], viewer: String) -> some View {
    ForEach(prs) { pr in
      PrRowView(pr: pr, viewer: viewer, stackParent: all.first { $0.number == pr.stackedOn && $0.repo == pr.repo })
        .listRowSeparatorTint(Palette.border)
    }
  }

  private struct Groups {
    var sections: [(waitingOn: WaitingOn, prs: [Pr])] = []
    var parked: [Pr] = []
    var merged: [Pr] = []
    var isEmpty: Bool { sections.isEmpty && merged.isEmpty }
  }

  /// Parked PRs (or PRs of parked tickets) leave the groups and the filter counts; they're listed
  /// at the bottom. A waiting-on filter is about open PRs only, so merged ones show with no filter
  /// or with mismatches.
  private func grouped(_ data: PrsResponse) -> Groups {
    let mismatchesOnly = filter == .mismatches
    let updatedOnly = filter == .updated
    let anyWaiting = mismatchesOnly || updatedOnly
    let visible = { (prs: [Pr]) in
      prs.filter {
        (!mismatchesOnly || !$0.mismatches.isEmpty) && (!updatedOnly || !store.changes($0, viewer: data.viewer).isEmpty) && matches($0)
      }
    }
    let open = visible(data.open.filter { store.parked(for: $0) == nil })
    var groups = Groups()
    groups.sections = WaitingOn.allCases
      .filter { filter == nil || anyWaiting || filter == .waitingOn($0) }
      .map { waitingOn in (waitingOn, open.filter { $0.waitingOn == waitingOn }) }
      .filter { !$0.prs.isEmpty }
    groups.parked = filter == nil ? data.open.filter { store.parked(for: $0) != nil && matches($0) } : []
    groups.merged = filter == nil || anyWaiting ? visible(data.recentlyMerged) : []
    return groups
  }

  private func matches(_ pr: Pr) -> Bool {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
    return [pr.title, pr.author, pr.repo, pr.headRef].contains { $0.localizedCaseInsensitiveContains(query) }
      || pr.ticketKeys.contains { $0.localizedCaseInsensitiveContains(query) }
      || String(pr.number) == number
  }

  @ViewBuilder
  private func placeholder(_ data: PrsResponse?) -> some View {
    if data == nil, model.errors[scope] == nil {
      VStack(spacing: 0) {
        ForEach(0 ..< 6, id: \.self) { index in
          if index > 0 { Divider().overlay(Palette.border) }
          SkeletonRow(seed: index)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 20).padding(.top, 12)
      .accessibilityLabel("Loading pull requests")
    } else if let data, grouped(data).isEmpty, model.errors[scope] == nil {
      if !search.isEmpty {
        ContentUnavailableView.search(text: search)
      } else {
        ContentUnavailableView(
          filter == .mismatches ? "No Mismatches" : filter == nil ? "No Open Pull Requests" : "Nothing Here",
          systemImage: "arrow.triangle.pull",
          description: Text(filter.map { "Nothing in \(title($0).lowercased())." } ?? "Your open pull requests show up here.")
        )
      }
    }
  }

  // MARK: Filter bar

  /// Whose PRs (Mine, Reviewing, Team), then the web version's summary cards as a row of glass
  /// filter buttons. Clicking the active filter clears it. The scope switch shows before anything
  /// loads, so a scope that failed can be left.
  private func topBar(_ data: PrsResponse?) -> some View {
    let active = data?.open.filter { store.parked(for: $0) == nil } ?? []
    let mismatches = (active + (data?.recentlyMerged ?? [])).filter { !$0.mismatches.isEmpty }.count
    let updated = scope == .team ? 0 : (active + (data?.recentlyMerged ?? [])).filter { !store.changes($0, viewer: data?.viewer ?? "").isEmpty }.count
    return ScrollView(.horizontal, showsIndicators: false) {
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          Picker("Scope", selection: $scope) {
            ForEach(PrScope.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .controlSize(.large)
          .fixedSize()
          .padding(.trailing, 6)
          if data != nil {
            ForEach(WaitingOn.allCases, id: \.self) { waitingOn in
              FilterButton(
                count: active.filter { $0.waitingOn == waitingOn }.count, label: waitingOn.title(scope),
                isOn: filter == .waitingOn(waitingOn)
              ) { toggle(.waitingOn(waitingOn)) }
            }
            FilterButton(count: mismatches, label: "Ticket mismatches", isOn: filter == .mismatches, warn: true) {
              toggle(.mismatches)
            }
            if scope != .team {
              FilterButton(count: updated, label: "Updated", isOn: filter == .updated) { toggle(.updated) }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
    }
  }

  private func toggle(_ next: Filter) {
    withAnimation(.snappy) { filter = filter == next ? nil : next }
  }

  private func title(_ filter: Filter) -> String {
    switch filter {
    case let .waitingOn(waitingOn): waitingOn.title(scope)
    case .mismatches: "Ticket mismatches"
    case .updated: "Updated"
    }
  }

  // MARK: Toolbar and menus

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.load(scope, settings: settings) }
      }
      .clickable()
      .keyboardShortcut("r")
      .disabled(model.loading.contains(scope))
    }
  }

  private func subtitle(_ data: PrsResponse?) -> String {
    if model.loading.contains(scope) { return "Updating…" }
    guard let fetchedAt = data?.fetchedAt else { return "" }
    return "Updated at \(fetchedAt.formatted(date: .omitted, time: .shortened))"
  }

  private func prs(_ ids: Set<Pr.ID>, in data: PrsResponse?) -> [Pr] {
    guard let data else { return [] }
    return (data.open + data.recentlyMerged).filter { ids.contains($0.id) }
  }

  @ViewBuilder
  private func menu(for prs: [Pr]) -> some View {
    if !prs.isEmpty {
      if prs.count == 1, let pr = prs.first {
        Button("Open Details") { navigation.open(PrKey(pr)) }
      }
      Button(prs.count == 1 ? "Open on GitHub" : "Open \(prs.count) on GitHub") {
        for pr in prs { NSWorkspace.shared.open(URL(string: pr.url)!) }
      }
      if prs.count == 1, let pr = prs.first {
        if let ticket = pr.tickets.first {
          Button("Open \(ticket.key) in Linear") { NSWorkspace.shared.open(URL(string: ticket.url)!) }
        }
      }
      if let viewer = model.responses[scope]?.viewer, prs.contains(where: { !store.changes($0, viewer: viewer).isEmpty }) {
        Button("Mark as Seen") { for pr in prs { store.markSeen(pr, viewer: viewer) } }
      }
      Button(prs.count == 1 ? "Copy Link" : "Copy Links") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prs.map(\.url).joined(separator: "\n"), forType: .string)
      }
      if prs.count == 1, let pr = prs.first {
        Divider()
        let ref = pr.tickets.first.map { ticketRef($0.key) } ?? prRef(pr.repo, pr.number)
        if store.pins.contains(where: { $0.ref == ref }) {
          Button("Unpin") { store.unpin(ref) }
        } else {
          Button("Pin to Focus") {
            store.pin(ref, title: pr.tickets.first.map { "\($0.key) \($0.title)" } ?? pr.title, url: pr.tickets.first?.url ?? pr.url)
          }
        }
        if let parked = store.parked(for: pr) {
          Button("Unpark") { store.unpark(parked.ref) }
        }
      }
    }
  }
}

extension WaitingOn {
  func title(_ scope: PrScope) -> String {
    switch self {
    case .you: scope == .mine ? "Needs you" : "Waiting on author"
    case .merge: "Ready to merge"
    case .ci: "Waiting on CI"
    case .reviewer: "Waiting on review"
    case .draft: "Drafts"
    }
  }
}

/// A waiting-on filter as a native glass capsule. The glass is set directly rather than through
/// a glass button style, which tints with the app's accent: unselected ones are tinted with the
/// card colour, and only the selected one takes the accent, with white text.
private struct FilterButton: View {
  let count: Int
  let label: String
  let isOn: Bool
  var warn = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text("\(count)")
          .monospacedDigit()
          .fontWeight(.semibold)
          .foregroundStyle(countStyle)
        Text(label).foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .glassEffect(isOn ? .regular.tint(.workbenchAccent).interactive() : .regular.tint(Palette.card.opacity(0.7)).interactive(), in: .capsule)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private var countStyle: AnyShapeStyle {
    if isOn { return AnyShapeStyle(Color.white) }
    if count == 0 { return AnyShapeStyle(.tertiary) }
    return warn ? AnyShapeStyle(Tone.warn.color) : AnyShapeStyle(.primary)
  }
}

/// Previous and next page, and where you are.
private struct PageBar: View {
  let page: Int
  let pages: Int
  let range: Range<Int>
  let total: Int
  let go: (Int) -> Void

  var body: some View {
    HStack {
      Button("Previous", systemImage: "chevron.left") { go(page - 1) }
        .disabled(page == 0)
        .clickable()
      Spacer()
      Text("\(range.lowerBound + 1)–\(range.upperBound) of \(total) · page \(page + 1) of \(pages)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Spacer()
      Button { go(page + 1) } label: { Label("Next", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle()) }
        .disabled(page == pages - 1)
        .clickable()
    }
    .buttonStyle(.pill)
    .padding(.vertical, 6)
  }
}

/// Title, then icon: "Next ›".
private struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.title
      configuration.icon.imageScale(.small)
    }
  }
}

private struct SectionHeader: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
      Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
    }
  }
}
