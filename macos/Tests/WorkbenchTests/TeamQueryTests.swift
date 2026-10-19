import Testing
@testable import Workbench

struct TeamQueryTests {
  private func config(repos: [String], teams: [String]) -> PrConfig {
    PrConfig(githubToken: "t", linearApiKey: "", githubRepos: repos, githubTeam: teams)
  }

  @Test func noTeamChosenIsEveryoneInYourReposButYou() throws {
    let queries = try PrService.searchQueries(.team, login: "me", config: config(repos: ["o/a", "o/b"], teams: []))
    #expect(queries.open == ["is:pr is:open archived:false -author:me -author:app/dependabot -author:app/renovate repo:o/a repo:o/b"])
  }

  @Test func teamNeedsRepos() {
    #expect(throws: NotConfigured.self) { try PrService.searchQueries(.team, login: "me", config: config(repos: [], teams: ["o/devs"])) }
  }

  @Test func chosenTeamsAreTheirMembersSplitToFitGitHubsLimit() throws {
    let members = (1 ... 40).map { "member-number-\($0)" } + ["me"]
    let queries = try PrService.searchQueries(.team, login: "me", config: config(repos: ["o/a"], teams: ["o/devs"]), teamMembers: members)
    #expect(queries.open.count > 1)
    #expect(queries.open.allSatisfy { $0.count <= 256 && $0.hasPrefix("is:pr is:open archived:false repo:o/a author:") })
    let authors = queries.open.flatMap { $0.split(separator: " ").filter { $0.hasPrefix("author:") } }
    #expect(authors.count == 40)
    #expect(!authors.contains("author:me"))
  }

  @Test func reposOrgsAreTheirOwnersOnce() {
    #expect(repoOrgs(["Org/a", "org/b", "me/c"]) == ["Org", "me"])
  }
}
