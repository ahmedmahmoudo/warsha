# Workbench

A personal dashboard: what needs you today, open PRs with their Linear tickets and the real gate
state, and a calendar of what you did.

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
  lib/swrCache.ts       serve cached, refresh in the background (upstream calls are seconds away);
                        `?maxAge=<s>` makes a request wait for a copy that recent, `?fresh=1` rebuilds
  integrations/         one file per external API (GitHub, Linear)
  store/                Workbench's own data in SQLite (node:sqlite): pins, notes, todos, parked, settings
  today/                the Today page: ranking, needs-you rules, deadlines
  prs/                  the Pull Requests list and details pages: routes, CODEOWNERS matching,
                        pure derivation of status, merge blockers and activity (detail.ts)
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
  → CodeRabbit changes → CI running → unresolved threads → behind base → needs code owner
  / approvals → ready.
- **Needs approval from** lists only who blocks the merge under the base branch's rules
  (rulesets and branch protection). With code-owner review required, each changed file is
  matched against the base branch's `CODEOWNERS`; an owner group clears once someone approves
  as that user or on behalf of that team. Other requested reviewers count as optional.
  Rulesets that also restrict pushes are skipped: only their bypass actors can merge, and
  those skip the rules anyway.
- **Reviewing** covers review requests made to you personally (not CODEOWNERS teams) plus PRs
  you reviewed in the last 14 days. **Team** is the logins in `GITHUB_TEAM`.

## The details page

`/prs/<owner>/<repo>/<number>` (from clicking a PR title) shows the description as GitHub renders
it, the timeline newest first (bot events hidden by default), open threads and change requests,
every check (required first), and **Merge status**: each thing stopping the merge, read from the
same rules as the list plus required thread resolution and strict up-to-date checks.
Description images move to a **Screenshots** gallery (a reference stays in the text, and both open
a lightbox). Files attached to a private repo's releases need the token, so they load through
`/api/github-image`, which only serves GitHub release downloads from `GITHUB_REPOS` or repos whose
PRs the server has shown. Anything that still can't load becomes an "Open on GitHub" tile.


Checks stay live without webhooks (they'd need a public URL): the panel polls
`/api/prs/<owner>/<repo>/<number>/checks`, a small uncached query, every 10s while anything runs and
every minute otherwise, and has its own refresh button. When the head commit or a required check
changes, the whole page refreshes so Merge status agrees; advisory changes only update the panel.

### Actions

Shown above Merge status when there's something to do about the branch:

- **Merge conflicts**: a prompt for Claude Code to merge the base in, resolve the conflicts, run the
  checks and push. **Open in Claude** opens a new Claude Code session in the Claude desktop app
  ([`claude://code/new`](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link))
  in the branch's worktree, with the prompt filled in; you confirm the folder and press send. With no
  worktree for the branch it opens the main clone and the prompt has Claude create one beside it
  (`<repo>-<ticket>`). The clone is found next to this project, or set `LOCAL_REPOS`. Opening the app
  only works when the API runs locally on macOS; otherwise copy the prompt or the terminal command.
- **Behind the base**: GitHub's "Update branch" (a merge commit pushed to the PR), after a confirm.
  It's refused if the branch moved since the page loaded.

Both are POSTs that need the `x-workbench-action` header, and in development the API only listens
on 127.0.0.1, since it can open Terminal and act with your token.

## Activity

`/activity` is a calendar of what you did, as a **Day**, **Week** (Monday to Sunday) or **Month**
view, in Sydney time or your browser's local time (the switch is remembered per browser; the API
takes `tz`, defaulting to `TIMEZONE`). Month and Week show which tickets you touched each day and
what happened, as icons; clicking a day opens its full detail. One line of totals sits on top, and
**Copy summary** writes a paste-ready update for whatever range is shown.

- The Day view shows a card per ticket: its status, linked PRs (open ones with the PR list's status)
  and the day's activity. A ticket sitting In Review or In Progress too long gets a yellow or red
  border with a message: review at 2 / 5 working days, progress at 3 / 7 (`AGE_LIMITS` in
  `server/activity/cards.ts`). Age runs from the latest move into the current status in Linear.
- Week and Month flag the same tickets, tinted yellow or red, but only on the last day each one
  appears in the range, and sort them first in their day. A "N stuck · N getting slow" count sits
  next to the totals; hover it for the tickets.
- PRs, reviews and ticket moves come from GitHub search and Linear history, so any range is complete.
- Pushes and review replies come from GitHub's events feed, which keeps only your last ~300 events
  (a few weeks). Days older than that show PR and ticket facts only, and the pushes total is left out.
- GitHub logs each reply to review feedback as a "commented" review; on your own PRs those count as
  replies, not reviews given.

## Today

The home page (`/`) answers what needs you, what's new, and what to pick up next:

- **Needs you now**: your open PRs that wait on you, grouped by what you'd do: Resolve conflicts,
  Fix CI, Reply (changes requested, threads), Nudge (stuck or slow review), Update branch, Merge,
  and Housekeeping (tickets still "Merged" in Linear, collapsed). Chips with counts filter to one
  group; the choice is remembered. Each item has one action button. Nudge items list who the
  review waits on: each code-owner team with its members (you and the author left out; from GitHub,
  cached an hour), with "or" between owners where one approval from either will do, and a Copy link
  button for pinging them.
- **Up next**: unstarted tickets assigned to you, ranked by priority, a Release Blocker label, a live
  project target date, the cycle ending, and new assignment; the reasons show beside each.
- **New for you**: your Linear inbox since you last pressed *Mark seen* (assignments, comments,
  mentions, status and priority changes, project updates; "write a project update" reminders are
  left out), plus reviews asked of you on GitHub. A dot marks what's still unread in Linear;
  *Earlier* shows the rest of the last two weeks. Marking seen here doesn't change Linear.
- **Deadlines**: cycles ending within two weeks and active projects' target dates (a target more than
  30 days past counts as stale and is dropped).
- **Waiting on others**: your PRs with nothing for you to do.

**Parking** sets a ticket or PR aside on purpose (with an optional reason and "bring back on" date):
it leaves Needs you now, Up next, Waiting on others and the header counts, the PR list's cards (it's
listed under Parked instead), and Activity's stuck flags and "N stuck" count. Parking a ticket parks
its PRs. It's listed under **Parked** on Today, and comes back by itself once its date passes.
With a reason, parking can also post it as a comment ("Parked: …", plus the return date) on the
Linear ticket and the item's open PRs, as you; each target is a checkbox with a preview, on by default
the first time you park. The park is saved even if a post fails, and the popover says which posted.

Pins (Focus), notes, todos and parked items live in Workbench's own SQLite file (`DB_PATH`, default
`data/workbench.sqlite`, gitignored). Notes attach to a ticket (or a PR without one) and show wherever
it appears: Today, the PR list and details page, and Activity's day cards. A todo that mentions a
ticket key links to that ticket. Deploying needs a persistent disk for the file.

## Freshness

Pages refetch in the background whenever you open them or come back to the window, keeping what's on
screen until the new answer arrives ("Updating…"). Those requests ask for `maxAge=15`: the server
answers straight from its cache when its copy is under 15 seconds old, and otherwise rebuilds first,
so a PR fixed in another tab shows fixed when you come back. Today takes its PR lists equally recent.
The Refresh buttons ask for `fresh=1`. After a PR action, Today and the PR list refetch too.

