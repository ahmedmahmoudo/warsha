# Warsha for macOS: what's left

What we've agreed on but haven't finished, with enough detail to pick each item up. Tick items off
here as they land. Done work is described in [README.md](README.md) under "Port plan".

## To build

- [ ] **Step 9: Productivity.** App usage tracking (`NSWorkspace` active app, idle and screen
      lock), break reminders and focus stats. Not started; to be designed first.
- [ ] **Pointer on links in PR descriptions.** Links inside a paragraph of the rendered Markdown
      (`PullRequests/Detail/MarkdownView.swift`) show no pointing hand or hover, because SwiftUI
      gives inline links none. The fix is rendering paragraphs with links through an `NSTextView`
      (via `NSViewRepresentable`), which shows the pointer on links. Everything else clickable
      has `.clickable()`.
- [ ] **Distribution signing.** Builds are signed with an Apple Development certificate, so on
      someone else's Mac the first launch needs right-click → Open. To hand the app out cleanly:
      a Developer ID Application certificate (paid Apple Developer Program), then notarize
      (`xcrun notarytool submit … --wait`) and staple (`xcrun stapler staple`). See "Sharing it"
      in the README.

## Waiting on someone

- [ ] **Try GitHub sign-in in the app.** Settings → Accounts → Sign in with GitHub (device flow).
      Tested outside the app only: the code and token work.
- [ ] **everlab-au approves Warsha's GitHub app.** The org has OAuth app access restrictions,
      so a signed-in token gets 403 on everything in it until an org owner approves Warsha
      (org Settings → Third-party access → OAuth app policy). Members can request it at
      github.com/settings/applications. Until then: a pasted token or "Use gh CLI token". Every
      organization that restricts OAuth apps has to approve it once; the apps are under the
      author's personal account on purpose, so Warsha isn't Everlab-only.
- [ ] **GitHub token renewal.** The GitHub OAuth app issues tokens that expire after 8 hours,
      with a refresh token. Warsha renews them without a client secret
      (`GitHubSignIn.refresh` in `SignIn.swift`), which is unproven: the first renewal is about
      8 hours after signing in. If it fails, Settings asks to sign in again. Alternatively turn off
      token expiration in the GitHub OAuth app's settings (Optional features).
- [ ] **Publish and verify the Google OAuth app.** Google Auth Platform → Audience → Publish app
      (until then only listed test users can connect, and refresh tokens expire after 7 days).
      `calendar.readonly` is a sensitive scope: unverified, people see "Google hasn't verified
      this app" and it's capped at 100 users. Verification needs, under Branding: name, logo
      (`design/icon-v2/google-oauth-logo-120.png`), support email, a home page and a privacy policy
      on a domain you own (verified in Search Console, listed under Authorised domains). Under
      Verification Centre: a scope justification and a demo video of the sign-in and the meetings
      showing in Warsha. No security assessment is needed (sensitive, not restricted).
  - [ ] Home page and privacy policy pages (the policy: runs on your Mac, calendar data goes only
        from Google to your Mac and stays there, nothing goes to any other server, how to
        disconnect).

## Built but not tried by hand

- [ ] Notifications (Settings → Notifications): PRs needing you or ready to merge, review
      requests, meetings five minutes before, moved or deleted meetings.
- [ ] Global shortcut ⌃⌥⌘W, and changing it.
- [ ] Open at login, from the installed copy (`npm run app:install`).
- [ ] Connect Google Calendar with the built-in client.
- [ ] Park with a reason, posting it to Linear and the PRs.

## Loose ends

- [ ] **Web version icons.** `public/` still has the old icon; the v2 favicons and app icons are
      in `design/icon-v2/`.
- [ ] **Retire the web version?** The native app now covers everything the web version did. If
      you're happy with it, `server/`, `src/`, `shared/` and the launchd service can go. The
      parity tests (`WARSHA_PARITY=1`) compare against the running web version, so they'd go
      too, and `.env.local` with them (`-WarshaEnvFile` reads it for dev launches).
