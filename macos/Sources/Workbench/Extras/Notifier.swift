import AppKit
import Foundation
import UserNotifications

/// Native notifications for what changed: a PR of yours newly needs you (or is ready to merge),
/// someone asks for your review, a meeting starts in five minutes, a meeting moves or is deleted.
///
/// Each thing is notified once. The first time a kind of thing is seen, what's already there is
/// noted without a notification, so a fresh install doesn't announce everything at once; what's
/// been notified is remembered across launches.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  enum Kind: String, CaseIterable, Identifiable {
    case prs, reviews, meetings, meetingChanges
    var id: Self { self }

    /// The UserDefaults switch for this kind, on unless turned off in Settings.
    var settingKey: String { "notify.\(rawValue)" }

    var label: String {
      switch self {
      case .prs: "Your PRs that need you, and ones ready to merge"
      case .reviews: "Reviews asked of you"
      case .meetings: "Meetings, five minutes before"
      case .meetingChanges: "Meetings moved or deleted"
      }
    }
  }

  private static let seenKey = "notify.seen"
  private static let baselinedKey = "notify.baselined"
  private static let maxSeen = 1000
  private static let meetingLead: TimeInterval = 5 * 60
  private static let joinAction = "join"
  private static let meetingCategory = "meeting"

  private let defaults = UserDefaults.standard
  private var seen: [String]
  private var baselined: Set<String>
  private var authorized = false
  private var asked = false

  /// Notifications need a real app bundle, and stay quiet while the app hosts tests or runs from
  /// a settings file for checks.
  private var available: Bool { Bundle.main.bundleIdentifier != nil && !Keychain.memoryOnly }

  override init() {
    seen = ProfileDefaults().stringArray(forKey: Self.seenKey) ?? []
    baselined = Set(ProfileDefaults().stringArray(forKey: Self.baselinedKey) ?? [])
    super.init()
  }

  /// What's been notified is the profile's: switching reads the new one's.
  func reloadProfile() {
    seen = ProfileDefaults().stringArray(forKey: Self.seenKey) ?? []
    baselined = Set(ProfileDefaults().stringArray(forKey: Self.baselinedKey) ?? [])
  }

  func isEnabled(_ kind: Kind) -> Bool { defaults.object(forKey: kind.settingKey) as? Bool ?? true }

  /// Becomes the notification delegate, with a Join button for meetings.
  func activate() {
    guard available else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.meetingCategory, actions: [UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])],
        intentIdentifiers: []
      ),
    ])
  }

  // MARK: Checking

  func check(_ state: AppState) async {
    guard available, Kind.allCases.contains(where: isEnabled) else { return }
    if !asked {
      asked = true
      authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    guard authorized else { return }

    if let mine = state.pullRequests.responses[.mine] {
      let items = mine.open.filter { !$0.isDraft && state.store.parked(for: $0) == nil }.compactMap { pr -> Item? in
        guard pr.waitingOn == .you || pr.status.label == "Ready to merge" else { return nil }
        let ready = pr.waitingOn != .you
        return Item(
          key: "pr|\(pr.url)|\(pr.status.label)", title: ready ? "Ready to merge" : pr.status.label,
          subtitle: "\(pr.repo)#\(String(pr.number))", body: pr.title, pr: PrKey(pr)
        )
      }
      deliver(.prs, items)
    }

    if let reviewing = state.pullRequests.responses[.reviewing] {
      let viewer = reviewing.viewer.lowercased()
      // Asked of you personally, as Today counts them.
      let requested = reviewing.open.filter { pr in
        ((pr.reviewGate?.codeOwners.flatMap { $0 } ?? []) + (pr.reviewGate?.optional ?? [])).contains { $0.kind == .user && $0.id.lowercased() == viewer }
      }
      deliver(.reviews, requested.map {
        Item(key: "review|\($0.url)", title: "Review requested by \($0.author)", subtitle: "\($0.repo)#\(String($0.number))", body: $0.title, pr: PrKey($0))
      })
    }

    if state.calendar.connection(state.settings, state.store) == .connected, state.calendar.lastSync != nil {
      let now = Date()
      let soon = state.calendar.today(state.settings, state.store).filter { meeting in
        guard !meeting.allDay, !meeting.declined, let start = TodayRules.parseInstant(meeting.start) else { return false }
        let wait = start.timeIntervalSince(now)
        return wait > 0 && wait <= Self.meetingLead
      }
      deliver(.meetings, soon.map {
        Item(
          key: "meeting|\($0.id)|\($0.start)", title: $0.title, subtitle: "Starts at \(CalendarTime.clock($0.start, TimeZone.current.identifier))",
          body: $0.location.flatMap { $0.hasPrefix("http") ? nil : $0 } ?? "", joinUrl: $0.joinUrl
        )
      }, baseline: false)

      deliver(.meetingChanges, state.calendar.changes(state.store).compactMap { meeting in
        guard let change = meeting.change else { return nil }
        let when = CalendarTime.timeRange(start: meeting.start, end: meeting.end, allDay: meeting.allDay, zone: TimeZone.current.identifier, withDay: true)
        return Item(
          key: "change|\(meeting.id)|\(change.at)", title: change.isDeleted ? "Meeting deleted" : "Meeting moved",
          subtitle: meeting.title, body: change.isDeleted ? "It was \(when)" : "Now \(when)", url: meeting.htmlUrl
        )
      })
    }
  }

  private struct Item {
    let key: String
    let title: String
    let subtitle: String
    let body: String
    var pr: PrKey?
    var joinUrl: String?
    var url: String?
  }

  /// Notifies what hasn't been seen. `baseline` notes what's there the first time without a word;
  /// meetings skip it, since one starting in five minutes is news however new the install.
  private func deliver(_ kind: Kind, _ items: [Item], baseline: Bool = true) {
    let fresh = items.filter { !seen.contains($0.key) }
    guard !fresh.isEmpty || (baseline && !baselined.contains(kind.rawValue)) else { return }
    let quiet = baseline && !baselined.contains(kind.rawValue)
    if quiet {
      baselined.insert(kind.rawValue)
      ProfileDefaults().set(Array(baselined), forKey: Self.baselinedKey)
    }
    for item in fresh {
      seen.append(item.key)
      if !quiet && isEnabled(kind) { post(item) }
    }
    if seen.count > Self.maxSeen { seen.removeFirst(seen.count - Self.maxSeen) }
    ProfileDefaults().set(seen, forKey: Self.seenKey)
  }

  private func post(_ item: Item) {
    let content = UNMutableNotificationContent()
    content.title = item.title
    content.subtitle = item.subtitle
    content.body = item.body
    content.sound = .default
    var info: [String: String] = [:]
    if let pr = item.pr {
      info["repo"] = pr.repo
      info["number"] = String(pr.number)
    }
    if let url = item.url { info["url"] = url }
    if let join = item.joinUrl {
      info["join"] = join
      content.categoryIdentifier = Self.meetingCategory
    }
    content.userInfo = info
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.key, content: content, trigger: nil))
  }

  // MARK: UNUserNotificationCenterDelegate

  /// Shown even while Workbench is in front.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }

  /// A PR opens its details here; Join opens the call; anything else opens its link.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
    let action = response.actionIdentifier
    await MainActor.run {
      if action == Self.joinAction || (info["join"] != nil && action == UNNotificationDefaultActionIdentifier),
         let join = info["join"].flatMap(URL.init(string:)) {
        NSWorkspace.shared.open(join)
      } else if let repo = info["repo"], let number = info["number"].flatMap(Int.init) {
        AppState.shared.show(pr: PrKey(repo: repo, number: number))
      } else if let url = info["url"].flatMap(URL.init(string:)) {
        NSWorkspace.shared.open(url)
      } else {
        AppState.shared.show()
      }
    }
  }
}
