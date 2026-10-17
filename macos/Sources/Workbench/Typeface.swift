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
  /// The macOS text style it is, if any: at actual size it's drawn as that style, exactly as before.
  var style: Font.TextStyle?
  var size: CGFloat
  /// nil keeps the style's own weight (headline is bold).
  var weight: Font.Weight?
  var design: Font.Design = .default

  private static func style(_ style: Font.TextStyle, _ nsStyle: NSFont.TextStyle) -> Typeface {
    Typeface(style: style, size: NSFont.preferredFont(forTextStyle: nsStyle).pointSize)
  }

  static let largeTitle = style(.largeTitle, .largeTitle)
  static let title = style(.title, .title1)
  static let title2 = style(.title2, .title2)
  static let title3 = style(.title3, .title3)
  static let headline = style(.headline, .headline)
  static let subheadline = style(.subheadline, .subheadline)
  static let body = style(.body, .body)
  static let callout = style(.callout, .callout)
  static let footnote = style(.footnote, .footnote)
  static let caption = style(.caption, .caption1)
  static let caption2 = style(.caption2, .caption2)

  static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> Typeface {
    Typeface(size: size, weight: weight, design: design)
  }
  static func system(_ style: Typeface, design: Font.Design) -> Typeface {
    Typeface(style: style.style, size: style.size, weight: style.weight, design: design)
  }

  func weight(_ weight: Font.Weight) -> Typeface { Typeface(style: style, size: size, weight: weight, design: design) }
  func bold() -> Typeface { weight(.bold) }
  func monospaced() -> Typeface { Typeface(style: style, size: size, weight: weight, design: .monospaced) }

  func font(_ scale: CGFloat) -> Font {
    if scale == 1, let style {
      let font = Font.system(style, design: design)
      return weight.map { font.weight($0) } ?? font
    }
    let defaultWeight: Font.Weight = style == .headline ? .bold : .regular
    return .system(size: (size * scale).rounded(), weight: weight ?? defaultWeight, design: design)
  }
}

private struct ScaledFont: ViewModifier {
  @Environment(\.textScale) private var scale
  let typeface: Typeface

  func body(content: Content) -> some View { content.font(typeface.font(scale)) }
}

private struct ScaledControlSize: ViewModifier {
  @Environment(\.textScale) private var scale
  let size: ControlSize

  func body(content: Content) -> some View { content.font(nil).controlSize(size.scaled(scale)) }
}

extension ControlSize {
  /// One step per text size range: smaller below 90%, bigger from 120%, two bigger from 150%.
  func scaled(_ scale: CGFloat) -> ControlSize {
    let sizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
    let step = scale >= 1.5 ? 2 : scale >= 1.2 ? 1 : scale < 0.9 ? -1 : 0
    let index = sizes.firstIndex(of: self) ?? 2
    return sizes[min(max(index + step, 0), sizes.count - 1)]
  }
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

  /// The root of a window: text at the chosen size. Native controls keep their size, toolbar ones
  /// included, as their text doesn't scale; a view scales one on purpose with scaledControlSize.
  func textScale(_ scale: CGFloat) -> some View {
    // The scale goes outermost: the base font below reads it.
    scaledFont(.body)
      .environment(\.textScale, scale)
  }

  /// A control's size, a step bigger or smaller with the text size. The control keeps its own
  /// system font: a scaled font in a fixed-height bezel (bordered buttons) leaves it no padding.
  func scaledControlSize(_ size: ControlSize) -> some View { modifier(ScaledControlSize(size: size)) }
}

/// The text sizes View → Zoom In and Zoom Out step through.
enum TextScale {
  static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6]

  static func larger(than scale: Double) -> Double { steps.first { $0 > scale + 0.001 } ?? steps.last! }
  static func smaller(than scale: Double) -> Double { steps.last { $0 < scale - 0.001 } ?? steps.first! }
  static func label(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}
