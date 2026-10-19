import SwiftUI

/// A GitHub team in the organization that owns one of your repos.
struct OrgTeam: Identifiable, Equatable, Sendable {
  let org: String
  let slug: String
  let name: String
  let members: Int
  /// You're on it.
  let mine: Bool
  /// How it's saved in Settings → Accounts → Team: "org/slug".
  var id: String { "\(org)/\(slug)" }
}

extension GitHub {
  /// Every team in the organizations among `owners` (a personal account has none), yours marked.
  static func teams(ofOwners owners: [String], token: String) async throws -> [OrgTeam] {
    guard !owners.isEmpty else { return [] }
    let login = try await viewer(token: token)
    struct Owner: Decodable {
      struct Team: Decodable { struct Count: Decodable { let totalCount: Int }; let slug: String; let name: String; let members: Count }
      struct Mine: Decodable { let slug: String }
      let login: String?
      let all: Nodes<Team>?
      let mine: Nodes<Mine>?
    }
    let definitions = (owners.indices.map { "$o\($0): String!" } + ["$me: [String!]"]).joined(separator: ", ")
    let selections = owners.indices.map { index in
      """
      o\(index): repositoryOwner(login: $o\(index)) { ... on Organization {
        login all: teams(first: 100, orderBy: { field: NAME, direction: ASC }) { nodes { slug name members { totalCount } } }
        mine: teams(first: 100, userLogins: $me) { nodes { slug } }
      } }
      """
    }.joined(separator: "\n")
    var variables: [String: any Sendable] = ["me": [login]]
    for (index, owner) in owners.enumerated() { variables["o\(index)"] = owner }
    let result = try await graphql("query OrgTeams(\(definitions)) {\n\(selections)\n}", variables: variables, token: token, as: [String: Owner?].self)
    return owners.indices.flatMap { index -> [OrgTeam] in
      guard let owner = result["o\(index)"] ?? nil, let org = owner.login else { return [] }
      let mine = Set((owner.mine?.nodes ?? []).map(\.slug))
      return (owner.all?.nodes ?? []).map { OrgTeam(org: org, slug: $0.slug, name: $0.name, members: $0.members.totalCount, mine: mine.contains($0.slug)) }
    }
  }
}

/// The organizations that own the repos you follow: where Team's teams come from.
func repoOrgs(_ repos: [String]) -> [String] {
  var owners: [String] = []
  for repo in repos {
    guard let owner = repo.split(separator: "/").first.map(String.init), !owners.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else { continue }
    owners.append(owner)
  }
  return owners
}

/// Whose PRs the Team view follows: GitHub teams from the organizations that own your repos, or no
/// team ticked for everyone in those repos. With no teams there (personal repos, or none chosen),
/// Team is off and this says why. Writes Settings → Accounts → Team as "org/slug" values.
struct TeamPicker: View {
  @Environment(AppSettings.self) private var settings
  @Environment(PullRequestsModel.self) private var model
  /// Ticks your own teams when none is chosen yet, as on Get started.
  var preselect = false
  var listHeight: CGFloat = 220

  private var chosen: [String] { AppSettings.list(settings.githubTeam) }
  private var repos: [String] { AppSettings.list(settings.githubRepos) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Group {
        if let error = model.teamOptionsError {
          message(error, tone: .bad)
        } else if repos.isEmpty {
          message("Team needs your repos chosen first: its teams come from the organizations that own them.", tone: .warn)
        } else if let teams = model.teamOptions {
          if teams.isEmpty {
            message("None of the organizations that own your repos (\(repoOrgs(repos).joined(separator: ", "))) has GitHub teams, so Team is off.", tone: .warn)
          } else {
            list(teams)
          }
        } else {
          VStack(spacing: 0) { ForEach(0 ..< 3, id: \.self) { SkeletonRow(seed: $0) } }
        }
      }
      .frame(height: listHeight)

      if let teams = model.teamOptions, !teams.isEmpty {
        HStack(spacing: 12) {
          Button("Everyone in My Repos") { settings.githubTeam = "" }
            .buttonStyle(.link).clickable(underline: true)
            .disabled(chosen.isEmpty)
          if teams.contains(where: \.mine) {
            Button("My Teams") { settings.githubTeam = teams.filter(\.mine).map(\.id).joined(separator: ", ") }
              .buttonStyle(.link).clickable(underline: true)
          }
          Spacer()
        }
        .scaledFont(.caption)
        Text(chosen.isEmpty
          ? "With no team ticked, Team shows everyone's PRs in your repos, apart from yours and bots'."
          : "Team shows PRs by the members of these teams, in your repos.")
          .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .task(id: "\(settings.githubCredential)|\(settings.githubRepos)") {
      await model.loadTeamOptions(settings: settings)
      if preselect, chosen.isEmpty, let mine = model.teamOptions?.filter(\.mine), !mine.isEmpty {
        settings.githubTeam = mine.map(\.id).joined(separator: ", ")
      }
    }
  }

  private func message(_ text: String, tone: Tone) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "person.3").scaledFont(.title2).foregroundStyle(.tertiary)
      Text(text).scaledFont(.callout).foregroundStyle(tone == .bad ? Tone.bad.color : .secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.background, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }

  private func list(_ teams: [OrgTeam]) -> some View {
    let orgs = repoOrgs(teams.map(\.id))
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
        ForEach(orgs, id: \.self) { org in
          Section {
            ForEach(teams.filter { $0.org == org }.sorted { ($0.mine ? 0 : 1, $0.name.lowercased()) < ($1.mine ? 0 : 1, $1.name.lowercased()) }) { row($0) }
          } header: {
            if orgs.count > 1 {
              Text(org.uppercased()).scaledFont(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.background)
            }
          }
        }
      }
    }
    .background(Palette.background, in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }

  private func row(_ team: OrgTeam) -> some View {
    let on = chosen.contains { $0.caseInsensitiveCompare(team.id) == .orderedSame }
    return Button { toggle(team, on: on) } label: {
      HStack(spacing: 10) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .scaledFont(.body)
          .foregroundStyle(on ? AnyShapeStyle(Color.workbenchAccent) : AnyShapeStyle(.tertiary))
        Image(systemName: "person.2.fill").scaledFont(.caption).foregroundStyle(.secondary)
        Text(team.name).scaledFont(.callout.weight(.medium)).lineLimit(1)
        if team.mine { Chip(text: "Your team", tone: .good) }
        Spacer(minLength: 8)
        Text("\(team.members) \(team.members == 1 ? "person" : "people")").scaledFont(.caption).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .clickable()
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  private func toggle(_ team: OrgTeam, on: Bool) {
    var next = chosen
    if on { next.removeAll { $0.caseInsensitiveCompare(team.id) == .orderedSame } } else { next.append(team.id) }
    settings.githubTeam = next.joined(separator: ", ")
  }
}

/// Settings → Accounts: what Team follows, with the team picker in a sheet.
struct TeamSetting: View {
  @Environment(AppSettings.self) private var settings
  @Environment(PullRequestsModel.self) private var model
  @State private var open = false

  var body: some View {
    let chosen = AppSettings.list(settings.githubTeam)
    LabeledContent("Team") {
      HStack(spacing: 8) {
        Text(summary(chosen)).foregroundStyle(.secondary).lineLimit(1)
        Button("Choose…") { open = true }.clickable().disabled(!settings.hasGitHub)
      }
    }
    .task(id: "\(settings.githubCredential)|\(settings.githubRepos)") { await model.loadTeamOptions(settings: settings) }
    .sheet(isPresented: $open) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Whose PRs Team shows").scaledFont(.headline)
        TeamPicker(listHeight: 300)
        HStack {
          Spacer()
          Button("Done") { open = false }.keyboardShortcut(.defaultAction).clickable()
        }
      }
      .padding(20)
      .scaledFrame(width: 520)
      .workbenchPage()
    }
  }

  private func summary(_ chosen: [String]) -> String {
    if model.teamOptions?.isEmpty == true || AppSettings.list(settings.githubRepos).isEmpty { return "Off: no teams in your repos' orgs" }
    if chosen.isEmpty { return "Everyone in your repos" }
    let names = chosen.map { id in model.teamOptions?.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name ?? id }
    return names.joined(separator: ", ")
  }
}
