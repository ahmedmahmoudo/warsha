import Foundation
import Testing
@testable import Workbench

struct CodeownersTests {
  @Test func matchesLikeGitHub() {
    let owners = Codeowners(
      """
      # comment
      *.js            @org/web
      /build/         @org/infra
      docs/*          @docs
      apps/**/test    @org/qa   # trailing comment
      apps/legacy/
      """
    )
    #expect(owners.ownersOf("src/deep/app.js") == ["@org/web"])
    #expect(owners.ownersOf("build/out/x.txt") == ["@org/infra"])
    #expect(owners.ownersOf("other/build/x.txt") == [])
    #expect(owners.ownersOf("docs/a.md") == ["@docs"])
    // A trailing "*" doesn't reach into subdirectories.
    #expect(owners.ownersOf("docs/build/b.md") == [])
    #expect(owners.ownersOf("apps/x/y/test/file.ts") == ["@org/qa"])
    #expect(owners.ownersOf("apps/test") == ["@org/qa"])
    // A pattern with no owners removes ownership, and the last match wins.
    #expect(owners.ownersOf("apps/legacy/old.js") == [])
  }
}

struct TicketKeyTests {
  @Test func readsBranchTitleAndLinearLinks() {
    #expect(
      Derive.ticketKeys(
        headRefName: "feature/mx-2473-add-thing-ab-12",
        title: "MX-2473: Add thing (CD-9)",
        body: "Fixes https://linear.app/everlab/issue/EF-77/something and MX-1 in prose"
      ) == ["MX-2473", "CD-9", "EF-77"]
    )
    #expect(Derive.ticketKeys(headRefName: "main", title: "chore", body: "") == [])
  }
}

struct DeriveTests {
  /// A minimal PR in GitHub's GraphQL shape; `overrides` replaces top-level fields.
  private func pr(_ overrides: [String: Any] = [:]) throws -> GithubPr {
    var json: [String: Any] = [
      "id": "PR_1", "number": 1, "title": "MX-1 Thing", "url": "https://github.com/o/r/pull/1", "body": "",
      "isDraft": false, "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "2026-10-02T00:00:00Z", "mergedAt": NSNull(),
      "headRefName": "mx-1-thing", "baseRefName": "main", "additions": 1, "deletions": 1, "mergeStateStatus": "BLOCKED",
      "reviewDecision": NSNull(), "author": ["login": "me", "avatarUrl": "a"], "repository": ["nameWithOwner": "o/r"],
      "baseRef": [
        "rules": ["nodes": [["type": "PULL_REQUEST", "repositoryRuleset": ["id": "rs"], "parameters": ["requiredApprovingReviewCount": 1, "requireCodeOwnerReview": true]]]],
        "branchProtectionRule": NSNull(),
      ],
      "files": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": [["path": "web/app.js"]]],
      "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS", "contexts": ["nodes": [
        ["__typename": "CheckRun", "name": "Required CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": NSNull(), "isRequired": true],
        ["__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": NSNull(), "isRequired": false],
      ]]]]]]],
      "reviewThreads": ["nodes": []],
      "latestOpinionatedReviews": ["nodes": []],
      "reviewRequests": ["nodes": []],
    ]
    for (key, value) in overrides { json[key] = value }
    return try JSONDecoder().decode(GithubPr.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private let review = Derive.ReviewContext(codeowners: Codeowners("*.js @o/web"), files: ["web/app.js"], filesComplete: true, teams: [:])

  @Test func advisoryFailuresDontBlockAndCodeOwnersDo() throws {
    let derived = Derive.pr(try pr(), tickets: nil, review: review)
    #expect(derived.checks.state == .passing)
    #expect(derived.checks.advisoryFailing.map(\.name) == ["lint"])
    #expect(derived.status.label == "Needs code owner")
    #expect(derived.waitingOn == .reviewer)
    #expect(derived.reviewGate?.codeOwners.map { $0.map(\.id) } == [["o/web"]])
    #expect(derived.reviewGate?.approvalsNeeded == 1)
  }

  @Test func anApprovalOnBehalfOfTheTeamClearsIt() throws {
    let approved = try pr(["latestOpinionatedReviews": ["nodes": [
      ["state": "APPROVED", "author": ["login": "pal", "avatarUrl": "b"], "onBehalfOf": ["nodes": [["slug": "web"]]]],
    ]]])
    let derived = Derive.pr(approved, tickets: nil, review: review)
    #expect(derived.reviewGate?.codeOwners.isEmpty == true)
    #expect(derived.status.label == "Ready to merge")
    #expect(derived.waitingOn == .merge)
  }

  @Test func conflictsComeBeforeEverythingButDrafts() throws {
    #expect(Derive.pr(try pr(["mergeStateStatus": "DIRTY"]), tickets: nil, review: review).status.label == "Merge conflicts")
    #expect(Derive.pr(try pr(["mergeStateStatus": "DIRTY", "isDraft": true]), tickets: nil).status.label == "Draft")
  }

  @Test func ticketsThatDontExistAreDropped() throws {
    let ticket = Ticket(key: "MX-1", title: "T", url: "u", state: "Backlog", stateType: "backlog", stateColor: "#999", assignee: nil, project: nil)
    let derived = Derive.pr(try pr(["title": "MX-1 and ZZ-9"]), tickets: ["MX-1": ticket], review: review)
    #expect(derived.ticketKeys == ["MX-1"])
    #expect(derived.mismatches == [.ticketNotStarted])
  }

  @Test func stacksLinkToTheBranchTheyTarget() throws {
    let base = Derive.pr(try pr(["number": 1, "url": "u1", "headRefName": "a"]), tickets: nil)
    let top = Derive.pr(try pr(["number": 2, "url": "u2", "headRefName": "b", "baseRefName": "a"]), tickets: nil)
    #expect(Derive.linkStacks([base, top]).map(\.stackedOn) == [nil, 1])
  }
}
