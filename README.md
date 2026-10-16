# Workbench

A personal dashboard. Today: open PRs with their Linear tickets and the real gate state.
Next: Slack catch-up (mentions, replies, unread DMs) and a weekly activity view.

## Run

```bash
cp .env.example .env.local   # then fill it in
npm install
npm run dev                  # web on http://localhost:5179, API on :8787
```

## Layout

```
server/
  index.ts              Hono app — mounts one route per page
  env.ts                .env.local loading; a missing key means "not configured", not a crash
  lib/swrCache.ts       serve cached, refresh in the background (upstream calls are seconds away)
  integrations/         one file per external API (GitHub, Linear; Slack goes here)
  prs/                  the Pull Requests page: route + pure derivation of status/mismatches
shared/                 types the server and the UI both read
src/                    Vite + React, TanStack Router (code-based routes) and Query
  components/ui/        shadcn components (`npx shadcn@latest add <name>`)
  theme/                light / midnight dark / system; System follows the OS live
```

Colours are shadcn's CSS variables in `src/styles.css` (`:root` light, `.dark` midnight), plus
`faint` and the `good`/`bad`/`warn`/`info` status tones. Use those names; don't add raw colours.

Adding a page: an integration in `server/integrations/`, a route under `server/<page>/`,
its response type in `shared/`, a page in `src/routes/`, and a nav entry in `AppShell`.

## How a PR's status is read

- Only **required** checks decide "CI failing"; advisory ones are listed but don't count.
  When the required aggregate (`Required CI`) fails, the row names the checks behind it.
- The first thing the author must act on wins: conflicts → required CI → changes requested
  → CodeRabbit changes → CI running → unresolved threads → behind base → ready → needs reviewer.
- **Reviewing** covers review requests made to you personally (not CODEOWNERS teams) plus PRs
  you reviewed in the last 14 days. **Team** is the logins in `GITHUB_TEAM`.
