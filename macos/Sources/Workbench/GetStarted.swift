import SwiftUI
import UserNotifications

/// What someone new sees first: a short guided tour that connects GitHub, Linear and Google
/// Calendar, asks for the permissions Workbench uses, and ends with the shortcuts worth knowing.
/// It comes up until there's a GitHub account (for each profile), and Help → Get Started brings it
/// back. Always dark, on a slowly moving gradient, like a launch screen.
struct GetStartedSheet: View {
  enum Step: Int, CaseIterable {
    case welcome, github, linear, calendar, permissions, done
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(CalendarModel.self) private var calendar
  @State private var step: Step = DevHooks.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
  /// Which way the steps slide: forward moves in from the right.
  @State private var forward = true

  var body: some View {
    ZStack {
      OnboardingBackground(step: step)
      VStack(spacing: 0) {
        topBar
        ZStack {
          page(step)
            .id(step)
            .transition(.asymmetric(
              insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
              removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        bottomBar
      }
    }
    .frame(width: 780, height: 580)
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white, .white.opacity(0.62), .white.opacity(0.4))
  }

  // MARK: Chrome

  private var topBar: some View {
    HStack(spacing: 6) {
      ForEach(Step.allCases.dropFirst().dropLast(), id: \.self) { item in
        Capsule()
          .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(LinearGradient.onboardingAccent) : AnyShapeStyle(.white.opacity(0.14)))
          .frame(width: item == step ? 34 : 18, height: 5)
      }
    }
    .opacity(step == .welcome || step == .done ? 0 : 1)
    .animation(.snappy, value: step)
    .frame(height: 44)
    .padding(.top, 10)
  }

  private var bottomBar: some View {
    HStack {
      if step != .welcome && step != .done {
        Button("Back") { go(-1) }.buttonStyle(OnboardingSecondaryButtonStyle()).clickable()
      }
      Spacer()
      if let skip = skipTitle {
        Button(skip) { go(1) }.buttonStyle(OnboardingSecondaryButtonStyle()).clickable()
      }
      Button(primaryTitle) { primary() }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .clickable()
        .disabled(step == .github && !connected)
        .opacity(step == .github && !connected ? 0.4 : 1)
    }
    .padding(.horizontal, 28)
    .padding(.bottom, 24)
    .opacity(step == .welcome ? 0 : 1)
    .disabled(step == .welcome)
  }

  private var connected: Bool {
    switch step {
    case .github: settings.hasGitHub
    case .linear: !settings.linearAuthorization.isEmpty
    case .calendar: calendar.connection(settings, store) == .connected
    default: true
    }
  }

  private var primaryTitle: String {
    switch step {
    case .welcome: "Get Started"
    case .done: "Open Workbench"
    case .github, .permissions: "Continue"
    case .linear, .calendar: connected ? "Continue" : "Skip"
    }
  }

  /// GitHub is what Workbench needs; it can still wait, from Settings → Accounts.
  private var skipTitle: String? { step == .github && !connected ? "Skip for Now" : nil }

  private func primary() {
    if step == .done { dismiss() } else { go(1) }
  }

  private func go(_ by: Int) {
    guard let next = Step(rawValue: step.rawValue + by) else { return dismiss() }
    forward = by > 0
    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = next }
  }

  // MARK: Pages

  @ViewBuilder
  private func page(_ step: Step) -> some View {
    switch step {
    case .welcome: WelcomePage { go(1) }
    case .github:
      AccountPage(
        glyph: .github, title: "Connect GitHub", connected: settings.hasGitHub,
        detail: "Your pull requests, the reviews asked of you, checks and code owners. Sign in with GitHub, or paste a token."
      ) { GitHubConnect() }
    case .linear:
      AccountPage(
        glyph: .linear, title: "Connect Linear", connected: !settings.linearAuthorization.isEmpty,
        detail: "Your tickets, what to pick up next, and the inbox. Optional: Workbench works without it."
      ) { LinearConnect() }
    case .calendar:
      AccountPage(
        glyph: .calendar, title: "Connect Google Calendar", connected: calendar.connection(settings, store) == .connected,
        detail: "Your next meeting on Today, a Join button, and a heads-up when one moves. Workbench only reads your calendar."
      ) { GoogleConnect() }
    case .permissions: PermissionsPage()
    case .done: DonePage()
    }
  }
}

// MARK: Welcome

private struct WelcomePage: View {
  let start: () -> Void
  @State private var shown = false

  var body: some View {
    VStack(spacing: 22) {
      Spacer(minLength: 0)
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 132, height: 132)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .phaseAnimator([false, true]) { icon, up in icon.offset(y: up ? -6 : 4) } animation: { _ in .easeInOut(duration: 2.4) }
        // A soft glow drawn as a gradient (no blur pass), behind the icon without taking up room.
        .background {
          Circle()
            .fill(RadialGradient(
              colors: [Color(red: 0.85, green: 0.4, blue: 0.75).opacity(0.55), Color(red: 0.55, green: 0.3, blue: 0.95).opacity(0.18), .clear],
              center: .center, startRadius: 10, endRadius: 150
            ))
            .frame(width: 300, height: 300)
        }
      .scaleEffect(shown ? 1 : 0.7)
      .opacity(shown ? 1 : 0)
      VStack(spacing: 10) {
        Text("Welcome to Workbench")
          .font(.system(size: 36, weight: .bold, design: .rounded))
        Text("Your pull requests, tickets and meetings in one calm place.\nEverything stays on this Mac.")
          .font(.system(size: 15))
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .offset(y: shown ? 0 : 16)
      .opacity(shown ? 1 : 0)
      HStack(spacing: 10) {
        FeaturePill(symbol: "arrow.triangle.pull", text: "What needs you")
        FeaturePill(symbol: "checklist", text: "What's next")
        FeaturePill(symbol: "video", text: "When to join")
      }
      .opacity(shown ? 1 : 0)
      Button("Get Started", action: start)
        .buttonStyle(OnboardingPrimaryButtonStyle(large: true))
        .keyboardShortcut(.defaultAction)
        .clickable()
        .padding(.top, 8)
        .opacity(shown ? 1 : 0)
      Spacer(minLength: 0)
    }
    .padding(.bottom, 40)
    .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.1)) { shown = true } }
  }
}

private struct FeaturePill: View {
  let symbol: String
  let text: String

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.white.opacity(0.85))
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(.white.opacity(0.08), in: .capsule)
      .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
  }
}

// MARK: Accounts

/// The service's mark, drawn rather than shipped: a tile in its colours with a symbol.
private enum Glyph {
  case github, linear, calendar

  var symbol: String {
    switch self {
    case .github: "chevron.left.forwardslash.chevron.right"
    case .linear: "line.diagonal"
    case .calendar: "calendar"
    }
  }

  var colors: [Color] {
    switch self {
    case .github: [Color(white: 0.28), Color(white: 0.1)]
    case .linear: [Color(red: 0.42, green: 0.45, blue: 0.98), Color(red: 0.31, green: 0.24, blue: 0.82)]
    case .calendar: [Color(red: 0.26, green: 0.6, blue: 0.98), Color(red: 0.12, green: 0.4, blue: 0.86)]
    }
  }
}

private struct AccountPage<Controls: View>: View {
  let glyph: Glyph
  let title: String
  let connected: Bool
  let detail: String
  @ViewBuilder let controls: Controls

  var body: some View {
    VStack(spacing: 18) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 22)
          .fill(LinearGradient(colors: glyph.colors, startPoint: .top, endPoint: .bottom))
          .frame(width: 84, height: 84)
          .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.18)))
          .overlay(Image(systemName: glyph.symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white))
          .shadow(color: glyph.colors[0].opacity(0.5), radius: 22, y: 10)
        if connected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 28))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color(red: 0.2, green: 0.78, blue: 0.45))
            .background(Circle().fill(Color(white: 0.08)).padding(2))
            .offset(x: 10, y: 10)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.4, dampingFraction: 0.6), value: connected)
      VStack(spacing: 8) {
        Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
        Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 12) { controls }
        .padding(20)
        .frame(width: 500)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
        .animation(.snappy, value: connected)
      Spacer(minLength: 0)
    }
    .padding(.top, 6)
  }
}

// MARK: Permissions

private struct PermissionsPage: View {
  @State private var notifications: UNAuthorizationStatus?

  var body: some View {
    VStack(spacing: 18) {
      RoundedRectangle(cornerRadius: 22)
        .fill(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.3), Color(red: 0.92, green: 0.3, blue: 0.42)], startPoint: .top, endPoint: .bottom))
        .frame(width: 84, height: 84)
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.18)))
        .overlay(Image(systemName: "bell.badge.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white))
        .shadow(color: .orange.opacity(0.45), radius: 22, y: 10)
      VStack(spacing: 8) {
        Text("A few permissions").font(.system(size: 26, weight: .bold, design: .rounded))
        Text("So Workbench can tap you on the shoulder, and be there when you need it.")
          .font(.system(size: 14)).foregroundStyle(.secondary)
      }
      VStack(spacing: 0) {
        PermissionRow(symbol: "bell.fill", tint: .orange, title: "Notifications", detail: "PRs that need you, review requests, meetings in five minutes") {
          switch notifications {
          case .authorized, .provisional, .ephemeral:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Color(red: 0.2, green: 0.78, blue: 0.45))
          case .denied:
            Button("Open Settings") {
              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
            .buttonStyle(OnboardingSecondaryButtonStyle(compact: true)).clickable()
          default:
            Button("Allow") {
              Task {
                _ = await AppState.shared.notifier.requestPermission()
                notifications = await AppState.shared.notifier.permission()
              }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle(compact: true)).clickable()
          }
        }
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        Form { OpenAtLogin() }.formStyle(.columns).toggleStyle(.switch).padding(.vertical, 4)
          .modifier(PermissionChrome(symbol: "power", tint: .green, title: "Open at login", detail: "Keeps the menu bar count and notifications going"))
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        Form { ShortcutSetting() }.formStyle(.columns).labelsHidden().padding(.vertical, 4)
          .modifier(PermissionChrome(symbol: "command", tint: .purple, title: "Global shortcut", detail: "Brings Workbench forward from any app"))
      }
      .padding(.horizontal, 16).padding(.vertical, 6)
      .frame(width: 560)
      .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
      Spacer(minLength: 0)
    }
    .padding(.top, 6)
    .task { notifications = await AppState.shared.notifier.permission() }
  }
}

private struct PermissionRow<Accessory: View>: View {
  let symbol: String
  let tint: Color
  let title: String
  let detail: String
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8).fill(tint.gradient).frame(width: 32, height: 32)
        .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer()
      accessory
    }
    .padding(.vertical, 10)
  }
}

/// The icon and words of a permission row around a settings control.
private struct PermissionChrome: ViewModifier {
  let symbol: String
  let tint: Color
  let title: String
  let detail: String

  func body(content: Content) -> some View {
    PermissionRow(symbol: symbol, tint: tint, title: title, detail: detail) {
      content.labelsHidden().fixedSize()
    }
  }
}

// MARK: Done

private struct DonePage: View {
  @State private var shown = false

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 0)
      ZStack {
        Circle()
          .fill(RadialGradient(colors: [Color(red: 0.2, green: 0.78, blue: 0.45).opacity(0.45), .clear], center: .center, startRadius: 10, endRadius: 110))
          .frame(width: 220, height: 220)
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 84))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, Color(red: 0.2, green: 0.78, blue: 0.45))
          .symbolEffect(.bounce, value: shown)
      }
      VStack(spacing: 8) {
        Text("You're all set").font(.system(size: 32, weight: .bold, design: .rounded))
        Text("A few keys worth knowing:").font(.system(size: 14)).foregroundStyle(.secondary)
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
        ShortcutRow(keys: [GlobalShortcut.combo.display], text: "Bring Workbench forward from anywhere")
        ShortcutRow(keys: ["⌘1", "⌘5"], text: "Today, Pull Requests, Activity, Calendar, Worktrees")
        ShortcutRow(keys: ["⌘R"], text: "Refresh the page")
        ShortcutRow(keys: ["⌘W"], text: "Close the PR tab in front")
        ShortcutRow(keys: ["⇧⌘C"], text: "Copy the PR's link")
      }
      .padding(18)
      .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
      Spacer(minLength: 0)
    }
    .onAppear { shown = true }
  }
}

private struct ShortcutRow: View {
  let keys: [String]
  let text: String

  var body: some View {
    GridRow {
      HStack(spacing: 4) {
        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
          if index > 0 { Text("–").foregroundStyle(.tertiary) }
          Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.14)))
        }
      }
      .gridColumnAlignment(.trailing)
      Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }
  }
}

// MARK: Look

extension LinearGradient {
  static let onboardingAccent = LinearGradient(
    colors: [Color(red: 0.98, green: 0.42, blue: 0.36), Color(red: 0.62, green: 0.36, blue: 0.98)], startPoint: .leading, endPoint: .trailing
  )
}

/// A deep, slowly drifting gradient whose glow shifts a little with each step.
private struct OnboardingBackground: View {
  let step: GetStartedSheet.Step

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let drift = Float(sin(t / 4) * 0.08)
      let shift = Float(step.rawValue) * 0.06
      MeshGradient(
        width: 3, height: 3,
        points: [
          [0, 0], [0.5, 0], [1, 0],
          [0, 0.5], [0.5 + drift, 0.45 - drift + shift / 3], [1, 0.5],
          [0, 1], [0.5, 1], [1, 1],
        ],
        colors: [
          Color(red: 0.05, green: 0.05, blue: 0.09), Color(red: 0.09, green: 0.06, blue: 0.16), Color(red: 0.05, green: 0.05, blue: 0.09),
          Color(red: 0.12, green: 0.07, blue: 0.2 + Double(shift)), Color(red: 0.22, green: 0.1, blue: 0.3),
          Color(red: 0.07, green: 0.08, blue: 0.16),
          Color(red: 0.04, green: 0.04, blue: 0.07), Color(red: 0.16, green: 0.06, blue: 0.12), Color(red: 0.04, green: 0.04, blue: 0.07),
        ]
      )
    }
    .overlay(alignment: .top) {
      // A faint top highlight, as on a glass panel.
      LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
    }
    .ignoresSafeArea()
  }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
  var large = false
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: large ? 15 : compact ? 12 : 13, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, large ? 28 : compact ? 12 : 18)
      .padding(.vertical, large ? 11 : compact ? 5 : 8)
      .background(LinearGradient.onboardingAccent, in: .capsule)
      .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
      .shadow(color: Color(red: 0.8, green: 0.36, blue: 0.7).opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 6)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.snappy(duration: 0.15), value: configuration.isPressed)
      .contentShape(.capsule)
  }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compact ? 12 : 13, weight: .medium))
      .foregroundStyle(.white.opacity(0.8))
      .padding(.horizontal, compact ? 12 : 16)
      .padding(.vertical, compact ? 5 : 8)
      .background(.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: .capsule)
      .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
      .contentShape(.capsule)
  }
}

// MARK: Connect controls

private let connectedGreen = Color(red: 0.2, green: 0.78, blue: 0.45)

/// Who's connected, in place of the sign-in button.
private struct ConnectedBadge: View {
  let account: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(connectedGreen)
      VStack(alignment: .leading, spacing: 1) {
        Text("Connected").font(.system(size: 13, weight: .semibold))
        Text(account).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
    }
    .transition(.scale(scale: 0.9).combined(with: .opacity))
  }
}

private struct ErrorText: View {
  let text: String?

  var body: some View {
    if let text {
      Text(text).font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A token field, folded under a link: for when signing in isn't offered or isn't wanted.
private struct TokenField: View {
  let title: String
  let prompt: String
  @Binding var value: String
  var startOpen = false
  var extra: AnyView?
  @State private var open: Bool?

  var body: some View {
    let isOpen = open ?? (startOpen || !value.isEmpty)
    VStack(spacing: 10) {
      Button { withAnimation(.snappy) { open = !isOpen } } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(isOpen ? 90 : 0))
          Text(title)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
      }
      .buttonStyle(.plain).clickable()
      if isOpen {
        SecureField(prompt, text: $value)
          .textFieldStyle(.plain)
          .font(.system(size: 13, design: .monospaced))
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(.white.opacity(0.07), in: .rect(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.14)))
        if let extra { extra }
      }
    }
  }
}

private struct GitHubConnect: View {
  @Environment(AppSettings.self) private var settings
  private let signIns = AppState.shared.signIns

  var body: some View {
    @Bindable var settings = settings
    if let grant = settings.githubSignIn {
      ConnectedBadge(account: grant.account)
    } else if settings.hasGitHub {
      ConnectedBadge(account: "With a token")
    } else if let code = signIns.githubCode {
      VStack(spacing: 10) {
        Text("Enter this code on GitHub").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        Text(code.userCode)
          .font(.system(size: 30, weight: .bold, design: .monospaced))
          .kerning(4)
          .textSelection(.enabled)
        HStack(spacing: 8) {
          Button("Copy & Open GitHub") { signIns.copyAndOpen(code) }.buttonStyle(OnboardingPrimaryButtonStyle(compact: true)).clickable()
          Button("Cancel") { signIns.cancelGitHub() }.buttonStyle(OnboardingSecondaryButtonStyle(compact: true)).clickable()
        }
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Waiting for you to approve Workbench…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
    } else {
      if signIns.githubClientId != nil {
        Button { signIns.signInToGitHub(settings) } label: {
          HStack(spacing: 8) {
            if signIns.githubBusy { ProgressView().controlSize(.small).tint(.white) }
            Text("Sign in with GitHub")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingPrimaryButtonStyle(large: true))
        .disabled(signIns.githubBusy)
        .clickable()
      }
      ErrorText(text: signIns.githubError)
      TokenField(
        title: signIns.githubClientId == nil ? "Personal access token" : "Use a token instead", prompt: "ghp_… with repo and read:org",
        value: $settings.githubToken, startOpen: signIns.githubClientId == nil,
        extra: AnyView(
          Button("Use my gh CLI token") { Task { if let token = await AppSettings.ghToken() { settings.githubToken = token } } }
            .buttonStyle(OnboardingSecondaryButtonStyle(compact: true)).clickable()
        )
      )
    }
  }
}

private struct LinearConnect: View {
  @Environment(AppSettings.self) private var settings
  private let signIns = AppState.shared.signIns

  var body: some View {
    @Bindable var settings = settings
    if let grant = settings.linearSignIn {
      ConnectedBadge(account: grant.account)
    } else if !settings.linearApiKey.isEmpty {
      ConnectedBadge(account: "With an API key")
    } else {
      if signIns.linearClientId != nil {
        Button { signIns.signInToLinear(settings) } label: {
          HStack(spacing: 8) {
            if signIns.linearBusy { ProgressView().controlSize(.small).tint(.white) }
            Text(signIns.linearBusy ? "Finish in your browser…" : "Sign in with Linear")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingPrimaryButtonStyle(large: true))
        .disabled(signIns.linearBusy)
        .clickable()
      }
      ErrorText(text: signIns.linearError)
      TokenField(
        title: signIns.linearClientId == nil ? "Personal API key" : "Use an API key instead", prompt: "lin_api_…",
        value: $settings.linearApiKey, startOpen: signIns.linearClientId == nil
      )
    }
  }
}

private struct GoogleConnect: View {
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(CalendarModel.self) private var calendar
  @State private var error: String?

  var body: some View {
    switch calendar.connection(settings, store) {
    case .connected:
      ConnectedBadge(account: calendar.email(store) ?? "Google Calendar")
    case .unconfigured:
      Text("This build has no Google client. Add one later in Settings → Accounts.")
        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    case .disconnected:
      Button {
        error = nil
        Task { do { try await calendar.signIn(settings, store) } catch { self.error = error.localizedDescription } }
      } label: {
        HStack(spacing: 8) {
          if calendar.signingIn { ProgressView().controlSize(.small).tint(.white) }
          Text(calendar.signingIn ? "Finish in your browser…" : "Connect Google Calendar")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(OnboardingPrimaryButtonStyle(large: true))
      .disabled(calendar.signingIn)
      .clickable()
      ErrorText(text: error)
    }
  }
}
