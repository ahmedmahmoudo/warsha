import SwiftUI

// Placeholders shaped like what's loading, shown only on a page's first load. A reload keeps what's
// on screen and swaps in the new answer, so these never replace content you're reading.

/// A grey bar standing in for a line of text, pulsing gently while it waits.
struct SkeletonBar: View {
  var width: CGFloat? = nil
  var height: CGFloat = 10
  @State private var dim = false

  var body: some View {
    RoundedRectangle(cornerRadius: height / 2)
      .fill(Palette.fill)
      .frame(width: width, height: height)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
      .opacity(dim ? 0.45 : 1)
      .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
      .onAppear { dim = true }
      .accessibilityHidden(true)
  }
}

/// A row: a short chip, a title line and a detail line, in the shape of a PR or ticket row.
struct SkeletonRow: View {
  /// Varies the line lengths so a list of them doesn't look like stripes.
  var seed = 0

  var body: some View {
    let widths: [CGFloat] = [0.72, 0.55, 0.64, 0.48, 0.8]
    let title = widths[seed % widths.count]
    VStack(alignment: .leading, spacing: 7) {
      SkeletonBar(width: 70, height: 12)
      GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 7) {
          SkeletonBar(width: proxy.size.width * title, height: 11)
          SkeletonBar(width: proxy.size.width * (title - 0.2), height: 8)
        }
      }
      .frame(height: 26)
    }
    .padding(.vertical, 8)
  }
}

/// A panel of skeleton rows, in place of a Today or Activity panel that hasn't loaded yet.
struct SkeletonPanel: View {
  let title: String
  var rows = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).scaledFont(.callout.weight(.semibold)).foregroundStyle(.secondary)
      ForEach(0 ..< rows, id: \.self) { index in
        if index > 0 { Divider().overlay(Palette.border) }
        SkeletonRow(seed: index)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.card, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading \(title)")
  }
}
