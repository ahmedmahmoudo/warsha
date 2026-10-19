import SwiftUI

/// The window's sidebar, laid out like Claude's: the pages at the top, the PRs you've opened below
/// (each a row you can close, reorder or copy), and your profile at the bottom. The selected row
/// gets a soft fill rather than the accent, so the sidebar stays quiet.
struct Sidebar: View {
  @Environment(Navigation.self) private var navigation
  @Environment(PullRequestsModel.self) private var pullRequests
  @Environment(Store.self) private var store

  static let width: CGFloat = 236

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Page.allCases) { page in
            SidebarRow(selected: navigation.selectedPage == page, action: { navigation.show(page) }) {
              Image(systemName: page.symbol).frame(width: 18)
              Text(page.title)
              Spacer(minLength: 4)
              if page == .pullRequests, let count = needsYou, count > 0 {
                Text("\(count)").monospacedDigit().foregroundStyle(Tone.warn.color).help("\(count) of your PRs need you")
              }
            }
            .keyboardShortcutHint(page.shortcut)
          }
          if !navigation.tabs.isEmpty {
            OpenSection()
              .padding(.top, 18)
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 12)
      }
      .scrollIndicators(.never)
      ProfileFooter()
    }
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }

  private var needsYou: Int? {
    pullRequests.responses[.mine] == nil ? nil : pullRequests.needsYou(store: store)
  }
}

/// A sidebar row: soft fill when selected, a lighter one on hover.
struct SidebarRow<Content: View>: View {
  let selected: Bool
  let action: () -> Void
  @ViewBuilder let content: Content
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) { content }
        .scaledFont(.callout)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          selected ? Palette.sidebarSelection : hovering ? Palette.sidebarSelection.opacity(0.55) : .clear,
          in: .rect(cornerRadius: 8)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .clickable()
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// The PRs you've opened, newest where you opened them, like Claude's sessions under a project.
private struct OpenSection: View {
  @Environment(Navigation.self) private var navigation
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack {
        Text("Open").scaledFont(.caption).foregroundStyle(.tertiary)
        Spacer()
        Button { navigation.closeAll() } label: { Image(systemName: "xmark").scaledFont(.caption2.weight(.semibold)) }
          .buttonStyle(.plain).foregroundStyle(.tertiary).clickable()
          .opacity(hovering ? 1 : 0)
          .help("Close all")
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 4)
      .contentShape(.rect)
      .onHover { hovering = $0 }
      ForEach(navigation.tabs, id: \.self) { OpenPrRow(key: $0) }
    }
  }
}

private struct OpenPrRow: View {
  let key: PrKey
  @Environment(Navigation.self) private var navigation
  @Environment(PullRequestsModel.self) private var pullRequests
  @Environment(\.openURL) private var openURL
  @State private var hovering = false

  var body: some View {
    let pr = pr
    SidebarRow(selected: navigation.openTab == key, action: { navigation.open(key) }) {
      Text(pr?.title ?? key.repo).truncationMode(.tail)
      Spacer(minLength: 4)
      if hovering {
        Button { navigation.close(key) } label: {
          Image(systemName: "xmark").scaledFont(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 14, height: 14).contentShape(.rect)
        }
        .buttonStyle(.plain).clickable()
        .help("Close (⌘W)")
      } else {
        Text("#\(String(key.number))").monospacedDigit().scaledFont(.caption).foregroundStyle(.tertiary)
        Circle().fill(pr?.status.tone.color ?? Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
      }
    }
    .onHover { hovering = $0 }
    .help("\(key.repo)#\(key.number)\(pr.map { " · \($0.status.label)\n\($0.title)" } ?? "")")
    .contextMenu {
      Button("Copy Link") { copyToPasteboard(key.url) }
      Button("Open on GitHub") { openURL(URL(string: key.url)!) }
      Divider()
      Button("Close") { navigation.close(key) }
      Button("Close Others") { navigation.closeOthers(key) }
      Button("Close All") { navigation.closeAll() }
    }
    .draggable("\(key.repo)#\(key.number)")
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first, let match = item.wholeMatch(of: /(.+)#(\d+)/), let number = Int(match.2) else { return false }
      navigation.move(PrKey(repo: String(match.1), number: number), before: key)
      return true
    }
  }

  /// What's known about the PR: its details page if it's loaded, else its row in a list.
  private var pr: Pr? {
    if let pr = AppState.shared.prDetails.existing(key)?.detail?.pr { return pr }
    return pullRequests.responses.values.lazy.flatMap { $0.open + $0.recentlyMerged }
      .first { $0.repo == key.repo && $0.number == key.number }
  }
}

/// Who you are and which profile, at the foot of the sidebar: click to switch profile; the gear
/// opens Settings.
private struct ProfileFooter: View {
  @Environment(AppState.self) private var state
  @Environment(PullRequestsModel.self) private var pullRequests
  @State private var naming = false

  var body: some View {
    let login = pullRequests.responses.values.first?.viewer
    HStack(spacing: 8) {
      Menu {
        ProfileMenuItems(naming: $naming)
      } label: {
        HStack(spacing: 8) {
          Text(initials(login ?? state.profile.name))
            .scaledFont(.caption2.weight(.semibold))
            .frame(width: 22, height: 22)
            .background(Palette.sidebarSelection, in: .circle)
          Text(login ?? state.profile.name).scaledFont(.callout).lineLimit(1)
          if login != nil {
            Text("· \(state.profile.name)").scaledFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
          }
          Image(systemName: "chevron.down").scaledFont(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .clickable()
      .help("Switch profile")
      Spacer(minLength: 4)
      SettingsLink { Image(systemName: "gearshape").scaledFont(.callout).foregroundStyle(.secondary) }
        .buttonStyle(.plain).clickable().help("Settings (⌘,)")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    .sheet(isPresented: $naming) { NewProfileSheet() }
  }

  private func initials(_ name: String) -> String {
    let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    let letters = parts.count > 1 ? [parts[0].first, parts[1].first] : [name.first, name.dropFirst().first]
    return String(letters.compactMap { $0 }).uppercased()
  }
}

private extension View {
  /// Shows the page's shortcut on hover, as the row's help.
  func keyboardShortcutHint(_ key: KeyEquivalent) -> some View {
    help("⌘\(key.character)")
  }
}
