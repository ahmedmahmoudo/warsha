import SwiftUI

/// GitHub-flavoured Markdown as native, selectable text: headings, paragraphs, lists, quotes, code
/// blocks, tables and rules, parsed by Foundation's Markdown support. Inline HTML (comments, <br>,
/// <details>) is reduced to its text, and images are left to the gallery.
struct MarkdownView: View {
  let blocks: [MarkdownBlock]

  init(_ markdown: String) {
    blocks = MarkdownBlock.parse(markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(blocks) { block in
        view(for: block)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func view(for block: MarkdownBlock) -> some View {
    switch block.kind {
    case let .heading(level):
      Text(block.text)
        .scaledFont(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        .padding(.top, level <= 2 ? 6 : 2)
    case .paragraph:
      Text(block.text).fixedSize(horizontal: false, vertical: true)
    case let .listItem(marker):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(marker).foregroundStyle(.secondary).monospacedDigit()
        Text(block.text).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.leading, CGFloat(block.depth) * 18)
    case .code:
      ScrollView(.horizontal) {
        Text(block.text).scaledFont(.system(.callout, design: .monospaced)).padding(10)
      }
      .background(Palette.fill, in: .rect(cornerRadius: 8))
    case .quote:
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5).fill(Palette.border).frame(width: 3)
        Text(block.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    case let .table(rows):
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(cell).fontWeight(index == 0 ? .semibold : .regular)
            }
          }
          if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
        }
      }
      .padding(10)
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
    case .rule:
      Divider()
    }
  }
}

struct MarkdownBlock: Identifiable {
  enum Kind {
    case heading(Int)
    case paragraph
    case listItem(String)
    case code
    case quote
    case table([[AttributedString]])
    case rule
  }

  let id: Int
  let kind: Kind
  let text: AttributedString
  /// How deeply nested a list item is, from 0.
  var depth = 0

  /// GitHub's HTML extras, reduced to what the Markdown parser understands.
  static func clean(_ markdown: String) -> String {
    var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let replacements: [(String, String)] = [
      (#"(?s)<!--.*?-->"#, ""),
      (#"!\[[^\]]*\]\([^)]*\)"#, ""),
      (#"(?i)<img\b[^>]*>"#, ""),
      (#"(?i)<br\s*/?>"#, "\n"),
      (#"(?i)</?(details|summary|p|div|sub|sup|span|picture|source|video|a)\b[^>]*>"#, ""),
      (#"(?m)^(\s*[-*+]\s+)\[ \]"#, "$1☐"),
      (#"(?m)^(\s*[-*+]\s+)\[[xX]\]"#, "$1☑"),
    ]
    for (pattern, template) in replacements {
      text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return text
  }

  static func parse(_ markdown: String) -> [MarkdownBlock] {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard let parsed = try? AttributedString(markdown: clean(markdown), options: options) else {
      return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
    }

    var blocks: [MarkdownBlock] = []
    /// The innermost component behind each block, to join the runs of one block.
    var identities: [Int: Int] = [:]
    var table: (identity: Int, rows: [Int: [Int: AttributedString]])?

    func flushTable() {
      guard let current = table else { return }
      let rows = current.rows.keys.sorted().map { row in
        current.rows[row]!.keys.sorted().map { current.rows[row]![$0]! }
      }
      blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows), text: AttributedString()))
      table = nil
    }

    for (intent, range) in parsed.runs[\.presentationIntent] {
      guard let intent else { continue }
      var text = AttributedString(parsed[range])
      text.presentationIntent = nil
      let components = intent.components

      if let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }) {
        if table?.identity != tableComponent.identity {
          flushTable()
          table = (tableComponent.identity, [:])
        }
        var row = 0
        var column = 0
        for component in components {
          switch component.kind {
          case .tableHeaderRow: row = 0
          case let .tableRow(index): row = index + 1
          case let .tableCell(index): column = index
          default: break
          }
        }
        table!.rows[row, default: [:]][column, default: AttributedString()] += text
        continue
      }
      flushTable()

      // A run belongs to the same block as the one before when their innermost component matches.
      if let last = blocks.last, let lastIdentity = identities[last.id], lastIdentity == components.first?.identity {
        blocks[blocks.count - 1] = MarkdownBlock(id: last.id, kind: last.kind, text: last.text + text, depth: last.depth)
        continue
      }

      let lists = components.filter { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }
      var kind: Kind = .paragraph
      if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
        kind = .code
      } else if let heading = components.lazy.compactMap({ if case let .header(level) = $0.kind { level } else { nil } }).first {
        kind = .heading(heading)
      } else if components.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) {
        kind = .rule
      } else if let item = components.lazy.compactMap({ if case let .listItem(ordinal) = $0.kind { ordinal } else { nil } }).first {
        let ordered = lists.first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
        kind = .listItem(ordered ? "\(item)." : "•")
      } else if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
        kind = .quote
      }
      if case .code = kind, text.characters.last == "\n" { text.characters.removeLast() }
      let block = MarkdownBlock(id: blocks.count, kind: kind, text: text, depth: max(0, lists.count - 1))
      identities[block.id] = components.first?.identity
      blocks.append(block)
    }
    flushTable()
    return blocks.filter { block in
      if case .rule = block.kind { return true }
      if case .table = block.kind { return true }
      return !String(block.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}
