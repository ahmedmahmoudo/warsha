import Foundation
import Testing
@testable import Warsha

/// Reads a week of events natively and from the running web version, and compares them. Uses the
/// web version's own Google sign-in (its data/warsha.sqlite) and client, so it only runs when asked:
///   WARSHA_PARITY=1 swift test --package-path macos --filter CalendarParity
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WARSHA_PARITY"] == "1"))
struct CalendarParityTests {
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized

  @Test func eventsMatchTheWebVersion() async throws {
    var env: [String: String] = [:]
    for line in try String(contentsOf: Self.root.appendingPathComponent(".env.local"), encoding: .utf8).split(whereSeparator: \.isNewline)
    where !line.hasPrefix("#") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      env[String(line[..<equals])] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    let db = try Database(path: Self.root.appendingPathComponent("data/warsha.sqlite").path)
    let token = try #require(try db.query("select value from settings where key = 'google.refreshToken'").first?.string("value"))
    let client = GoogleCalendar.Client(id: env["GOOGLE_CLIENT_ID"] ?? "", secret: env["GOOGLE_CLIENT_SECRET"] ?? "")

    let today = TodayRules.localDate(Date(), "UTC")
    let start = "\(TodayRules.addDays(today, -1))T00:00:00Z"
    let end = "\(TodayRules.addDays(today, 7))T00:00:00Z"
    async let native = GoogleCalendar.shared.events(from: start, to: end, client: client, refreshToken: token)
    async let webData = URLSession.shared.data(from: URL(string: "http://127.0.0.1:5180/api/calendar/range?start=\(start)&end=\(end)&fresh=1")!)
    let ours = try await native
    let web = (try JSONSerialization.jsonObject(with: try await webData.0) as! [String: Any])["meetings"] as! [[String: Any]]

    func line(_ id: String, _ title: String, _ start: String, _ end: String, _ allDay: Bool, _ join: String?, _ declined: Bool) -> String {
      "\(id) | \(title) | \(start) → \(end) | allDay \(allDay) | \(join ?? "-") | declined \(declined)"
    }
    let nativeLines = ours.map { line($0.id, $0.title, $0.start, $0.end, $0.allDay, $0.joinUrl, $0.response == "declined") }.sorted()
    // The web list adds meetings it saved as deleted; those come from its own database, not Google.
    let fromWeb = web
      .filter { (($0["change"] as? [String: Any])?["kind"] as? String) != "deleted" }
      .map {
        line($0["id"] as! String, $0["title"] as! String, $0["start"] as! String, $0["end"] as! String, $0["allDay"] as! Bool,
             $0["joinUrl"] as? String, $0["declined"] as! Bool)
      }
      .sorted()
    print("[calendar] \(nativeLines.count) native, \(fromWeb.count) web")
    #expect(nativeLines == fromWeb, "native:\n\(nativeLines.joined(separator: "\n"))\n\nweb:\n\(fromWeb.joined(separator: "\n"))")
  }
}

struct CalendarTimeTests {
  @Test func timesFollowTheRegion() {
    Formats.locale = Locale(identifier: "en_AU")
    #expect(CalendarTime.city("Australia/Sydney") == "Sydney")
    // Foundation puts a narrow no-break space before "am".
    #expect(CalendarTime.clock("2026-10-19T23:30:00.000Z", "Australia/Sydney").replacingOccurrences(of: "\u{202F}", with: " ") == "10:30 am")
    #expect(CalendarTime.timeRange(start: "2026-10-20", end: "2026-10-21", allDay: true, zone: "Australia/Sydney", withDay: true) == "Tue, 20 Oct, all day")
  }
}
