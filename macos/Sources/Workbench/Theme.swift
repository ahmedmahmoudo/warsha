import AppKit
import SwiftUI

/// The web version's status tones (src/styles.css: `:root` for light, `.dark` for midnight), as
/// colours that follow the window's appearance. Backgrounds stay the system's, so Liquid Glass
/// works.
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
    case .neutral: Color(nsColor: .quaternarySystemFill)
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
