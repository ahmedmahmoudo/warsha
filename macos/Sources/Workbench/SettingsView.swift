import AppKit
import SwiftUI

/// Credentials and preferences (what .env.local held in the web version), plus Workbench's data.
struct SettingsView: View {
  var body: some View {
    TabView {
      Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettings() }
      Tab("General", systemImage: "gearshape") { GeneralSettings() }
      Tab("Data", systemImage: "externaldrive") { DataSettings() }
    }
    .frame(width: 560)
    .scenePadding()
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }
}

private struct AccountsSettings: View {
  @Environment(AppSettings.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    Form {
      Section("GitHub") {
        SecureField("Token", text: $settings.githubToken, prompt: Text("repo + read:org"))
        HStack {
          Button("Use gh CLI token") {
            Task { if let token = await AppSettings.ghToken() { settings.githubToken = token } }
          }
          Spacer()
          ConnectionCheck { try await "Signed in as \(GitHub.viewer(token: settings.githubToken))" }
            .id(settings.githubToken)
        }
        TextField("Repos", text: $settings.githubRepos, prompt: Text("everlab-au/ev-admin"))
        TextField("Team", text: $settings.githubTeam, prompt: Text("Comma-separated logins"))
      }
      Section("Linear") {
        SecureField("API key", text: $settings.linearApiKey, prompt: Text("Settings → Security & access → Personal API keys"))
        HStack {
          Spacer()
          ConnectionCheck { try await "Signed in as \(Linear.viewer(apiKey: settings.linearApiKey))" }
            .id(settings.linearApiKey)
        }
      }
      Section {
        TextField("Client ID", text: $settings.googleClientId)
        SecureField("Client secret", text: $settings.googleClientSecret)
      } header: {
        Text("Google Calendar")
      } footer: {
        Text("A Desktop app client from Google Cloud Console. Signing in arrives with the Calendar page.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// A Test button that shows who the credentials belong to, or why they don't work.
private struct ConnectionCheck: View {
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
      if checking { ProgressView().controlSize(.small) }
      Button("Test") {
        checking = true
        Task {
          do { result = .success(try await check()) } catch { result = .failure(error) }
          checking = false
        }
      }
      .disabled(checking)
    }
    .lineLimit(2)
    .font(.callout)
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
      Picker("Time zone", selection: $settings.timeZone) {
        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
      }
      Section {
        TextField("Local repos", text: $settings.localRepos, prompt: Text("owner/repo=/path/to/clone"))
      } footer: {
        Text("Where repos are cloned, for opening a conflicted PR in Claude. Without it, Workbench looks in ~/everlab, ~/Developer, ~/code and similar folders.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.path]) }
        }
        Text(store.path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      } footer: {
        Text("Pins, notes, todos and parked items.").foregroundStyle(.secondary)
      }
      Section("From the web version") {
        LabeledContent("Settings and credentials") {
          Button("Import .env.local…") { importEnv() }
        }
        LabeledContent("Pins, notes, todos and parked items") {
          Button("Import workbench.sqlite…") { importDatabase() }
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
