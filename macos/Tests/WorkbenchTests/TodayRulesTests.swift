import Foundation
import Testing
@testable import Workbench

struct TodayRulesTests {
  @Test func parkCommentMatchesTheWebVersion() {
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
}
