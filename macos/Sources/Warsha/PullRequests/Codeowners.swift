import Foundation

/// Reads a CODEOWNERS file the way GitHub does: gitignore-style patterns, and the last matching
/// line wins. A line with a pattern but no owners removes ownership for those paths.
/// server/prs/codeowners.ts in Swift.
struct Codeowners: Sendable {
  private struct Rule: @unchecked Sendable {
    let pattern: NSRegularExpression
    let owners: [String]
  }

  private let rules: [Rule]

  init(_ text: String) {
    rules = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
      let content = line.replacingOccurrences(of: #"(^|\s)#.*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      guard !content.isEmpty else { return nil }
      let parts = content.split(whereSeparator: \.isWhitespace).map(String.init)
      return Rule(pattern: Self.regex(parts[0]), owners: parts.dropFirst().filter { $0.hasPrefix("@") })
    }
  }

  func ownersOf(_ path: String) -> [String] {
    let range = NSRange(path.startIndex..., in: path)
    return rules.last { $0.pattern.firstMatch(in: path, range: range) != nil }?.owners ?? []
  }

  static func pattern(_ raw: String) -> String {
    let directoryOnly = raw.hasSuffix("/")
    var pattern = directoryOnly ? String(raw.dropLast()) : raw
    // A slash anywhere but the end anchors the pattern to the repo root, as in .gitignore.
    let anchored = pattern.hasPrefix("/") || pattern.contains("/")
    if pattern.hasPrefix("/") { pattern.removeFirst() }

    let prefix = anchored ? "^" : "^(?:.*/)?"
    // A directory pattern matches everything inside it; a plain one matches the path itself or, if
    // it names a directory, everything inside that. Unlike .gitignore, GitHub doesn't let a trailing
    // "*" reach into subdirectories: "docs/*" owns docs/a.md but not docs/build/b.md.
    let trailingStar = pattern.hasSuffix("*") && !pattern.hasSuffix("**")
    let suffix = directoryOnly ? "/.*$" : trailingStar ? "$" : "(?:/.*)?$"
    return prefix + glob(pattern) + suffix
  }

  private static func regex(_ raw: String) -> NSRegularExpression {
    // A pattern that can't compile matches nothing rather than taking the file down with it.
    (try? NSRegularExpression(pattern: pattern(raw))) ?? (try! NSRegularExpression(pattern: "(?!)"))
  }

  private static func glob(_ glob: String) -> String {
    let characters = Array(glob)
    var out = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      if character == "*", next == "*" {
        // "**/" matches zero or more directories; a bare "**" matches anything.
        if index + 2 < characters.count, characters[index + 2] == "/" {
          out += "(?:.*/)?"
          index += 2
        } else {
          out += ".*"
          index += 1
        }
      } else if character == "*" {
        out += "[^/]*"
      } else if character == "?" {
        out += "[^/]"
      } else {
        out += NSRegularExpression.escapedPattern(for: String(character))
      }
      index += 1
    }
    return out
  }
}
