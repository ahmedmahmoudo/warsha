/** The contract between `GET /api/prs` and the Pull Requests page. */

export type PrScope = 'mine' | 'reviewing' | 'team'

export type Ticket = {
  key: string
  title: string
  url: string
  state: string
  /** Linear's workflow category: backlog | unstarted | started | completed | canceled | triage */
  stateType: string
  stateColor: string
  assignee: string | null
  project: string | null
}

export type FailedCheck = { name: string; url: string | null }

/** `state`, `failing` and `pending` cover required checks only; advisory failures are listed apart. */
export type CheckSummary = {
  state: 'passing' | 'failing' | 'pending' | 'none'
  failing: FailedCheck[]
  pending: string[]
  advisoryFailing: FailedCheck[]
  total: number
}

export type CodeRabbitSummary = {
  /** The bot's standing review, which outlives follow-up commits until it re-reviews. */
  review: 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | null
  unresolvedThreads: number
}

/** Who the PR is waiting on right now. */
export type WaitingOn = 'you' | 'reviewer' | 'ci' | 'merge' | 'draft'

export type Mismatch =
  | 'no-ticket'
  | 'ticket-closed-pr-open'
  | 'ticket-not-started'
  | 'pr-merged-ticket-open'

export type Pr = {
  number: number
  title: string
  url: string
  repo: string
  author: string
  isDraft: boolean
  headRef: string
  baseRef: string
  createdAt: string
  updatedAt: string
  mergedAt: string | null
  additions: number
  deletions: number
  /** Plain-words reading of mergeStateStatus + checks + reviews. */
  status: { label: string; tone: 'good' | 'bad' | 'warn' | 'neutral' }
  waitingOn: WaitingOn
  checks: CheckSummary
  coderabbit: CodeRabbitSummary
  reviewDecision: string | null
  approvals: string[]
  changesRequestedBy: string[]
  pendingReviewers: string[]
  unresolvedThreads: number
  ticketKeys: string[]
  tickets: Ticket[]
  mismatches: Mismatch[]
  /** Number of the open PR whose head this PR is stacked on, if any. */
  stackedOn: number | null
}

export type PrsResponse = {
  scope: PrScope
  viewer: string
  open: Pr[]
  recentlyMerged: Pr[]
  fetchedAt: string
  warnings: string[]
}
