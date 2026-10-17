# Resources

`Assets.xcassets` is compiled into the app by `build.sh` (actool).

**AccentColor** is the app's accent: selection, prominent buttons, the active filter. In light mode
it's the web version's `--primary` (`#1c1c1a`). In dark mode the web's primary is a near-white
(`#dbe4f3`, meant for dark text), but macOS draws white text on the accent, so dark mode uses the
web palette's midnight slate (`--ring`, `#4b5d7d`) to keep selected text readable.

If you choose an accent colour other than Multicolor in System Settings → Appearance, macOS uses
yours instead, as it does for every app.

`actool` needs Xcode's first-launch setup (`xcodebuild -runFirstLaunch`). Without it, `build.sh`
skips the catalog with a warning, and the app still applies the same colour through SwiftUI's
`.tint` (`Color.workbenchAccent` in `Theme.swift`). That covers buttons, toggles and links, but not
list selection, which then uses the system accent.
