import Foundation
import Testing
@testable import Warsha

struct TodayRulesTests {
  @Test func parkCommentReadsWell() {
    Formats.locale = Locale(identifier: "en_AU")
    // From shared/store.ts parkComment("  waiting on design ", "2026-10-20").
    #expect(parkComment("  waiting on design ", until: "2026-10-20") == "Parked: waiting on design\n\nPicking this back up on Tue, 20 Oct.")
    #expect(parkComment("blocked", until: nil) == "Parked: blocked")
  }

  @Test func countsWorkingDaysInTheZone() {
    let friday = TodayRules.parseInstant("2026-10-16T02:00:00Z")!
    // In review since Monday morning Sydney time: Tue, Wed, Thu, Fri.
    #expect(TodayRules.workingDaysSince("2026-10-11T22:00:00Z", timeZone: "Australia/Sydney", now: friday) == 4)
    // The weekend doesn't count.
    let monday = TodayRules.parseInstant("2026-10-19T02:00:00Z")!
    #expect(TodayRules.workingDaysSince("2026-10-15T22:00:00Z", timeZone: "Australia/Sydney", now: monday) == 1)
  }

  @Test func reviewAgesFasterThanProgress() {
    let ticket = { (state: String) in Ticket(key: "MX-1", title: "T", url: "u", state: state, stateType: "started", stateColor: "#000", assignee: nil, project: nil) }
    let now = TodayRules.parseInstant("2026-10-16T02:00:00Z")!
    let since = "2026-10-11T22:00:00Z"
    #expect(TodayRules.ticketAge(ticket("In Review"), since: since, timeZone: "Australia/Sydney", now: now)?.level == .warn)
    #expect(TodayRules.ticketAge(ticket("In Progress"), since: since, timeZone: "Australia/Sydney", now: now)?.level == .warn)
    #expect(TodayRules.ticketAge(ticket("Merged"), since: since, timeZone: "Australia/Sydney", now: now) == nil)
  }

  @Test func snippetsFlattenMarkdown() {
    #expect(TodayRules.snippet("**Hey** [@ahmed](https://x) see `code`\n\n> quoted") == "Hey @ahmed see code quoted")
    #expect(TodayRules.snippet("   ") == nil)
  }

  @Test func newPrsAreSentForReviewNotNudged() throws {
    let raw = try JSONDecoder().decode(GithubPr.self, from: JSONSerialization.data(withJSONObject: [
      "id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/o/r/pull/7", "body": "", "isDraft": false,
      "createdAt": "2026-10-17T00:00:00Z", "updatedAt": "2026-10-17T00:00:00Z", "mergedAt": NSNull(), "headRefName": "b",
      "baseRefName": "main", "additions": 1, "deletions": 1, "mergeStateStatus": "BLOCKED", "reviewDecision": NSNull(),
      "author": ["login": "me", "avatarUrl": "a"], "repository": ["nameWithOwner": "o/r"],
      "baseRef": ["rules": ["nodes": [["type": "PULL_REQUEST", "repositoryRuleset": ["id": "x"], "parameters": ["requiredApprovingReviewCount": 1]]]], "branchProtectionRule": NSNull()],
      "files": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []],
      "commits": ["nodes": []], "reviewThreads": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviewRequests": ["nodes": []],
    ] as [String: Any]))
    let pr = Derive.pr(raw, tickets: nil)
    #expect(pr.waitingOn == .reviewer)
    let hoursLater = { (hours: Double) in TodayRules.parseInstant("2026-10-17T00:00:00Z")!.addingTimeInterval(hours * 3600) }
    #expect(TodayRules.sendForReview(pr, now: hoursLater(3), newPrHours: 24)?.kind == .sendForReview)
    #expect(TodayRules.sendForReview(pr, now: hoursLater(30), newPrHours: 24) == nil)
    #expect(TodayRules.sendForReview(pr, now: hoursLater(3), newPrHours: 0) == nil)
  }

  @Test func aPingIsItsLatestMoment() {
    let ping = Ping(sentAt: "2026-10-17T00:00:00.000Z", nudgedAt: "2026-10-18T09:00:00.000Z")
    #expect(ping.last == TodayRules.parseInstant("2026-10-18T09:00:00.000Z"))
    #expect(Ping().last == nil)
  }
}
