import AppKit
import ServiceManagement
import SwiftUI

/// Credentials and preferences (what .env.local held in the web version), plus Workbench's data.
struct SettingsView: View {
  /// Settings reopens on the tab you last used, as Mac apps do.
  @AppStorage("settingsTab") private var tab = "accounts"

  var body: some View {
    TabView(selection: $tab) {
      // The palette's text colours go on each form, not the window: the native tab bar can't draw them.
      Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") { AccountsSettings().palettedText() }
      Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings().palettedText() }
      Tab("Notifications", systemImage: "bell.badge", value: "notifications") { NotificationSettings().palettedText() }
      Tab("Data", systemImage: "externaldrive", value: "data") { DataSettings().palettedText() }
    }
    .scaledFrame(width: 560)
    .scenePadding()
  }
}

private extension View {
  func palettedText() -> some View {
    foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }
}

struct AccountsSettings: View {
  @Environment(AppSettings.self) private var settings
  private let signIns = AppState.shared.signIns

  var body: some View {
    @Bindable var settings = settings
    Form {
      ProfilesSection()
      Section {
        GitHubAccount()
        HStack {
          TextField("Repos", text: $settings.githubRepos, prompt: Text("All you can see, or owner/repo, owner/other-repo"))
          if settings.hasGitHub { ChooseReposButton() }
        }
        TeamSetting()
      } header: {
        Text("GitHub")
      } footer: {
        if settings.githubSignIn != nil {
          GitHubAccess(token: settings.githubCredential, repos: AppSettings.list(settings.githubRepos))
            .id("\(settings.githubCredential)|\(settings.githubRepos)")
        }
      }
      Section {
        LinearAccount()
      } header: {
        Text("Linear")
      } footer: {
        if signIns.linearClientId != nil, settings.linearSignIn == nil {
          Text("Signs in to the workspace open in your browser; switch workspace in Linear first to pick another.")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        GoogleConnection()
        if CalendarModel.builtInClient == nil {
          TextField("Client ID", text: $settings.googleClientId)
          SecureField("Client secret", text: $settings.googleClientSecret)
        } else {
          DisclosureGroup("Use your own Google client") {
            TextField("Client ID", text: $settings.googleClientId)
            SecureField("Client secret", text: $settings.googleClientSecret)
          }
        }
      } header: {
        Text("Google Calendar")
      } footer: {
        Text(CalendarModel.builtInClient == nil
          ? "A Desktop app client from Google Cloud Console. Signing in opens Google in your browser and comes back here."
          : "Signing in opens Google in your browser and comes back here. Workbench only reads your calendar.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// Connect or disconnect your Google account, and which one is connected.
struct GoogleConnection: View {
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(CalendarModel.self) private var calendar
  @State private var error: String?
  @State private var confirmingDisconnect = false

  var body: some View {
    LabeledContent("Account") {
      HStack(spacing: 8) {
        switch calendar.connection(settings, store) {
        case .unconfigured:
          Text("Add the client ID and secret first").foregroundStyle(.secondary)
        case .disconnected:
          if calendar.signingIn {
            ProgressView().scaledControlSize(.small)
            Text("Finish signing in in your browser…").foregroundStyle(.secondary)
          }
          Button("Connect Google Calendar") {
            error = nil
            Task {
              do { try await calendar.signIn(settings, store) } catch { self.error = error.localizedDescription }
            }
          }
          .clickable()
          .disabled(calendar.signingIn)
        case .connected:
          Text(calendar.email(store) ?? "Connected").foregroundStyle(Tone.good.color)
          Button("Disconnect") { confirmingDisconnect = true }
            .clickable()
            .confirmationDialog("Disconnect Google Calendar?", isPresented: $confirmingDisconnect) {
              Button("Disconnect", role: .destructive) { Task { await calendar.disconnect(store) } }
            } message: {
              Text("Workbench's access is revoked at Google, and the meetings it saved are forgotten.")
            }
        }
      }
    }
    if let error {
      Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color)
    }
  }
}

/// A Test button that shows who the credentials belong to, or why they don't work.
struct ConnectionCheck: View {
  let check: () async throws -> String
  @State private var result: Result<String, any Error>?
  @State private var checking = false

  var body: some View {
    HStack {
      switch result {
      case let .success(message): Text(message).foregroundStyle(Tone.good.color)
      case let .failure(error): Text(error.localizedDescription).foregroundStyle(Tone.bad.color)
      case nil: EmptyView()
      }
      if checking { ProgressView().scaledControlSize(.small) }
      Button("Test") {
        checking = true
        Task {
          do { result = .success(try await check()) } catch { result = .failure(error) }
          checking = false
        }
      }
      .disabled(checking)
      .clickable()
    }
    .lineLimit(2)
    .scaledFont(.callout)
  }
}

private struct GeneralSettings: View {
  @Environment(AppSettings.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    Form {
      Picker("Appearance", selection: $settings.appearance) {
        ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      Picker("Text size", selection: $settings.textScale) {
        ForEach(TextScale.steps, id: \.self) { Text($0 == 1 ? "Actual size" : TextScale.label($0)).tag($0) }
      }
      .help("Also View → Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0)")
      OpenAtLogin()
      ShortcutSetting()
      Picker("Home time zone", selection: $settings.timeZone) {
        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
      }
      Section {
        Picker("A PR counts as new for", selection: $settings.newPrHours) {
          Text("Off").tag(0)
          ForEach([6, 12, 24, 48, 72], id: \.self) { Text(hoursLabel($0)).tag($0) }
        }
        Picker("Suggest a nudge again after", selection: $settings.nudgeAgainHours) {
          ForEach([4, 8, 24, 48, 72, 120], id: \.self) { Text(hoursLabel($0)).tag($0) }
        }
      } header: {
        Text("Reviews")
      } footer: {
        Text("A new PR nobody has reviewed yet shows on Today as Send for review. Once you've sent it or nudged its reviewers, it waits on them until this long has passed without an approval.")
          .foregroundStyle(.secondary)
      }
      Section {
        TextField("Ticket states after merge", text: $settings.afterMergeStates, prompt: Text("Merged"))
      } footer: {
        Text("Ticket states that are fine once a PR has merged, besides done and canceled, separated by commas. A merged PR whose ticket is in any other state shows a ticket mismatch.")
          .foregroundStyle(.secondary)
      }
      Section {
        TextField("Local repos", text: $settings.localRepos, prompt: Text("owner/repo=/path/to/clone"))
      } footer: {
        Text("Where repos are cloned, for opening a conflicted PR in Claude. Without it, Workbench looks in your home folder and the folders directly inside it.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// Open at login, through macOS's login items.
struct OpenAtLogin: View {
  @State private var status = LoginItem.status
  @State private var error: String?

  var body: some View {
    Toggle("Open at login", isOn: Binding(
      get: { status == .enabled || status == .requiresApproval },
      set: { on in
        do { try LoginItem.set(on) } catch { self.error = error.localizedDescription }
        status = LoginItem.status
      }
    ))
    if status == .requiresApproval {
      HStack {
        Text("macOS needs you to allow it in Login Items.").foregroundStyle(Tone.warn.color)
        Button("Open Login Items") { LoginItem.openSystemSettings() }.clickable()
      }
      .scaledFont(.callout)
    }
    if let error { Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color) }
  }
}

/// The shortcut that brings Workbench forward from any app: on or off, and which keys.
struct ShortcutSetting: View {
  @State private var enabled = GlobalShortcut.isEnabled
  @State private var combo = GlobalShortcut.combo
  @State private var recording = false
  @State private var monitor: Any?

  var body: some View {
    LabeledContent("Bring Workbench forward") {
      HStack(spacing: 8) {
        Toggle("Shortcut", isOn: $enabled).labelsHidden().toggleStyle(.switch)
          .onChange(of: enabled) { _, on in GlobalShortcut.isEnabled = on }
        Button(recording ? "Press a shortcut…" : combo.display) { recording ? stop() : record() }
          .monospaced()
          .clickable()
          .disabled(!enabled)
          .help("Click, then press the keys you want, with ⌘, ⌥ or ⌃. Esc cancels.")
        if combo != .standard {
          Button("Reset", systemImage: "arrow.uturn.backward") {
            combo = .standard
            GlobalShortcut.combo = .standard
          }
          .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().help("Back to ⌃⌥⌘W")
        }
      }
    }
    .onDisappear(perform: stop)
  }

  private func record() {
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 { // Esc
        stop()
        return nil
      }
      guard let next = GlobalShortcut.combo(from: event) else { return nil }
      combo = next
      GlobalShortcut.combo = next
      stop()
      return nil
    }
  }

  private func stop() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

private struct NotificationSettings: View {
  var body: some View {
    Form {
      Section {
        ForEach(Notifier.Kind.allCases) { kind in
          NotificationToggle(kind: kind)
        }
      } header: {
        Text("Notify me about")
      } footer: {
        Text("Workbench notes what's already there the first time, so you only hear about changes. Clicking a PR's notification opens it here. macOS asks once whether Workbench may notify you; you can change that in System Settings → Notifications.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct NotificationToggle: View {
  let kind: Notifier.Kind
  @AppStorage private var on: Bool

  init(kind: Notifier.Kind) {
    self.kind = kind
    _on = AppStorage(wrappedValue: true, kind.settingKey)
  }

  var body: some View {
    Toggle(kind.label, isOn: $on)
  }
}

private struct DataSettings: View {
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @State private var message: String?

  var body: some View {
    Form {
      Section {
        LabeledContent("Database") {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.path]) }.clickable()
        }
        Text(store.path.path).scaledFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      } footer: {
        Text("Pins, notes, todos and parked items.").foregroundStyle(.secondary)
      }
      Section("From the web version") {
        LabeledContent("Settings and credentials") {
          Button("Import .env.local…") { importEnv() }.clickable()
        }
        LabeledContent("Pins, notes, todos and parked items") {
          Button("Import workbench.sqlite…") { importDatabase() }.clickable()
        }
      }
      if let message { Text(message).foregroundStyle(.secondary) }
    }
    .formStyle(.grouped)
  }

  private func importEnv() {
    guard let file = choose("Choose the web version's .env.local") else { return }
    do {
      let keys = try settings.importEnvFile(file)
      message = keys.isEmpty ? "Nothing to import in that file." : "Imported \(keys.joined(separator: ", "))."
    } catch {
      message = error.localizedDescription
    }
  }

  private func importDatabase() {
    guard let file = choose("Choose the web version's data/workbench.sqlite") else { return }
    let confirm = NSAlert()
    confirm.messageText = "Replace Workbench's data?"
    confirm.informativeText = "Everything in the app's database is replaced with the contents of \(file.lastPathComponent)."
    confirm.addButton(withTitle: "Replace")
    confirm.addButton(withTitle: "Cancel")
    guard confirm.runModal() == .alertFirstButtonReturn else { return }
    store.importDatabase(from: file)
    message = store.error ?? "Imported \(store.pins.count) pins, \(store.notes.count) notes, \(store.todos.count) todos and \(store.parked.count) parked items."
  }

  private func choose(_ prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.message = prompt
    panel.showsHiddenFiles = true
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private func hoursLabel(_ hours: Int) -> String {
  hours % 24 == 0 ? "\(hours / 24) day\(hours == 24 ? "" : "s")" : "\(hours) hours"
}
