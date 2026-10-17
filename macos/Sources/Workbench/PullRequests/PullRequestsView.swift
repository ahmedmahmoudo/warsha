import SwiftUI

/// The Pull Requests page: your open PRs grouped by who they're waiting on, with each one's real
/// gate state, plus the last week's merged ones. src/routes/PullRequestsPage.tsx in SwiftUI.
struct PullRequestsView: View {
  /// A summary card's filter: one waiting-on group, or ticket mismatches.
  enum Filter: Hashable {
    case waitingOn(WaitingOn)
    case mismatches
  }

  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @State private var model = PullRequestsModel()
  @AppStorage("prScope") private var scope: PrScope = .mine
  @State private var filter: Filter?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        content
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Pull Requests")
    .toolbar { toolbar }
    .task(id: scope) {
      filter = nil
      while !Task.isCancelled {
        await model.load(scope, settings: settings)
        try? await Task.sleep(for: PullRequestsModel.refreshInterval)
      }
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Scope", selection: $scope) {
        ForEach(PrScope.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
    }
    ToolbarItemGroup {
      if model.loading.contains(scope) {
        ProgressView().controlSize(.small)
      } else if let fetchedAt = model.responses[scope]?.fetchedAt {
        Text("Updated \(fetchedAt, format: .relative(presentation: .named))")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.load(scope, settings: settings) }
      }
      .keyboardShortcut("r")
      .disabled(model.loading.contains(scope))
    }
  }

  @ViewBuilder
  private var content: some View {
    if let error = model.errors[scope] {
      Banner(text: error is NotConfigured ? "Setup needed: \(error.localizedDescription)" : error.localizedDescription, tone: .bad)
    }
    if let data = model.responses[scope] {
      loaded(data)
    } else if model.errors[scope] == nil {
      Text("Loading pull requests…").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func loaded(_ data: PrsResponse) -> some View {
    // Parked PRs (or PRs of parked tickets) don't count in the cards; they're listed at the bottom.
    let parkedOpen = data.open.filter { store.parked(for: $0) != nil }
    let activeOpen = data.open.filter { store.parked(for: $0) == nil }
    let mismatchesOnly = filter == .mismatches
    let visible = { (prs: [Pr]) in mismatchesOnly ? prs.filter { !$0.mismatches.isEmpty } : prs }
    let open = visible(activeOpen)
    // A waiting-on card is about open PRs only, so merged ones show with no filter or with mismatches.
    let merged = filter == nil || mismatchesOnly ? visible(data.recentlyMerged) : []
    let sections = WaitingOn.allCases.filter { filter == nil || mismatchesOnly || filter == .waitingOn($0) }

    ForEach(data.warnings, id: \.self) { Banner(text: $0, tone: .warn) }

    HStack(spacing: 8) {
      ForEach(WaitingOn.allCases, id: \.self) { waitingOn in
        SummaryCard(
          count: activeOpen.filter { $0.waitingOn == waitingOn }.count,
          label: waitingOn.title(scope), active: filter == .waitingOn(waitingOn)
        ) { toggle(.waitingOn(waitingOn)) }
      }
      SummaryCard(
        count: (activeOpen + data.recentlyMerged).filter { !$0.mismatches.isEmpty }.count,
        label: "Ticket mismatches", active: mismatchesOnly, tone: .warn
      ) { toggle(.mismatches) }
    }

    if let filter {
      HStack(spacing: 4) {
        Text("Showing \(filter == .mismatches ? "ticket mismatches" : sectionTitle(filter).lowercased()) only ·")
        Button("Show all") { self.filter = nil }.buttonStyle(.link)
      }
      .font(.caption).foregroundStyle(.secondary)
    }

    ForEach(sections, id: \.self) { waitingOn in
      let prs = open.filter { $0.waitingOn == waitingOn }
      if !prs.isEmpty {
        PrSection(title: waitingOn.title(scope), prs: prs, all: data.open, viewer: data.viewer)
      }
    }

    if !open.contains(where: { sections.contains($0.waitingOn) }) {
      Text(
        mismatchesOnly ? "No open PRs with mismatches."
          : filter.map { "Nothing in \(sectionTitle($0).lowercased())." } ?? "No open pull requests."
      )
      .foregroundStyle(.secondary)
    }

    if !parkedOpen.isEmpty && filter == nil {
      DisclosureGroup {
        PrList(prs: parkedOpen, all: data.open, viewer: data.viewer)
      } label: {
        SectionTitle(title: "Parked", count: parkedOpen.count).foregroundStyle(.secondary)
      }
    }

    if !merged.isEmpty {
      PrSection(title: "Merged in the last 7 days", prs: merged, all: data.recentlyMerged, viewer: data.viewer)
    }
  }

  private func sectionTitle(_ filter: Filter) -> String {
    switch filter {
    case let .waitingOn(waitingOn): waitingOn.title(scope)
    case .mismatches: "Ticket mismatches"
    }
  }

  /// Clicking the active card clears the filter.
  private func toggle(_ next: Filter) {
    filter = filter == next ? nil : next
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

private struct SummaryCard: View {
  let count: Int
  let label: String
  let active: Bool
  var tone: Tone = .neutral
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(count)")
          .font(.title2.weight(.semibold)).monospacedDigit()
          .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : tone == .warn ? AnyShapeStyle(Tone.warn.color) : AnyShapeStyle(.primary))
        Text(label).font(.caption).foregroundStyle(.secondary)
      }
      .frame(minWidth: 110, alignment: .leading)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background), in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? .secondary : .quaternary))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

private struct SectionTitle: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(.headline)
      Text("\(count)").foregroundStyle(.tertiary)
    }
  }
}

private struct PrSection: View {
  let title: String
  let prs: [Pr]
  let all: [Pr]
  let viewer: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(title: title, count: prs.count)
      PrList(prs: prs, all: all, viewer: viewer)
    }
  }
}

private struct PrList: View {
  let prs: [Pr]
  let all: [Pr]
  let viewer: String

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(prs.enumerated()), id: \.element.id) { index, pr in
        if index > 0 { Divider() }
        PrRowView(pr: pr, viewer: viewer, stackParent: all.first { $0.number == pr.stackedOn && $0.repo == pr.repo })
      }
    }
    .background(.background, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
  }
}

struct Banner: View {
  let text: String
  let tone: Tone

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(tone.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(tone.color.opacity(0.1), in: .rect(cornerRadius: 8))
      .textSelection(.enabled)
  }
}
