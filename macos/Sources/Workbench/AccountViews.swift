import AppKit
import SwiftUI

// Settings → Accounts (and the Get started sheet) for GitHub and Linear: sign in with Workbench's
// app, or use a token instead. A sign-in wins while there is one; signing out goes back to the token.

struct GitHubAccount: View {
  @Environment(AppSettings.self) private var settings
  private let signIns = AppState.shared.signIns
  @State private var showToken: Bool?

  var body: some View {
    @Bindable var settings = settings
    if let grant = settings.githubSignIn {
      SignedIn(account: grant.account) { signIns.signOutOfGitHub(settings) }
    } else if signIns.githubClientId != nil {
      LabeledContent("Account") {
        HStack(spacing: 8) {
          if signIns.githubBusy {
            ProgressView().scaledControlSize(.small)
            Button("Cancel") { signIns.cancelGitHub() }.clickable()
          } else {
            Button("Sign in with GitHub") { signIns.signInToGitHub(settings) }
              .buttonStyle(.pill(.neutral, prominent: true))
              .clickable()
          }
        }
      }
      if let code = signIns.githubCode {
        DeviceCodeRow(code: code)
      }
      if let error = signIns.githubError {
        Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color).fixedSize(horizontal: false, vertical: true)
      }
    }
    if settings.githubSignIn == nil {
      TokenFallback(isExpanded: expanded(signIns.githubClientId, settings.githubToken), hasSignIn: signIns.githubClientId != nil) {
        SecureField("Token", text: $settings.githubToken, prompt: Text("repo + read:org"))
        HStack {
          Button("Use gh CLI token") {
            Task { if let token = await AppSettings.ghToken() { settings.githubToken = token } }
          }
          .clickable()
          Spacer()
          ConnectionCheck { try await "Signed in as \(GitHub.viewer(token: settings.githubToken))" }
            .id(settings.githubToken)
        }
      }
    }
  }

  private func expanded(_ clientId: String?, _ token: String) -> Binding<Bool> {
    Binding(get: { showToken ?? (clientId == nil || !token.isEmpty) }, set: { showToken = $0 })
  }
}

struct LinearAccount: View {
  @Environment(AppSettings.self) private var settings
  private let signIns = AppState.shared.signIns
  @State private var showToken: Bool?

  var body: some View {
    @Bindable var settings = settings
    if let grant = settings.linearSignIn {
      SignedIn(account: grant.account) { signIns.signOutOfLinear(settings) }
    } else if signIns.linearClientId != nil {
      LabeledContent("Account") {
        HStack(spacing: 8) {
          if signIns.linearBusy {
            ProgressView().scaledControlSize(.small)
            Text("Finish signing in in your browser…").foregroundStyle(.secondary)
          } else {
            Button("Sign in with Linear") { signIns.signInToLinear(settings) }
              .buttonStyle(.pill(.neutral, prominent: true))
              .clickable()
          }
        }
      }
      if let error = signIns.linearError {
        Text(error).scaledFont(.callout).foregroundStyle(Tone.bad.color).fixedSize(horizontal: false, vertical: true)
      }
    }
    if settings.linearSignIn == nil {
      let clientId = signIns.linearClientId
      TokenFallback(
        isExpanded: Binding(get: { showToken ?? (clientId == nil || !settings.linearApiKey.isEmpty) }, set: { showToken = $0 }),
        hasSignIn: clientId != nil
      ) {
        SecureField("API key", text: $settings.linearApiKey, prompt: Text("Settings → Security & access → Personal API keys"))
        HStack {
          Spacer()
          ConnectionCheck { try await "Signed in as \(Linear.viewer(apiKey: settings.linearApiKey))" }
            .id(settings.linearApiKey)
        }
      }
    }
  }
}

/// Who's signed in, and the way out.
private struct SignedIn: View {
  let account: String
  let signOut: () -> Void
  @State private var confirming = false

  var body: some View {
    LabeledContent("Account") {
      HStack(spacing: 8) {
        Text(account).foregroundStyle(Tone.good.color)
        Button("Sign Out") { confirming = true }
          .clickable()
          .confirmationDialog("Sign out of \(account)?", isPresented: $confirming) {
            Button("Sign Out", role: .destructive, action: signOut)
          } message: {
            Text("Workbench goes back to the token under “Use a token instead”, if there is one.")
          }
      }
    }
  }
}

/// GitHub's code while it waits: on the clipboard already, with GitHub's page open.
private struct DeviceCodeRow: View {
  let code: GitHubSignIn.DeviceCode
  private let signIns = AppState.shared.signIns

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(code.userCode)
          .scaledFont(.title2.weight(.semibold).monospaced())
          .textSelection(.enabled)
        Button("Copy & Open GitHub", systemImage: "arrow.up.right") { signIns.copyAndOpen(code) }
          .buttonStyle(.pill)
          .clickable()
      }
      Text("The code is on your clipboard: paste it on GitHub's page and approve Workbench. This page updates when you're done.")
        .scaledFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The token fields, folded away when signing in is offered and no token is set.
private struct TokenFallback<Content: View>: View {
  @Binding var isExpanded: Bool
  let hasSignIn: Bool
  @ViewBuilder let content: Content

  var body: some View {
    if hasSignIn {
      DisclosureGroup("Use a token instead", isExpanded: $isExpanded) { content }
    } else {
      content
    }
  }
}

/// After signing in to GitHub: whether the sign-in can see your repos. An organization that
/// hasn't approved Workbench yet shows here, with what to do about it.
struct GitHubAccess: View {
  let token: String
  let repos: [String]
  @State private var problems: [String]?

  var body: some View {
    Group {
      if let problems {
        if problems.isEmpty {
          Text(repos.isEmpty ? "Signed in." : "Can see \(repos.joined(separator: ", ")).").foregroundStyle(Tone.good.color)
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { Text($0).foregroundStyle(Tone.warn.color) }
            if problems.contains(where: { $0.contains("hasn't approved") }) {
              Link("Request approval on GitHub", destination: URL(string: "https://github.com/settings/applications")!)
                .clickable(underline: true)
            }
          }
        }
      } else {
        Text("Checking what the sign-in can see…").foregroundStyle(.secondary)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .task { problems = await GitHub.tokenProblems(token: token, repos: repos) }
  }
}
