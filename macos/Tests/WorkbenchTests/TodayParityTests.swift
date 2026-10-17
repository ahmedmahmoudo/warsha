import Foundation
import Testing
@testable import Workbench

/// Builds Today natively and fetches it from the running web version (the launchd service), and
/// compares them (Send for review is the app's own, so it's off here). Live data, so it only runs when asked:
///   WORKBENCH_PARITY=1 swift test --package-path macos --filter TodayParity
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_PARITY"] == "1"))
struct TodayParityTests {
  @Test func matchesTheWebVersion() async throws {
    let env = try Self.envFile()
    let config = PrConfig(
      githubToken: env["GITHUB_TOKEN"] ?? "", linearApiKey: env["LINEAR_API_KEY"] ?? "",
      githubRepos: AppSettings.list(env["GITHUB_REPOS"] ?? ""), githubTeam: AppSettings.list(env["GITHUB_TEAM"] ?? "")
    )
    async let native = TodayService.shared.build(config: config, timeZone: env["TIMEZONE"] ?? "Australia/Sydney", newPrHours: 0)
    async let webData = URLSession.shared.data(from: URL(string: "http://127.0.0.1:5180/api/today?fresh=1")!)
    let ours = try await native
    let web = try JSONSerialization.jsonObject(with: try await webData.0) as! [String: Any]

    func list(_ key: String) -> [[String: Any]] { web[key] as! [[String: Any]] }
    func string(_ value: Any?) -> String { (value as? String) ?? "-" }
    func people(_ value: Any?) -> String {
      ((value as? [[[String: Any]]]) ?? []).map { group in
        group.map { target in
          let owner = (target["owner"] as! [String: Any])["id"] as! String
          let members = (target["members"] as! [[String: Any]]).map { $0["id"] as! String }
          return "\(owner)[\(members.joined(separator: ","))]"
        }.joined(separator: " or ")
      }.joined(separator: "; ")
    }

    let compare: [(String, String, String)] = [
      ("needsYou",
       ours.needsYou.map { item in
         let action = switch item.action { case let .details(key): "/prs/\(key.repo)/\(key.number)"; case let .web(url): url.absoluteString }
         return "\(item.id) | \(item.tone) | \(item.title) | \(item.detail ?? "-") | \(item.actionLabel) \(action) | \(item.ref)"
       }.joined(separator: "\n"),
       list("needsYou").map { item in
         let action = item["action"] as! [String: Any]
         return "\(item["id"]!) | \(item["tone"]!) | \(item["title"]!) | \(string(item["detail"])) | \(action["label"]!) \(action["href"]!) | \(item["ref"]!)"
       }.joined(separator: "\n")),
      ("nudge",
       ours.needsYou.map { item in
         (item.nudge ?? []).map { group in
           group.map { "\($0.owner.id)[\($0.members.map(\.id).joined(separator: ","))]" }.joined(separator: " or ")
         }.joined(separator: "; ")
       }.joined(separator: "\n"),
       list("needsYou").map { people($0["nudge"]) }.joined(separator: "\n")),
      ("upNext",
       ours.upNext.map { "\($0.ticket.key) \($0.score) \($0.reasons.joined(separator: ","))" }.joined(separator: "\n"),
       list("upNext").map { "\(($0["ticket"] as! [String: Any])["key"]!) \($0["score"]!) \(($0["reasons"] as! [String]).joined(separator: ","))" }
         .joined(separator: "\n")),
      ("deadlines",
       ours.deadlines.map { "\($0.kind.rawValue) \($0.name) \($0.date) \($0.daysLeft) \($0.ticketCount)" }.joined(separator: "\n"),
       list("deadlines").map { "\($0["kind"]!) \($0["name"]!) \($0["date"]!) \($0["daysLeft"]!) \($0["ticketCount"]!)" }.joined(separator: "\n")),
      ("inbox",
       ours.inbox.map { "\($0.id) \($0.kind.rawValue) \($0.verb) | \($0.snippet ?? "-") | \($0.url ?? "-") | \($0.unread)" }.joined(separator: "\n"),
       list("inbox").map { "\($0["id"]!) \($0["kind"]!) \($0["verb"]!) | \(string($0["snippet"])) | \(string($0["url"])) | \(($0["unread"] as! Bool))" }
         .joined(separator: "\n")),
      ("waiting", ours.waiting.map(\.url).joined(separator: ","), list("waiting").map { $0["url"] as! String }.joined(separator: ",")),
      ("reviewRequests", ours.reviewRequests.map(\.url).joined(separator: ","), list("reviewRequests").map { $0["url"] as! String }.joined(separator: ",")),
      ("tickets",
       ours.tickets.map { "\($0.key) \($0.assignedAt ?? "-")" }.sorted().joined(separator: "\n"),
       list("tickets").map { "\($0["key"]!) \(string($0["assignedAt"]))" }.sorted().joined(separator: "\n")),
    ]
    var differences: [String] = []
    for (field, native, web) in compare where native != web {
      differences.append("\(field):\n--- native\n\(native)\n--- web\n\(web)")
    }
    print("[today] \(ours.needsYou.count) needs you, \(ours.upNext.count) up next, \(ours.inbox.count) inbox, \(ours.deadlines.count) deadlines, warnings: \(ours.warnings)")
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n\n"))")
  }

  private static func envFile() throws -> [String: String] {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.env.local").standardized
    var values: [String: String] = [:]
    for line in try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      values[String(line[..<equals])] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    return values
  }
}
