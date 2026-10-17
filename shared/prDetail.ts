/** The contract between `GET /api/prs/:owner/:repo/:number` and the PR details page. */
import type { Person, Pr } from './prs'

/** The badge in the page header. */
export type PrState = 'draft' | 'open' | 'ready' | 'queued' | 'merged' | 'closed'

export type CheckState = 'passed' | 'failed' | 'pending' | 'skipped'

export type CheckItem = {
  name: string
  state: CheckState
  required: boolean
  url: string | null
  /** Required by the base branch but not reported on this commit yet. */
  expected?: boolean
}

/** Something that stops the PR merging right now, in the order the author should deal with it. */
export type MergeBlocker = {
  kind:
    | 'draft'
    | 'conflicts'
    | 'behind'
    | 'ci-failing'
    | 'ci-pending'
    | 'changes-requested'
    | 'code-owners'
    | 'approvals'
    | 'threads'
  label: string
  /** Names behind the label: checks, reviewers, owner groups. */
  items: string[]
}

export type MergeReadiness = {
  /** False once merged or closed; the blockers are then empty. */
  applicable: boolean
  ready: boolean
  /** Set while the PR sits in the merge queue. */
  queue: { position: number | null; state: string; enqueuedAt: string } | null
  blockers: MergeBlocker[]
  /** Worth knowing but not stopping the merge: advisory CI, CodeRabbit, an out-of-date branch. */
  notes: string[]
}

export type ActivityKind =
  | 'opened'
  | 'commits'
  | 'approved'
  | 'changes-requested'
  | 'reviewed'
  | 'comment'
  | 'review-requested'
  | 'event'

export type ActivityItem = {
  id: string
  kind: ActivityKind
  at: string
  actor: Person | null
  isBot: boolean
  /** What happened, without the actor: "pushed 3 commits", "added this to the merge queue". */
  title: string
  /** Plain-text excerpt: commit headlines, a review or comment body. */
  body: string | null
  url: string | null
}

export type ReviewThread = {
  id: string
  path: string
  line: number | null
  author: Person | null
  isBot: boolean
  isOutdated: boolean
  /** The opening comment as plain text. */
  body: string
  replies: number
  url: string
  createdAt: string
}

/** A reviewer whose latest review asks for changes, with what they asked for. */
export type ChangeRequest = {
  reviewer: Person
  at: string
  body: string
  url: string
  /** Their unresolved threads; also listed in `openThreads`. */
  threadIds: string[]
}

export type ActivitySummary = {
  commits: number
  approvals: number
  changeRequests: number
  comments: number
  botComments: number
  lastActivityAt: string
}

/** Things the page can do about the PR's branch; each is null when it doesn't apply. */
export type PrActions = {
  /** The branch conflicts with its base: hand it to Claude in a local checkout. */
  conflicts: {
    prompt: string
    /** The checkout Claude would run in, or null when no local clone of the repo was found. */
    checkout: { path: string; kind: 'worktree' | 'new-worktree' } | null
    /** One line to paste into a terminal; null without a local checkout. */
    command: string | null
    /** True when this server can open Terminal itself (local, macOS). */
    canLaunch: boolean
  } | null
  /** The branch is missing commits from its base. */
  updateBranch: {
    behindBy: number
    base: string
    /** False when GitHub won't do it here: conflicts, or no permission. */
    canUpdate: boolean
    reason: string | null
    headOid: string
  } | null
}

export type PrDetail = {
  pr: Pr
  state: PrState
  /** The head commit everything here was read from. */
  headOid: string
  /** GitHub-rendered, GitHub-sanitised description. */
  bodyHtml: string
  closedAt: string | null
  checks: CheckItem[]
  merge: MergeReadiness
  activity: ActivityItem[]
  activitySummary: ActivitySummary
  openThreads: ReviewThread[]
  changeRequests: ChangeRequest[]
  actions: PrActions
  fetchedAt: string
}

/** `GET /api/prs/:owner/:repo/:number/checks`: just the checks, polled while CI runs. */
export type PrChecksResponse = { headOid: string; checks: CheckItem[]; fetchedAt: string }

