import AppKit
import SwiftUI

// Text size, like the Claude app's zoom: every font is a Typeface, which reads like SwiftUI's Font
// (.caption.weight(.medium), .callout.monospaced()) but is sized by the window's text scale. macOS
// gives its text styles fixed sizes, so scaling Font itself isn't possible.

extension EnvironmentValues {
  /// How much bigger or smaller than macOS's sizes text is: 1 is actual size.
  @Entry var textScale: CGFloat = 1
}

struct Typeface: Sendable {
  var size: CGFloat
  var weight: Font.Weight = .regular
  var design: Font.Design = .default

  private static func style(_ style: NSFont.TextStyle, _ weight: Font.Weight = .regular) -> Typeface {
    Typeface(size: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
  }

  static let largeTitle = style(.largeTitle)
  static let title = style(.title1)
  static let title2 = style(.title2)
  static let title3 = style(.title3)
  static let headline = style(.headline, .bold)
  static let subheadline = style(.subheadline)
  static let body = style(.body)
  static let callout = style(.callout)
  static let footnote = style(.footnote)
  static let caption = style(.caption1)
  static let caption2 = style(.caption2)

  static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Typeface {
    Typeface(size: size, weight: weight, design: design)
  }
  static func system(_ style: Typeface, design: Font.Design) -> Typeface {
    Typeface(size: style.size, weight: style.weight, design: design)
  }

  func weight(_ weight: Font.Weight) -> Typeface { Typeface(size: size, weight: weight, design: design) }
  func bold() -> Typeface { weight(.bold) }
  func monospaced() -> Typeface { Typeface(size: size, weight: weight, design: .monospaced) }

  func font(_ scale: CGFloat) -> Font { .system(size: (size * scale).rounded(), weight: weight, design: design) }
}

private struct ScaledFont: ViewModifier {
  @Environment(\.textScale) private var scale
  let typeface: Typeface

  func body(content: Content) -> some View { content.font(typeface.font(scale)) }
}

private struct ScaledFrame: ViewModifier {
  @Environment(\.textScale) private var scale
  let width: CGFloat?, minWidth: CGFloat?, height: CGFloat?
  let alignment: Alignment

  func body(content: Content) -> some View {
    content
      .frame(width: width.map { ($0 * scale).rounded() }, height: height.map { ($0 * scale).rounded() }, alignment: alignment)
      .frame(minWidth: minWidth.map { ($0 * scale).rounded() }, alignment: alignment)
  }
}

extension View {
  /// A fixed size that holds text, so it grows and shrinks with the text size.
  func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
    modifier(ScaledFrame(width: width, minWidth: nil, height: height, alignment: alignment))
  }
  func scaledFrame(minWidth: CGFloat, alignment: Alignment = .center) -> some View {
    modifier(ScaledFrame(width: nil, minWidth: minWidth, height: nil, alignment: alignment))
  }

  func scaledFont(_ typeface: Typeface) -> some View { modifier(ScaledFont(typeface: typeface)) }

  /// The root of a window: text and controls at the chosen size.
  func textScale(_ scale: CGFloat) -> some View {
    environment(\.textScale, scale)
      .scaledFont(.body)
      .controlSize(scale >= 1.25 ? .large : scale <= 0.85 ? .small : .regular)
  }
}

/// The text sizes View → Zoom In and Zoom Out step through.
enum TextScale {
  static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6]

  static func larger(than scale: Double) -> Double { steps.first { $0 > scale + 0.001 } ?? steps.last! }
  static func smaller(than scale: Double) -> Double { steps.last { $0 < scale - 0.001 } ?? steps.first! }
  static func label(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}
