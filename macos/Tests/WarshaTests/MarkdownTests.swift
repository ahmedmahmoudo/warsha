import Testing
@testable import Warsha

struct MarkdownTests {
  @Test func readsAPullRequestTemplate() {
    let blocks = MarkdownBlock.parse(
      """
      <!-- Describe your change -->
      ## Summary
      Adds **the thing** with `code`.<br>Second line.

      - [x] Tested
      - [ ] Docs
        - nested

      1. First
      2. Second

      > Quoted

      ```ts
      const a = 1
      ```

      | Col A | Col B |
      | --- | --- |
      | 1 | 2 |

      ---
      ![shot](https://example.com/a.png)
      <img src="https://example.com/b.png" width="300">
      """
    )
    let kinds = blocks.map { block -> String in
      switch block.kind {
      case let .heading(level): "h\(level)"
      case .paragraph: "p"
      case let .listItem(marker): "li\(block.depth)\(marker)"
      case .code: "code"
      case .quote: "quote"
      case let .table(rows): "table\(rows.count)x\(rows.first?.count ?? 0)"
      case .rule: "rule"
      }
    }
    #expect(kinds == ["h2", "p", "li0•", "li0•", "li1•", "li01.", "li02.", "quote", "code", "table2x2", "rule"])
    #expect(String(blocks[1].text.characters).contains("Second line"))
    #expect(String(blocks[2].text.characters) == "☑ Tested")
    #expect(String(blocks[8].text.characters) == "const a = 1")
    #expect(!blocks.contains { String($0.text.characters).contains("Describe your change") })
  }
}
