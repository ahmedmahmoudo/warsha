import SwiftUI
import UserNotifications

/// What someone new sees first: a short guided tour that connects GitHub, Linear and Google
/// Calendar, asks for the permissions Workbench uses, and ends with the shortcuts worth knowing.
/// It comes up until there's a GitHub account (for each profile), and Help → Get Started brings it
/// back. It's built on the board in Workbench's icon: each step is one of its tiles (GitHub the
/// green PR tile, Calendar the amber meeting tile, Linear the blue ticket tile, permissions the
/// notes tile), and the board in the header fills in as you go. Colours, type and buttons follow
/// the brand kit (design/website) and the app's own light and dark palette.
struct GetStartedSheet: View {
  enum Step: Int, CaseIterable {
    case welcome, github, calendar, linear, permissions, done

    /// The board tile the step stands for.
    var tile: BoardTile? {
      switch self {
      case .github: .pullRequests
      case .calendar: .meetings
      case .linear: .tickets
      case .permissions: .notes
      case .welcome, .done: nil
      }
    }
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(AppSettings.self) private var settings
  @Environment(Store.self) private var store
  @Environment(CalendarModel.self) private var calendar
  @State private var step: Step = DevHooks.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
  /// Which way the steps slide: forward moves in from the right.
  @State private var forward = true

  var body: some View {
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
      // Not clipped: the step tile's glow would end in a hard line under the board.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      bottomBar
    }
    .frame(width: 760, height: 560)
    .background(OnboardingBackground(tile: step.tile))
    .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }

  // MARK: Chrome

  /// The board, filling in: steps done are lit, the current one is lit and outlined.
  private var topBar: some View {
    let lit = Set(Step.allCases.filter { $0.rawValue <= step.rawValue }.compactMap(\.tile))
    return BoardMark(size: 34, lit: lit, current: step.tile)
      .opacity(step == .welcome || step == .done ? 0 : 1)
      .animation(.snappy, value: step)
      .frame(height: 50)
      .padding(.top, 14)
  }

  private var bottomBar: some View {
    HStack(spacing: 10) {
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
    withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { step = next }
  }

  // MARK: Pages

  @ViewBuilder
  private func page(_ step: Step) -> some View {
    switch step {
    case .welcome: WelcomePage { go(1) }
    case .github:
      AccountPage(
        tile: .pullRequests, title: "Connect GitHub", connected: settings.hasGitHub,
        detail: "Your pull requests, the reviews asked of you, checks and code owners. Sign in with GitHub, or paste a token."
      ) { GitHubConnect() }
    case .calendar:
      AccountPage(
        tile: .meetings, title: "Connect Google Calendar", connected: calendar.connection(settings, store) == .connected,
        detail: "Your next meeting on Today, a Join button, and a heads-up when one moves. Workbench only reads your calendar."
      ) { GoogleConnect() }
    case .linear:
      AccountPage(
        tile: .tickets, title: "Connect Linear", connected: !settings.linearAuthorization.isEmpty,
        detail: "Your tickets, what to pick up next, and your inbox. Optional: Workbench works without it."
      ) { LinearConnect() }
    case .permissions: PermissionsPage()
    case .done: DonePage()
    }
  }
}

// MARK: The board

/// One of the four tiles in Workbench's icon, in the brand kit's colours.
enum BoardTile: CaseIterable {
  case pullRequests, meetings, tickets, notes

  var color: Color {
    switch self {
    case .pullRequests: Color(red: 0x5C / 255, green: 0xC7 / 255, blue: 0x9A / 255)
    case .meetings: Color(red: 0xE8 / 255, green: 0xB4 / 255, blue: 0x5A / 255)
    case .tickets: Color(red: 0x8F / 255, green: 0xB0 / 255, blue: 0xF5 / 255)
    case .notes: Color(red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xF1 / 255)
    }
  }

  /// The tile's glyph from the icon (design/website/brand/logo-mark.svg), in the tile's own
  /// 21.5-unit square, for stroking at 2.4 units.
  var glyph: Path {
    var path = Path()
    switch self {
    case .pullRequests:
      path.addEllipse(in: CGRect(x: 4.3, y: 4.3, width: 4.4, height: 4.4))
      path.addEllipse(in: CGRect(x: 12.8, y: 12.8, width: 4.4, height: 4.4))
      path.move(to: CGPoint(x: 6.5, y: 8.7)); path.addLine(to: CGPoint(x: 6.5, y: 17.2))
      path.move(to: CGPoint(x: 10.5, y: 6.5)); path.addLine(to: CGPoint(x: 13, y: 6.5))
      path.addArc(tangent1End: CGPoint(x: 15, y: 6.5), tangent2End: CGPoint(x: 15, y: 8.5), radius: 2)
      path.addLine(to: CGPoint(x: 15, y: 12.8))
    case .meetings:
      path.addRoundedRect(in: CGRect(x: 5, y: 6, width: 11.5, height: 10.5), cornerSize: CGSize(width: 1.8, height: 1.8))
      path.move(to: CGPoint(x: 5, y: 10)); path.addLine(to: CGPoint(x: 16.5, y: 10))
      path.move(to: CGPoint(x: 8, y: 4)); path.addLine(to: CGPoint(x: 8, y: 7))
      path.move(to: CGPoint(x: 13.5, y: 4)); path.addLine(to: CGPoint(x: 13.5, y: 7))
    case .tickets:
      // A stub with rounded corners and a notch in each side.
      path.move(to: CGPoint(x: 4.25, y: 8.25))
      path.addArc(tangent1End: CGPoint(x: 4.25, y: 6.25), tangent2End: CGPoint(x: 6.25, y: 6.25), radius: 2)
      path.addLine(to: CGPoint(x: 15.25, y: 6.25))
      path.addArc(tangent1End: CGPoint(x: 17.25, y: 6.25), tangent2End: CGPoint(x: 17.25, y: 8.25), radius: 2)
      path.addLine(to: CGPoint(x: 17.25, y: 8.75))
      path.addArc(center: CGPoint(x: 17.25, y: 10.75), radius: 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
      path.addLine(to: CGPoint(x: 17.25, y: 13.25))
      path.addArc(tangent1End: CGPoint(x: 17.25, y: 15.25), tangent2End: CGPoint(x: 15.25, y: 15.25), radius: 2)
      path.addLine(to: CGPoint(x: 6.25, y: 15.25))
      path.addArc(tangent1End: CGPoint(x: 4.25, y: 15.25), tangent2End: CGPoint(x: 4.25, y: 13.25), radius: 2)
      path.addLine(to: CGPoint(x: 4.25, y: 12.75))
      path.addArc(center: CGPoint(x: 4.25, y: 10.75), radius: 2, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
      path.closeSubpath()
    case .notes:
      for (y, length) in [(6.5, 10.0), (10.7, 10.0), (14.9, 6.0)] {
        path.move(to: CGPoint(x: 6, y: y)); path.addLine(to: CGPoint(x: 6 + length, y: y))
      }
    }
    return path
  }

  var label: String {
    switch self {
    case .pullRequests: "Pull requests"
    case .meetings: "Meetings"
    case .tickets: "Tickets"
    case .notes: "Notes"
    }
  }
}

/// The midnight of the icon's tile, and the ink its glyphs are drawn in.
private let midnight = Color(red: 0x0E / 255, green: 0x14 / 255, blue: 0x20 / 255)
private let midnightTop = Color(red: 0x1D / 255, green: 0x27 / 255, blue: 0x38 / 255)

/// A tile in its colour with its glyph in midnight ink, as in the icon; unlit, an empty outline.
struct TileView: View {
  let tile: BoardTile
  let size: CGFloat
  var lit = true

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.23)
      .fill(lit ? AnyShapeStyle(tile.color) : AnyShapeStyle(Palette.fill))
      .overlay(RoundedRectangle(cornerRadius: size * 0.23).strokeBorder(lit ? .clear : Palette.border))
      .overlay {
        // The icon's glyph, scaled from its 21.5-unit tile; a touch heavier when small.
        let scale = size / 21.5
        tile.glyph
          .applying(CGAffineTransform(scaleX: scale, y: scale))
          .stroke(lit ? AnyShapeStyle(midnight) : AnyShapeStyle(Palette.faint),
                  style: StrokeStyle(lineWidth: max(2.4 * scale, 1.2), lineCap: .round, lineJoin: .round))
      }
      .frame(width: size, height: size)
  }
}

/// The 2×2 board, its tiles lit or not; `current` gets a ring.
struct BoardMark: View {
  let size: CGFloat
  var lit: Set<BoardTile> = Set(BoardTile.allCases)
  var current: BoardTile?

  var body: some View {
    let tile = (size - 3) / 2
    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
      GridRow { cell(.pullRequests, tile); cell(.meetings, tile) }
      GridRow { cell(.tickets, tile); cell(.notes, tile) }
    }
  }

  private func cell(_ item: BoardTile, _ side: CGFloat) -> some View {
    TileView(tile: item, size: side, lit: lit.contains(item))
      .overlay {
        if item == current {
          RoundedRectangle(cornerRadius: side * 0.23 + 2.5).strokeBorder(item.color, lineWidth: 1.5).padding(-2.5)
        }
      }
  }
}

// MARK: Welcome

/// The board puts itself together, tile by tile, then says what Workbench is.
private struct WelcomePage: View {
  let start: () -> Void
  @State private var placed = 0
  @State private var shown = false

  var body: some View {
    VStack(spacing: 26) {
      Spacer(minLength: 0)
      ZStack {
        RoundedRectangle(cornerRadius: 34)
          .fill(LinearGradient(colors: [midnightTop, midnight], startPoint: .top, endPoint: .bottom))
          .overlay(RoundedRectangle(cornerRadius: 34).strokeBorder(Color(red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xF1 / 255).opacity(0.14)))
          .frame(width: 150, height: 150)
          .shadow(color: midnight.opacity(0.35), radius: 24, y: 14)
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
          GridRow { piece(.pullRequests, 0); piece(.meetings, 1) }
          GridRow { piece(.tickets, 2); piece(.notes, 3) }
        }
      }
      VStack(spacing: 10) {
        Text("Welcome to Workbench")
          .font(.system(size: 34, weight: .semibold))
          .tracking(-0.7)
        Text("PRs, meetings, Linear tickets and notes in one place.\nEverything stays on this Mac.")
          .font(.system(size: 15))
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : 10)
      Button("Get Started", action: start)
        .buttonStyle(OnboardingPrimaryButtonStyle(large: true))
        .keyboardShortcut(.defaultAction)
        .clickable()
        .opacity(shown ? 1 : 0)
      Spacer(minLength: 0)
    }
    .padding(.bottom, 30)
    .task {
      for index in 1 ... 4 {
        try? await Task.sleep(for: .milliseconds(index == 1 ? 150 : 110))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { placed = index }
      }
      withAnimation(.easeOut(duration: 0.45)) { shown = true }
    }
  }

  private func piece(_ tile: BoardTile, _ index: Int) -> some View {
    TileView(tile: tile, size: 52)
      .scaleEffect(placed > index ? 1 : 0.4)
      .opacity(placed > index ? 1 : 0)
  }
}

// MARK: Accounts

private struct AccountPage<Controls: View>: View {
  let tile: BoardTile
  let title: String
  let connected: Bool
  let detail: String
  @ViewBuilder let controls: Controls

  var body: some View {
    VStack(spacing: 18) {
      ZStack(alignment: .bottomTrailing) {
        TileView(tile: tile, size: 76)
          .shadow(color: tile.color.opacity(0.35), radius: 18, y: 8)
        if connected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 26))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Tone.good.color)
            .background(Circle().fill(Palette.background).padding(1))
            .offset(x: 9, y: 9)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.4, dampingFraction: 0.6), value: connected)
      VStack(spacing: 8) {
        Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
        Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 12) { controls }
        .padding(20)
        .frame(width: 480)
        .onboardingCard()
        .animation(.snappy, value: connected)
      Spacer(minLength: 0)
    }
  }
}

// MARK: Permissions

private struct PermissionsPage: View {
  @State private var notifications: UNAuthorizationStatus?

  var body: some View {
    VStack(spacing: 18) {
      TileView(tile: .notes, size: 76).shadow(color: midnight.opacity(0.2), radius: 18, y: 8)
      VStack(spacing: 8) {
        Text("A few permissions").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
        Text("So Workbench can tell you when something needs you, and be there when you want it.")
          .font(.system(size: 14)).foregroundStyle(.secondary)
      }
      VStack(spacing: 0) {
        PermissionRow(tile: .meetings, symbol: "bell.fill", title: "Notifications", detail: "PRs that need you, review requests, meetings in five minutes") {
          switch notifications {
          case .authorized, .provisional, .ephemeral:
            Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Tone.good.color)
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
        Rectangle().fill(Palette.border).frame(height: 1)
        Form { OpenAtLogin() }.formStyle(.columns).toggleStyle(.switch).padding(.vertical, 4)
          .modifier(PermissionChrome(tile: .pullRequests, symbol: "power", title: "Open at login", detail: "Keeps the menu bar count and notifications going"))
        Rectangle().fill(Palette.border).frame(height: 1)
        Form { ShortcutSetting() }.formStyle(.columns).labelsHidden().padding(.vertical, 4)
          .modifier(PermissionChrome(tile: .tickets, symbol: "command", title: "Global shortcut", detail: "Brings Workbench forward from any app"))
      }
      .padding(.horizontal, 16).padding(.vertical, 6)
      .frame(width: 560)
      .onboardingCard()
      Spacer(minLength: 0)
    }
    .task { notifications = await AppState.shared.notifier.permission() }
  }
}

private struct PermissionRow<Accessory: View>: View {
  let tile: BoardTile
  let symbol: String
  let title: String
  let detail: String
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 7).fill(tile.color).frame(width: 30, height: 30)
        .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(midnight))
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

/// The tile, words and layout of a permission row around a settings control.
private struct PermissionChrome: ViewModifier {
  let tile: BoardTile
  let symbol: String
  let title: String
  let detail: String

  func body(content: Content) -> some View {
    PermissionRow(tile: tile, symbol: symbol, title: title, detail: detail) {
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
      BoardMark(size: 96)
        .scaleEffect(shown ? 1 : 0.85)
        .shadow(color: midnight.opacity(0.25), radius: 20, y: 10)
      VStack(spacing: 8) {
        Text("You're all set").font(.system(size: 30, weight: .semibold)).tracking(-0.6)
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
      .onboardingCard()
      Spacer(minLength: 0)
    }
    .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { shown = true } }
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
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.fill, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.border))
        }
      }
      .gridColumnAlignment(.trailing)
      Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }
  }
}

// MARK: Look

private extension View {
  /// A panel as the app draws one: the card colour with a hairline border.
  func onboardingCard() -> some View {
    background(Palette.card, in: .rect(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
  }
}

/// The app's page colour, with the current step's tile colour as a faint wash from the top.
private struct OnboardingBackground: View {
  let tile: BoardTile?

  var body: some View {
    Palette.background
      .overlay(alignment: .top) {
        RadialGradient(colors: [(tile?.color ?? .clear).opacity(0.13), .clear], center: .top, startRadius: 0, endRadius: 420)
          .animation(.easeInOut(duration: 0.6), value: tile)
      }
      .ignoresSafeArea()
  }
}

/// The site's main button: solid primary with its own text colour, softly rounded.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
  var large = false
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    PrimaryBody(configuration: configuration, large: large, compact: compact)
  }

  private struct PrimaryBody: View {
    let configuration: Configuration
    let large: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .font(.system(size: large ? 15 : compact ? 12 : 13, weight: .semibold))
        .foregroundStyle(Palette.primaryText)
        .padding(.horizontal, large ? 26 : compact ? 12 : 18)
        .padding(.vertical, large ? 11 : compact ? 5 : 8)
        .background(Palette.primary, in: .rect(cornerRadius: large ? 10 : 8))
        .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        .contentShape(.rect)
    }
  }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compact ? 12 : 13, weight: .medium))
      .foregroundStyle(Palette.foreground)
      .padding(.horizontal, compact ? 12 : 16)
      .padding(.vertical, compact ? 5 : 8)
      .background(configuration.isPressed ? Palette.fill : Palette.card, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
      .contentShape(.rect)
  }
}

// MARK: Connect controls

private var connectedGreen: Color { Tone.good.color }

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
      Text(text).font(.system(size: 12)).foregroundStyle(Tone.bad.color)
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
          .background(Palette.background, in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
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
          .font(.system(size: 30, weight: .semibold, design: .monospaced))
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
            if signIns.githubBusy { ProgressView().controlSize(.small) }
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
            if signIns.linearBusy { ProgressView().controlSize(.small) }
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
          if calendar.signingIn { ProgressView().controlSize(.small) }
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
