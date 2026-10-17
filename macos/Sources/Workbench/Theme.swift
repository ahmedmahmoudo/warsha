import AppKit
import SwiftUI

/// The web version's palette (src/styles.css: `:root` for light, `.dark` for midnight). The window
/// background is the web's, so the Liquid Glass sidebar and toolbar take on its tint; text uses
/// its foreground, muted and faint as the primary, secondary and tertiary styles.
enum Palette {
  static let background = Color.dynamic(light: 0xF7F7F5, dark: 0x0E1420)
  static let border = Color.dynamic(light: 0xE4E4DF, dark: 0x253045)
  /// `--muted` as a fill: neutral chips and placeholders.
  static let fill = Color.dynamic(light: 0xF1F1EE, dark: 0x1D2738)

  static let foreground = PaletteText(light: 0x1C1C1A, dark: 0xE4E9F1, onAccent: 1)
  static let muted = PaletteText(light: 0x6B6B66, dark: 0x9AA7BB, onAccent: 0.85)
  static let faint = PaletteText(light: 0x9A9A94, dark: 0x66738A, onAccent: 0.65)
}

/// A text colour from the palette that turns white on a selected row, as the system's own styles
/// do; otherwise light mode's near-black text would vanish on the near-black accent.
struct PaletteText: ShapeStyle {
  let light: UInt32
  let dark: UInt32
  let onAccent: Double

  func resolve(in environment: EnvironmentValues) -> Color.Resolved {
    if environment.backgroundProminence == .increased { return Color.white.opacity(onAccent).resolve(in: environment) }
    return Color(nsColor: NSColor(rgb: environment.colorScheme == .dark ? dark : light)).resolve(in: environment)
  }
}

extension View {
  /// The web's page: its background behind a list or form, and its text colours.
  func workbenchPage() -> some View {
    scrollContentBackground(.hidden)
      .background(Palette.background)
      .foregroundStyle(Palette.foreground, Palette.muted, Palette.faint)
  }
}

/// The web version's status tones, following the window's appearance.
extension Tone {
  var color: Color {
    switch self {
    case .good: .dynamic(light: 0x1F7A4D, dark: 0x5CC79A)
    case .bad: .dynamic(light: 0xB42318, dark: 0xF2867C)
    case .warn: .dynamic(light: 0xA15C07, dark: 0xE8B45A)
    case .info: .dynamic(light: 0x2F5BD3, dark: 0x8FB0F5)
    case .neutral: .secondary
    }
  }

  /// The tone's soft background, for chips.
  var soft: Color {
    switch self {
    case .good: .dynamic(light: 0xE3F3EA, dark: 0x12302A)
    case .bad: .dynamic(light: 0xFDE8E6, dark: 0x3A1D26)
    case .warn: .dynamic(light: 0xFDF1DC, dark: 0x33291A)
    case .info: .dynamic(light: 0xE6ECFC, dark: 0x1A2846)
    case .neutral: Palette.fill
    }
  }
}

extension Color {
  /// The app's accent: the web's primary in light mode, its midnight slate in dark mode, where the
  /// web's near-white primary can't carry the white text macOS draws on the accent. Matches
  /// AccentColor in Resources/Assets.xcassets, which also covers what `.tint` can't, like list selection.
  static let workbenchAccent = dynamic(light: 0x1C1C1A, dark: 0x4B5D7D)

  /// A colour that changes with light and dark appearance, from 0xRRGGBB values.
  static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return NSColor(rgb: isDark ? dark : light)
    })
  }

  /// "#5e6ad2", as Linear sends state colours.
  init?(hex: String) {
    guard let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
    self.init(nsColor: NSColor(rgb: value))
  }
}

private extension NSColor {
  convenience init(rgb: UInt32) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
    )
  }
}
