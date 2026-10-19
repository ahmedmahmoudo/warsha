import SwiftUI

/// The open PR tabs, under the toolbar: each with its status, number and title. Click to bring one
/// forward, × or ⌘W to close it, drag to reorder; the context menu copies its link.
struct PrTabStrip: View {
  @Environment(Navigation.self) private var navigation
  @Environment(PullRequestsModel.self) private var pullRequests

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(navigation.tabs, id: \.self) { key in
            PrTab(key: key, pr: pr(key), selected: navigation.openTab == key).id(key)
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
      }
      .onChange(of: navigation.openTab) { _, tab in
        if let tab { withAnimation(.snappy) { proxy.scrollTo(tab) } }
      }
    }
    .background(Palette.background)
  }

  /// What's known about the PR: its details page if it's loaded, else its row in a list.
  private func pr(_ key: PrKey) -> Pr? {
    if let pr = AppState.shared.prDetails.existing(key)?.detail?.pr { return pr }
    return pullRequests.responses.values.lazy
      .flatMap { $0.open + $0.recentlyMerged }
      .first { $0.repo == key.repo && $0.number == key.number }
  }
}

private struct PrTab: View {
  let key: PrKey
  let pr: Pr?
  let selected: Bool
  @Environment(Navigation.self) private var navigation
  @Environment(\.openURL) private var openURL
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(pr?.status.tone.color ?? Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
      Text("#\(String(key.number))").monospacedDigit().foregroundStyle(.tertiary)
      Text(pr?.title ?? key.repo).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      Button { navigation.close(key) } label: {
        Image(systemName: "xmark").scaledFont(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          .frame(width: 14, height: 14).contentShape(.rect)
      }
      .buttonStyle(.plain)
      .clickable()
      .opacity(hovering || selected ? 1 : 0)
      .help("Close Tab (⌘W)")
      .accessibilityLabel("Close #\(key.number)")
    }
    .scaledFont(.caption)
    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
    .frame(maxWidth: 240, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
    .background(selected ? Palette.fill : hovering ? Palette.fill.opacity(0.5) : .clear, in: .rect(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Palette.border : .clear))
    .contentShape(.rect)
    .onHover { hovering = $0 }
    .onTapGesture { navigation.open(key) }
    .help("\(key.repo)#\(key.number)\(pr.map { " · \($0.title)" } ?? "")")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .contextMenu {
      Button("Copy Link") { copyToPasteboard(key.url) }
      Button("Open on GitHub") { openURL(URL(string: key.url)!) }
      Divider()
      Button("Close Tab") { navigation.close(key) }
      Button("Close Other Tabs") { navigation.closeOthers(key) }
      Button("Close All Tabs") { navigation.closeAll() }
    }
    .draggable("\(key.repo)#\(key.number)")
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first, let match = item.wholeMatch(of: /(.+)#(\d+)/), let number = Int(match.2) else { return false }
      navigation.move(PrKey(repo: String(match.1), number: number), before: key)
      return true
    }
  }
}
