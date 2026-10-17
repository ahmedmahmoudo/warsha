import Foundation
import Testing
@testable import Workbench

/// Builds Activity natively and fetches it from the running web version, for this week, last week,
/// this month and today, and compares them. Live data, so it only runs when asked:
///   WORKBENCH_PARITY=1 swift test --package-path macos --filter ActivityParity
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_PARITY"] == "1"))
struct ActivityParityTests {
  private static let zone = "Australia/Sydney"

  static var cases: [(ActivitySpan, String)] {
    let today = TodayRules.localDate(Date(), zone)
    return [(.week, today), (.week, TodayRules.addDays(today, -7)), (.month, today), (.day, today), (.day, TodayRules.addDays(today, -2))]
  }

  @Test(arguments: [0, 1, 2, 3, 4])
  func matchesTheWebVersion(index: Int) async throws {
    let (span, date) = Self.cases[index]
    var env: [String: String] = [:]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
    for line in try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8).split(whereSeparator: \.isNewline)
    where !line.hasPrefix("#") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      env[String(line[..<equals])] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    let config = PrConfig(githubToken: env["GITHUB_TOKEN"] ?? "", linearApiKey: env["LINEAR_API_KEY"] ?? "", githubRepos: [], githubTeam: [])

    async let native = ActivityService.shared.build(ActivityRange(span, date: date, timeZone: Self.zone), config: config)
    async let webData = URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:5180/api/activity?view=\(span.rawValue)&date=\(date)&tz=\(Self.zone)&fresh=1")!
    )
    let ours = try await native
    let web = try JSONSerialization.jsonObject(with: try await webData.0) as! [String: Any]
    func list(_ value: Any?) -> [[String: Any]] { (value as? [[String: Any]]) ?? [] }
    func str(_ value: Any?) -> String { (value as? String) ?? "-" }

    let totals = web["totals"] as! [String: Any]
    let compare: [(String, String, String)] = [
      ("totals",
       "\(ours.totals.prsOpened) \(ours.totals.prsMerged) \(ours.totals.prsReviewed) \(ours.totals.ticketsCompleted) \(ours.totals.pushes.map(String.init) ?? "-")",
       "\(totals["prsOpened"]!) \(totals["prsMerged"]!) \(totals["prsReviewed"]!) \(totals["ticketsCompleted"]!) \((totals["pushes"] as? Int).map(String.init) ?? "-")"),
      ("dayByDay", ours.dayByDay.rawValue, str(web["dayByDay"])),
      ("days",
       ours.days.map { day in
         "\(day.date) detailed \(day.detailed)\n"
           + day.groups.map { group in
             "  [\(group.key)] \(group.ticket?.key ?? "-") \(group.title)\n"
               + group.entries.map { "    \($0.kind.rawValue) \($0.at) \($0.text) \($0.url ?? "-")" }.joined(separator: "\n")
           }.joined(separator: "\n")
           + day.reviews.map { "\n  review \($0.entry.kind.rawValue) \($0.entry.text) \($0.entry.url ?? "-")" }.joined()
       }.joined(separator: "\n"),
       list(web["days"]).map { day in
         "\(day["date"]!) detailed \((day["detailed"] as! Bool))\n"
           + list(day["groups"]).map { group in
             "  [\(group["key"]!)] \(str((group["ticket"] as? [String: Any])?["key"])) \(group["title"]!)\n"
               + list(group["entries"]).map { "    \($0["kind"]!) \($0["at"]!) \($0["text"]!) \(str($0["url"]))" }.joined(separator: "\n")
           }.joined(separator: "\n")
           + list(day["reviews"]).map { "\n  review \($0["kind"]!) \($0["text"]!) \(str($0["url"]))" }.joined()
       }.joined(separator: "\n")),
      ("shipped", ours.shipped.map { "\($0.pr.url) \($0.ticketLagging)" }.joined(separator: ","),
       list(web["shipped"]).map { "\($0["url"]!) \(($0["ticketLagging"] as! Bool))" }.joined(separator: ",")),
      ("opened", ours.opened.map(\.url).joined(separator: ","), list(web["opened"]).map { str($0["url"]) }.joined(separator: ",")),
      ("reviewsGiven",
       ours.reviewsGiven.map { "\($0.pr.url): \($0.reviews.map { "\($0.state) \($0.at) \($0.comments)" }.joined(separator: "; "))" }.joined(separator: "\n"),
       list(web["reviewsGiven"]).map { given in
         "\(str((given["pr"] as? [String: Any])?["url"])): \(list(given["reviews"]).map { "\($0["state"]!) \($0["at"]!) \($0["comments"]!)" }.joined(separator: "; "))"
       }.joined(separator: "\n")),
      ("tickets",
       ours.tickets.map { "\($0.ticket.key) created \($0.created): \($0.transitions.map { "\($0.at) \($0.from ?? "-")→\($0.to)" }.joined(separator: ", "))" }.joined(separator: "\n"),
       list(web["tickets"]).map { activity in
         "\(str((activity["ticket"] as? [String: Any])?["key"])) created \((activity["created"] as! Bool)): \(list(activity["transitions"]).map { "\($0["at"]!) \(str($0["from"]))→\($0["to"]!)" }.joined(separator: ", "))"
       }.joined(separator: "\n")),
      ("ticketCards",
       ours.ticketCards.keys.sorted().map { key in "\(key): " + ours.ticketCards[key]!.map { "\($0.pr.url) \($0.status?.label ?? "-")" }.joined(separator: ", ") }.joined(separator: "\n"),
       ((web["ticketCards"] as? [String: Any]) ?? [:]).keys.sorted().map { key in
         "\(key): " + list(((web["ticketCards"] as! [String: Any])[key] as! [String: Any])["prs"]).map {
           "\($0["url"]!) \(str(($0["status"] as? [String: Any])?["label"]))"
         }.joined(separator: ", ")
       }.joined(separator: "\n")),
      ("ticketAges",
       ours.ticketAges.keys.sorted().map { "\($0): \(ours.ticketAges[$0]!.level.rawValue) \(ours.ticketAges[$0]!.message ?? "-")" }.joined(separator: "\n"),
       ((web["ticketAges"] as? [String: [String: Any]]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value["level"]!) \(str($0.value["message"]))" }
         .joined(separator: "\n")),
    ]
    var differences: [String] = []
    for (field, native, web) in compare where native != web {
      differences.append("\(field):\n--- native\n\(native)\n--- web\n\(web)")
    }
    print("[activity \(span.rawValue) \(date)] \(ours.days.count) days, \(ours.days.flatMap(\.groups).count) groups, \(ours.shipped.count) shipped, \(ours.reviewsGiven.count) reviewed, \(ours.tickets.count) tickets moved, \(ours.ticketCards.count) cards, \(ours.ticketAges.count) ages")
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n\n"))")
  }
}

struct ActivityDatesTests {
  @Test func labelsFollowTheRegion() {
    Formats.locale = Locale(identifier: "en_AU")
    // As Foundation writes them for Australia.
    #expect(ActivityDates.label(.day, "2026-10-17", "2026-10-17") == "Sat, 17 Oct 2026")
    #expect(ActivityDates.label(.week, "2026-10-12", "2026-10-18") == "12 Oct – 18 Oct 2026")
    #expect(ActivityDates.label(.week, "2026-09-28", "2026-10-04") == "28 Sep – 4 Oct 2026")
    #expect(ActivityDates.label(.month, "2026-10-01", "2026-10-31") == "October 2026")
  }

  @Test func rangesRunMondayToSunday() {
    let week = ActivityRange(.week, date: "2026-10-17", timeZone: "Australia/Sydney")
    #expect(week.start == "2026-10-12" && week.end == "2026-10-18")
    let month = ActivityRange(.month, date: "2026-02-10", timeZone: "Australia/Sydney")
    #expect(month.start == "2026-02-01" && month.end == "2026-02-28")
    #expect(ActivityDates.monthGrid("2026-10-01", "2026-10-31").count == 5)
  }
}
