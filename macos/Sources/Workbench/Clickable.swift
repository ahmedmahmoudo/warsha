import SwiftUI

extension View {
  /// Marks something you can click, the way the web version does: the pointing-hand cursor, and a
  /// hover highlight (buttons and chips brighten a little; text links underline). Standard Mac
  /// controls give no hover feedback, which made links and buttons on the PR pages feel dead.
  func clickable(underline: Bool = false) -> some View {
    modifier(Clickable(underline: underline))
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
