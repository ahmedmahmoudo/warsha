import SwiftUI

/// The Pull Requests page: your open PRs grouped by who they're waiting on, with each one's real
/// gate state, plus the last week's merged ones. src/routes/PullRequestsPage.tsx in SwiftUI.
struct PullRequestsView: View {
  /// A filter bar choice: one waiting-on group, or ticket mismatches.
  enum Filter: Hashable {
    case waitingOn(WaitingOn)
    case mismatches
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
          navigation.pullRequestPath.append(PrKey(chosen[0]))
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
      .task(id: scope) {
        filter = nil
        selection = []
        while !Task.isCancelled {
          await model.load(scope, settings: settings, maxAge: .seconds(15))
          try? await Task.sleep(for: PullRequestsModel.refreshInterval)
        }
      }
  }

  // MARK: The list

  private func list(_ data: PrsResponse?) -> some View {
    let groups = data.map(grouped) ?? Groups()
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
        ForEach(groups.sections, id: \.waitingOn) { section in
          Section {
            rows(section.prs, all: data.open, viewer: data.viewer)
          } header: {
            SectionHeader(title: section.waitingOn.title(scope), count: section.prs.count)
          }
        }
        if !groups.parked.isEmpty {
          Section(isExpanded: $showParked) {
            rows(groups.parked, all: data.open, viewer: data.viewer)
          } header: {
            SectionHeader(title: "Parked", count: groups.parked.count)
          }
        }
        if !groups.merged.isEmpty {
          Section {
            rows(groups.merged, all: data.recentlyMerged, viewer: data.viewer)
          } header: {
            SectionHeader(title: "Merged in the last 7 days", count: groups.merged.count)
          }
        }
      }
    }
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
    let visible = { (prs: [Pr]) in prs.filter { (!mismatchesOnly || !$0.mismatches.isEmpty) && matches($0) } }
    let open = visible(data.open.filter { store.parked(for: $0) == nil })
    var groups = Groups()
    groups.sections = WaitingOn.allCases
      .filter { filter == nil || mismatchesOnly || filter == .waitingOn($0) }
      .map { waitingOn in (waitingOn, open.filter { $0.waitingOn == waitingOn }) }
      .filter { !$0.prs.isEmpty }
    groups.parked = filter == nil ? data.open.filter { store.parked(for: $0) != nil && matches($0) } : []
    groups.merged = filter == nil || mismatchesOnly ? visible(data.recentlyMerged) : []
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
      ProgressView("Loading pull requests…")
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
    }
  }

  // MARK: Toolbar and menus

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.load(scope, settings: settings) }
      }
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
        Button("Open Details") { navigation.pullRequestPath.append(PrKey(pr)) }
      }
      Button(prs.count == 1 ? "Open on GitHub" : "Open \(prs.count) on GitHub") {
        for pr in prs { NSWorkspace.shared.open(URL(string: pr.url)!) }
      }
      if prs.count == 1, let pr = prs.first {
        if let ticket = pr.tickets.first {
          Button("Open \(ticket.key) in Linear") { NSWorkspace.shared.open(URL(string: ticket.url)!) }
        }
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
    .glassEffect(isOn ? .regular.tint(.workbenchAccent).interactive() : .regular.tint(Palette.card.opacity(0.7)).interactive(), in: .capsule)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private var countStyle: AnyShapeStyle {
    if isOn { return AnyShapeStyle(Color.white) }
    if count == 0 { return AnyShapeStyle(.tertiary) }
    return warn ? AnyShapeStyle(Tone.warn.color) : AnyShapeStyle(.primary)
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
