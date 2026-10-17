# Workbench for macOS

A native shell around Workbench: a Swift (AppKit) app with a Dock icon, a menu bar item and a window
that shows the existing pages in a `WKWebView`. It starts the Node server from this checkout on
http://127.0.0.1:5181 when it opens, restarts it if it dies, and stops it on quit, so it replaces the
launchd service (`npm run service:stop` once you've switched).

```bash
npm run app:build      # build macos/build/Workbench.app
npm run app:install    # build, copy to ~/Applications and open it
```

The app runs the server from this checkout, so it uses this folder's `.env.local`, `data/` and
`node_modules`. After changing server code, use **Restart Server** in the menu bar item. After
changing pages, `npm run build` and reload (⌘R). Rebuild the app only when `macos/` changes.
The server's output goes to `~/Library/Logs/Workbench/server.log`.

- Links to GitHub, Linear and other sites open in your default browser. Google sign-in does too,
  since Google refuses embedded browsers. Finish it there, then come back.
- Closing the window keeps the app in the menu bar. Click the Dock icon or ⌘0 to bring it back.
- Right-click → Inspect Element opens Web Inspector for the pages.

## Layout

```
Sources/Workbench/
  AppDelegate.swift     launch, main menu, menu bar item
  MainWindow.swift      the WKWebView window, external links, alert/confirm
  ServerProcess.swift   starts, watches, restarts and stops the Node server
  Config.swift          port, checkout and node paths (written into Info.plist by build.sh)
build.sh                swift build, then bundle, icon and sign Workbench.app
```

## Roadmap

Each phase ships on its own. Native features live in Swift and save through the server's API, so
the pages can show them next to PRs, tickets and meetings.

1. **Shell** (done): window, menu bar item, server supervision, build script.
2. **Everyday app**: open at login (`SMAppService`), a Dock and menu bar badge with the "Needs you
   now" count, native notifications for new Needs-you items and upcoming meetings (with actions
   like Open PR), and a global shortcut to bring Workbench forward.
3. **Signing**: a stable self-signed identity in place of ad-hoc signing, so macOS keeps
   Accessibility permission across rebuilds. Needed before phase 4's window titles.
4. **App usage tracking**: frontmost app from `NSWorkspace` activation events (no permission),
   idle, lock and sleep from the system, and window titles via Accessibility (opt-in). Stored as
   sessions in Workbench's SQLite file through a new `/api/usage` route.
5. **Breaks**: timers based on continuous active time, a notification first and an optional
   full-screen break across all displays, skipped during calendar meetings.
6. **Stats**: a Focus page with focus blocks, context switches and meeting load, joined with the
   PRs and tickets you touched each day.
7. **Later, if it pays off**: move the menu bar popover and the breaks screen to SwiftUI, and
   eventually drop Node once nothing needs it.
