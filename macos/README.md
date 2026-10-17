# Workbench for macOS

Workbench as a native macOS app: SwiftUI pages, a menu bar item, credentials in the Keychain and
Workbench's own data in SQLite. No Node server and no web view. It needs macOS 26 or later and uses
the Liquid Glass design. It's being ported from the web
version one page at a time. Until a page is ported, it links to the web version (the launchd
service on http://localhost:5180), so keep that running for now.

```bash
npm run app:build      # build macos/build/Workbench.app
npm run app:install    # build, copy to ~/Applications and open it
swift test --package-path macos
WORKBENCH_PARITY=1 swift test --package-path macos --filter PrParity   # vs the web version on :5180
```

**First run:** open Settings (⌘,) → Data and import the web version's `.env.local`, which fills in
the tokens and preferences, and `data/workbench.sqlite`, which brings over pins, notes, todos and
parked items. Then test each account under Accounts.

The app is ad-hoc signed, so macOS treats every rebuild as a new app, and the Keychain asks again
before letting it read its credentials. Choose Always Allow. A stable signing identity (phase 2)
ends that.

## Layout

```
Sources/Workbench/
  WorkbenchApp.swift    scenes (window, Settings, menu bar item), pages, Go menu
  ContentView.swift     sidebar and pages; pages not ported yet link to the web version
  SettingsView.swift    accounts, general preferences, data import
  AppSettings.swift     what .env.local held: secrets in the Keychain, the rest in UserDefaults
  Keychain.swift        generic passwords under the service com.workbench.app
  Store.swift           pins, notes, todos, parked, settings: server/store/repo.ts in Swift
  Database.swift        a small wrapper over the system SQLite library
  Integrations.swift    GitHub and Linear GraphQL clients, Linear ticket lookup
  PullRequests/         the Pull Requests page: GitHub queries (GitHubPrs), status rules (Derive),
                        CODEOWNERS, the loader with its caches (PrService), and the views
Tests/WorkbenchTests/   swift-testing tests; PrParityTests compares with the running web version
build.sh                swift build, then bundle, icon and sign Workbench.app
```

The database is `~/Library/Application Support/Workbench/workbench.sqlite`. It uses the same schema
and migrations as `server/store/db.ts`, so a file from either version opens in the other.

## Port plan

Each step ships on its own. Each port keeps the web version's rules (the README at the repo root
describes them), and the TypeScript is the reference.

1. **Foundation** (done): SwiftUI app, Settings with Keychain credentials and import from the web
   version, the SQLite store, GitHub and Linear clients with connection checks.
2. **Signing**: a stable self-signed identity, so the Keychain and later Accessibility permissions
   survive rebuilds.
3. **Pull Requests list** (done): GitHub search and details, status and merge blockers, CODEOWNERS,
   Linear tickets, the token check, Mine / Reviewing / Team, the waiting-on cards, and parked PRs.
   The page reloads every 30 seconds while it's open. Pin and unpin are in each row's context menu;
   parking with a reason comes with Today. A PR's title opens it on GitHub until the details page
   is ported.
4. **PR details**: description (rendered Markdown), timeline, threads, checks with live polling,
   Merge status, and the Actions (Update branch, open in Claude).
5. **Today**: Needs you now, Up next, New for you, Deadlines, Waiting on others, plus pins, notes,
   todos and parking (with posting the reason to Linear and GitHub).
6. **Google Calendar**: sign-in via `ASWebAuthenticationSession`, meeting sync with reschedule and
   deletion tracking, the Calendar page, and meetings on Today.
7. **Activity**: Day, Week and Month views, stuck-ticket flags, Copy summary.
8. **Native extras**: Dock and menu bar badge, notifications, open at login, global shortcut.
9. **Productivity**: app usage tracking (`NSWorkspace`, idle and lock), breaks, focus stats.

When step 7 is done, the web version (`server/`, `src/`, `shared/`) and the launchd service can go.
