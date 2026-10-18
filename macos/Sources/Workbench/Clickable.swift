import SwiftUI

extension View {
  /// Marks something you can click, the way the web version does: the pointing-hand cursor, and a
  /// hover highlight (buttons and chips brighten a little; text links underline). Standard Mac
  /// controls give no hover feedback, which made links and buttons on the PR pages feel dead.
  func clickable(underline: Bool = false) -> some View {
    modifier(Clickable(underline: underline))
  }
}

/// A vertical scroll view whose content ignores the pointer while it scrolls. Content moving under
/// a still pointer makes SwiftUI hit-test every hover, tooltip and glass button on every frame,
/// which on Today took most of each frame; with hit testing off there's nothing to test.
struct PageScrollView<Content: View>: View {
  @ViewBuilder let content: Content
  @State private var scrolling = false

  var body: some View {
    ScrollView { content.allowsHitTesting(!scrolling) }
      .onScrollPhaseChange { _, phase in scrolling = phase.isScrolling }
  }
}

private struct Clickable: ViewModifier {
  let underline: Bool
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let active = hovering && isEnabled
    content
      .underline(underline && active)
      .brightness(active && !underline ? (colorScheme == .dark ? 0.08 : -0.04) : 0)
      .pointerStyle(isEnabled ? .link : nil)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: active)
  }
}

/// A small action in a row (Open check, Reply, Copy link) as a glass capsule in its tone. Its
/// padding is in proportion to its text, so it keeps its shape at every text size, which macOS's
/// fixed control sizes don't. `prominent` fills it with the tone, for the one main action.
struct PillButtonStyle: ButtonStyle {
  var tone: Tone = .neutral
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, tone: tone, prominent: prominent)
  }
}

private struct PillBody: View {
  let configuration: ButtonStyleConfiguration
  let tone: Tone
  let prominent: Bool
  @Environment(\.textScale) private var scale
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let fill: Color = prominent ? (tone == .neutral ? .workbenchAccent : tone.color) : tone == .neutral ? Palette.card.opacity(0.7) : tone.soft
    configuration.label
      .labelStyle(PillLabelStyle())
      .scaledFont(.subheadline.weight(.medium))
      .lineLimit(1)
      .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : tone == .neutral ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(tone.color))
      .padding(.horizontal, (10 * scale).rounded())
      .padding(.vertical, (4 * scale).rounded())
      .contentShape(.capsule)
      .glassEffect(.regular.tint(fill).interactive(), in: .capsule)
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
  }
}

/// An icon and title close together, the icon a little smaller, as in a toolbar button.
private struct PillLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}

extension ButtonStyle where Self == PillButtonStyle {
  static var pill: PillButtonStyle { PillButtonStyle() }
  static func pill(_ tone: Tone, prominent: Bool = false) -> PillButtonStyle { PillButtonStyle(tone: tone, prominent: prominent) }
}
