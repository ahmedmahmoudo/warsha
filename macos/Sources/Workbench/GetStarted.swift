import SwiftUI

/// What someone new sees first: the accounts Workbench reads from, in one sheet over the main window.
/// It comes up until there's a GitHub token, and Help → Get Started brings it back.
struct GetStartedSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppSettings.self) private var settings

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Welcome to Workbench").scaledFont(.title2.weight(.semibold))
        Text(
          "Your PRs, tickets and meetings in one place. Workbench reads GitHub, Linear and Google Calendar with your own accounts; nothing leaves this Mac except to them. GitHub is all it needs to start; the rest can wait."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding([.horizontal, .top], 20)

      AccountsSettings()

      HStack {
        Text("All of this is in Settings → Accounts later.").scaledFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Later") { dismiss() }
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .disabled(!settings.hasGitHub)
      }
      .padding(20)
    }
    .scaledFrame(width: 600)
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }
}
