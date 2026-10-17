/** The contract between `GET /api/today` and the Today page. */
import type { Person, Pr, Ticket } from './prs'

/** A ticket assigned to you and not finished, with what decides how urgent it is. */
export type OpenTicket = Ticket & {
  /** 0 none, 1 urgent, 2 high, 3 medium, 4 low (Linear's scale). */
  priority: number
  priorityLabel: string
  labels: string[]
  createdAt: string
  /** The latest time it was assigned to you. */
  assignedAt: string | null
  projectInfo: { name: string; url: string; targetDate: string | null; statusType: string | null } | null
  cycle: { number: number; startsAt: string; endsAt: string } | null
}

export type NeedsYouKind =
  | 'conflicts'
  | 'ci-failing'
  | 'changes-requested'
  | 'stuck-review'
  | 'threads'
  | 'behind'
  | 'slow-review'
  | 'ready'
  | 'merged-not-done'

/** Something waiting on you, with why and the one thing to do about it. */
export type NeedsYouItem = {
  id: string
  kind: NeedsYouKind
  tone: 'bad' | 'warn' | 'good' | 'neutral'
  /** What's wrong, short: "Merge conflicts", "CI failing". */
  title: string
  /** The specifics: failing checks, who it waits on, how long. */
  detail: string | null
  ticket: Ticket | null
  pr: Pr | null
  action: { label: string; href: string; external: boolean }
  /** What pins and notes attach to: the ticket when there is one, else the PR. */
  ref: string
  /**
   * For a review that's stuck or slow: whose approval it waits on. Each inner list is one approval
   * needed, from any one of its owners; teams list their members.
   */
  nudge?: NudgeTarget[][]
}

/** A code owner (team or person) a review waits on; a team lists its members, minus you and the author. */
export type NudgeTarget = { owner: Person; members: Person[] }

export type UpNextItem = {
  ticket: OpenTicket
  score: number
  /** Why it ranks where it does: "Urgent", "Release Blocker", "Cycle ends in 3 days". */
  reasons: string[]
}

export type InboxKind = 'assigned' | 'comment' | 'mention' | 'status' | 'priority' | 'project' | 'other'

/** Something that happened in Linear that concerns you, from your Linear inbox. */
export type InboxItem = {
  id: string
  kind: InboxKind
  at: string
  /** Unread in Linear itself. */
  unread: boolean
  actor: { name: string; avatarUrl: string | null } | null
  /** "assigned you", "commented on", "mentioned you on". */
  verb: string
  ticket: { key: string; title: string; url: string; state: string; stateColor: string } | null
  project: { name: string; url: string } | null
  /** A comment's or update's first words. */
  snippet: string | null
  url: string | null
}

export type Deadline = {
  kind: 'cycle' | 'project'
  name: string
  url: string | null
  /** YYYY-MM-DD. */
  date: string
  daysLeft: number
  ticketCount: number
}

export type TodayResponse = {
  viewer: string
  timeZone: string
  needsYou: NeedsYouItem[]
  upNext: UpNextItem[]
  /** All open tickets assigned to you; the page picks out what's new since `lastSeenAt`. */
  tickets: OpenTicket[]
  /** Open PRs asking for your review personally. */
  reviewRequests: Pr[]
  /** Your Linear inbox from the last couple of weeks, newest first; the page shows what's new. */
  inbox: InboxItem[]
  deadlines: Deadline[]
  /** Your open PRs with nothing for you to do: CI running, or waiting on reviewers in good time. */
  waiting: Pr[]
  /** When you last marked Today as seen; null until the first time. */
  lastSeenAt: string | null
  warnings: string[]
  fetchedAt: string
}
