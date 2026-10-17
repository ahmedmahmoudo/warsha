import Foundation
import Testing
@testable import Workbench

/// Loads each scope natively and from the running web version (the launchd service), and compares
/// what each PR reads as. Live data, so it only runs when asked:
///   WORKBENCH_PARITY=1 swift test --package-path macos --filter PrParity
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WORKBENCH_PARITY"] == "1"))
struct PrParityTests {
  private static let web = URL(string: "http://127.0.0.1:5180/api/prs")!

  @Test(arguments: PrScope.allCases)
  func matchesTheWebVersion(scope: PrScope) async throws {
    let env = try Self.envFile()
    let config = PrConfig(
      githubToken: env["GITHUB_TOKEN"] ?? "", linearApiKey: env["LINEAR_API_KEY"] ?? "",
      githubRepos: AppSettings.list(env["GITHUB_REPOS"] ?? ""), githubTeam: AppSettings.list(env["GITHUB_TEAM"] ?? "")
    )
    // Team needs GITHUB_TEAM; without it both versions refuse the same way.
    if scope == .team && config.githubTeam.isEmpty { return }
    async let native = PrService.shared.load(scope, config: config)
    async let webData = URLSession.shared.data(from: URL(string: "\(Self.web)?scope=\(scope.rawValue)&fresh=1")!)
    let ours = try await native
    let theirs = try JSONSerialization.jsonObject(with: try await webData.0) as! [String: Any]

    var differences: [String] = []
    let lists: [(String, [Pr])] = [("open", ours.open), ("recentlyMerged", ours.recentlyMerged)]
    for (list, prs) in lists {
      let webPrs = theirs[list] as! [[String: Any]]
      var webByUrl: [String: [String: Any]] = [:]
      for web in webPrs { webByUrl[web["url"] as! String] = web }
      if Set(webByUrl.keys) != Set(prs.map { $0.url }) {
        differences.append("\(list): web has \(webByUrl.count), native has \(prs.count)")
      }
      for pr in prs {
        guard let web = webByUrl[pr.url] else { continue }
        let status = web["status"] as! [String: Any]
        let gate = web["reviewGate"] as? [String: Any]
        let compare: [(String, String, String)] = [
          ("status", pr.status.label, status["label"] as! String),
          ("waitingOn", "\(pr.waitingOn)", web["waitingOn"] as! String),
          ("tickets", pr.ticketKeys.joined(separator: ","), (web["ticketKeys"] as! [String]).joined(separator: ",")),
          ("mismatches", pr.mismatches.map { $0.label }.joined(separator: ","), (web["mismatches"] as! [String]).map(Self.mismatchLabel).joined(separator: ",")),
          ("checks", "\(pr.checks.state)", (web["checks"] as! [String: Any])["state"] as! String),
          ("codeOwners", pr.reviewGate.map { $0.codeOwners.map { $0.map(\.id).joined(separator: "|") }.joined(separator: ",") } ?? "-",
           gate.map { ($0["codeOwners"] as! [[[String: Any]]]).map { $0.map { $0["id"] as! String }.joined(separator: "|") }.joined(separator: ",") } ?? "-"),
          ("approvalsNeeded", pr.reviewGate.map { "\($0.approvalsNeeded)" } ?? "-", gate.map { "\($0["approvalsNeeded"]!)" } ?? "-"),
          ("stackedOn", pr.stackedOn.map(String.init) ?? "-", (web["stackedOn"] as? Int).map(String.init) ?? "-"),
        ]
        for (field, native, web) in compare where native != web {
          differences.append("\(pr.repo)#\(pr.number) \(field): native \"\(native)\", web \"\(web)\"")
        }
      }
    }
    print("[\(scope)] \(ours.open.count) open, \(ours.recentlyMerged.count) merged, warnings: \(ours.warnings)")
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
  }

  private static func mismatchLabel(_ web: String) -> String {
    ["no-ticket": Mismatch.noTicket, "ticket-closed-pr-open": .ticketClosedPrOpen, "ticket-not-started": .ticketNotStarted,
     "pr-merged-ticket-open": .prMergedTicketOpen][web]!.label
  }

  /// The web version's .env.local, so both load with the same credentials.
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
