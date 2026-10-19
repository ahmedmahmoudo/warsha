import SwiftUI

// Workbench's icon, drawn in SwiftUI from its source, design/icon-v2/c-board-macos.svg (the same
// file as design/website/brand/macos-app-icon.svg), so it can be shown at any size and animated
// piece by piece. Every number below is that file's: keep the two in step when the icon changes.

/// The app icon exactly as the Dock shows it: the midnight body on Apple's icon grid (an 824-point
/// body inset 100 points in a 1024 canvas, 185-point corners) with its hairline edge and shadow,
/// and the board of four tiles at 10.3× its 64-unit web size. `progress` builds it, 0 (nothing) to
/// 1 (done): the body settles in, each tile pops in, then each glyph draws itself, as an SVG
/// animation would. It animates with `withAnimation`.
struct AppIcon: View, Animatable {
  /// The whole canvas, margin included, as an app icon is sized.
  let size: CGFloat
  var progress: Double = 1

  nonisolated var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let unit = size / 1024
    let boardScale = 10.3 * unit
    let body = phase(0, 0.22)
    ZStack {
      RoundedRectangle(cornerRadius: 185 * unit, style: .circular)
        .fill(LinearGradient(colors: [midnightTop, midnight], startPoint: .top, endPoint: .bottom))
        .overlay(
          RoundedRectangle(cornerRadius: 184.5 * unit, style: .circular)
            .strokeBorder(BoardTile.notes.color.opacity(0.12), lineWidth: max(2 * unit, 0.5))
        )
        .frame(width: 824 * unit, height: 824 * unit)
        .shadow(color: .black.opacity(0.3), radius: 12 * unit, y: 10 * unit)
        .scaleEffect(0.92 + 0.08 * body)
        .opacity(body)
      ForEach(Array(BoardTile.allCases.enumerated()), id: \.offset) { index, tile in
        let pop = phase(0.14 + Double(index) * 0.09, 0.26)
        let draw = phase(0.4 + Double(index) * 0.1, 0.3)
        let origin = tile.boardOrigin
        RoundedRectangle(cornerRadius: 5 * boardScale, style: .circular)
          .fill(tile.color)
          .overlay {
            tile.glyph
              .trimmedPath(from: 0, to: draw)
              .applying(CGAffineTransform(scaleX: boardScale, y: boardScale))
              .stroke(midnight, style: StrokeStyle(lineWidth: 2.4 * boardScale, lineCap: tile == .tickets ? .butt : .round, lineJoin: .round))
          }
          .frame(width: 21.5 * boardScale, height: 21.5 * boardScale)
          .scaleEffect(0.5 + 0.5 * spring(pop))
          .opacity(min(pop * 2, 1))
          // The board's 64-unit square is centred: a point x maps to 512 + (x − 32) × 10.3.
          .position(
            x: (512 + (origin.x + 10.75 - 32) * 10.3) * unit,
            y: (512 + (origin.y + 10.75 - 32) * 10.3) * unit
          )
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel("Workbench")
  }

  /// How far along a piece is: 0 before `start`, 1 after `start + length`.
  private func phase(_ start: Double, _ length: Double) -> Double {
    min(max((progress - start) / length, 0), 1)
  }

  /// A little overshoot, as a tile landing.
  private func spring(_ t: Double) -> Double {
    t >= 1 ? 1 : 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2)
  }
}

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

  /// Where the tile sits on the board, in the icon's 64-unit board square.
  var boardOrigin: CGPoint {
    switch self {
    case .pullRequests: CGPoint(x: 9, y: 9)
    case .meetings: CGPoint(x: 33.5, y: 9)
    case .tickets: CGPoint(x: 9, y: 33.5)
    case .notes: CGPoint(x: 33.5, y: 33.5)
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
let midnight = Color(red: 0x0E / 255, green: 0x14 / 255, blue: 0x20 / 255)
let midnightTop = Color(red: 0x1D / 255, green: 0x27 / 255, blue: 0x38 / 255)

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

