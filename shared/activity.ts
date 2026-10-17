/** The contract between `GET /api/activity?week=YYYY-MM-DD` and the Activity page. */
import type { Person, Ticket } from './prs'

export type ActivityPr = {
  repo: string
  number: number
  title: string
  url: string
  author: Person | null
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  isDraft: boolean
  createdAt: string
  mergedAt: string | null
  headRef: string
  ticketKeys: string[]
}

export type DayEntryKind =
  | 'pushed'
  | 'opened'
  | 'merged'
  | 'closed'
  | 'reopened'
  | 'replied'
  | 'commented'
  | 'approved'
  | 'changes-requested'
  | 'reviewed'
  | 'ticket'

export type DayEntry = {
  kind: DayEntryKind
  at: string
  /** What happened, ready to show: "pushed 3×", "opened #18771", "moved to In Review". */
  text: string
  url: string | null
}

/** One ticket's (or one branch's) work on one day. */
export type DayGroup = {
  key: string
  ticket: Ticket | null
  /** The ticket title, else the PR title or branch name. */
  title: string
  entries: DayEntry[]
}

export type ActivityDay = {
  /** YYYY-MM-DD in the page's time zone. */
  date: string
  groups: DayGroup[]
  /** Reviews of other people's PRs that day. */
  reviews: (DayEntry & { pr: ActivityPr })[]
  /** False when the day is older than GitHub's events feed: no pushes or replies, only PR and ticket facts. */
  detailed: boolean
}

export type ReviewGiven = {
  pr: ActivityPr
  reviews: { state: 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | 'DISMISSED'; at: string; url: string; comments: number }[]
}

export type TicketTransition = { at: string; from: string | null; to: string; toType: string; by: string | null }

export type TicketActivity = {
  ticket: Ticket
  /** You created it this week. */
  created: boolean
  transitions: TicketTransition[]
}

export type ShippedPr = ActivityPr & {
  tickets: Ticket[]
  /** Merged, but its ticket isn't marked done yet. */
  ticketLagging: boolean
}

/**
 * How much of the week GitHub's events feed covers. It keeps about 300 events, so day-by-day
 * detail (pushes, replies) only reaches back a couple of weeks; PR facts come from search and
 * are always complete.
 */
export type DayByDayCoverage = 'complete' | 'partial' | 'unavailable'

/** A PR linked to a ticket, with the PR list's plain-words status while it's open. */
export type LinkedPr = ActivityPr & { status: { label: string; tone: 'good' | 'bad' | 'warn' | 'neutral' } | null }

/**
 * How long a ticket has sat in its current in-flight status, in working days (Mon–Fri), and
 * whether that's long enough to flag.
 */
export type TicketAge = {
  state: string
  since: string
  workingDays: number
  level: 'ok' | 'warn' | 'alert'
  /** Set when level isn't ok, e.g. "In Review for 4 working days, worth a nudge". */
  message: string | null
}

/** What the Day view shows per ticket beyond the day's activity. */
export type TicketCard = { prs: LinkedPr[] }

export type ActivityView = 'day' | 'week' | 'month'

export type ActivityResponse = {
  range: {
    view: ActivityView
    /** First day, YYYY-MM-DD. */
    start: string
    /** Last day, YYYY-MM-DD (inclusive). */
    end: string
    timeZone: string
    /** Today falls inside it. */
    isCurrent: boolean
  }
  viewer: string
  totals: {
    prsOpened: number
    prsMerged: number
    /** Other people's PRs you reviewed. */
    prsReviewed: number
    ticketsCompleted: number
    /** Null when the events feed doesn't cover the whole range. */
    pushes: number | null
  }
  dayByDay: DayByDayCoverage
  /** The oldest moment the events feed covers. */
  coverageFrom: string | null
  days: ActivityDay[]
  shipped: ShippedPr[]
  opened: ActivityPr[]
  reviewsGiven: ReviewGiven[]
  tickets: TicketActivity[]
  /** Day view only: linked PRs per ticket key in the day. */
  ticketCards: Record<string, TicketCard>
  /** How long each in-flight ticket in the range has sat in its status, as of now. */
  ticketAges: Record<string, TicketAge>
  warnings: string[]
  fetchedAt: string
}
