# Resources

`Assets.xcassets` holds the app icon (`AppIcon`, from `design/icon-v2/c-board-macos.svg`: the board on the macOS icon grid) and the accent colour.

**AccentColor** is the app's accent: selection, prominent buttons, the active filter, and the text of
buttons and links. In light mode it's the web version's `--primary` (`#1c1c1a`). In dark mode macOS
uses it two ways: white text on it (selection) and it as text on the navy page (buttons, links). The
web's near-white primary (`#dbe4f3`) fails the first and its slate (`--ring`, `#4b5d7d`) the second,
so dark mode uses `#4f74d0`, a mid blue from the web's info family that reads about 4.5:1 and 4.2:1.

If you choose an accent colour other than Multicolor in System Settings → Appearance, macOS uses
yours instead, as it does for every app.

Xcode compiles the catalog (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `project.yml`).
`build-swiftpm.sh` compiles it with `actool`, which needs Xcode's first-launch setup
(`xcodebuild -runFirstLaunch`); without it, that build skips the catalog and the app still applies the
same colour through SwiftUI's `.tint` (`Color.warshaAccent` in `Theme.swift`), everywhere but list
selection.
