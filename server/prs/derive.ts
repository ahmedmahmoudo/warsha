import type { CheckSummary, CodeRabbitSummary, Mismatch, Pr, Ticket, WaitingOn } from '../../shared/prs'
import type { GithubPr, RawCheckContext } from '../integrations/github'

const CODERABBIT_LOGIN = 'coderabbitai'
const FAILING_CONCLUSIONS = new Set(['FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'])
const CLOSED_TICKET_TYPES = new Set(['completed', 'canceled'])
const NOT_STARTED_TICKET_TYPES = new Set(['backlog', 'unstarted', 'triage'])

/**
 * Branch names are lower-cased by Linear ("feature/mx-2473-…"), so the branch is matched
 * case-insensitively but only its first key counts. Titles and bodies use upper case keys
 * and Linear issue links; anything that isn't a real ticket is dropped after the lookup.
 */
export function extractTicketKeys(pr: Pick<GithubPr, 'headRefName' | 'title' | 'body'>): string[] {
  const keys = new Set<string>()
  const branchKey = pr.headRefName.match(/(?:^|[/_-])([a-z]{2,6}-\d{1,6})(?=\b|[/_-])/i)?.[1]
  if (branchKey) keys.add(branchKey.toUpperCase())
  for (const match of pr.title.matchAll(/\b[A-Z]{2,6}-\d{1,6}\b/g)) keys.add(match[0])
  for (const match of pr.body.matchAll(/linear\.app\/[^/\s]+\/issue\/([A-Z]{2,6}-\d{1,6})/g)) keys.add(match[1]!)
  return [...keys]
}

function summariseChecks(raw: GithubPr): CheckSummary {
  const contexts: RawCheckContext[] = raw.commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes ?? []
  const summary: CheckSummary = { state: 'none', failing: [], pending: [], advisoryFailing: [], total: contexts.length }
  // Without branch protection nothing is "required", so every check counts.
  const hasProtection = contexts.some((context) => context.isRequired)

  for (const context of contexts) {
    const name = context.__typename === 'CheckRun' ? context.name : context.context
    const url = context.__typename === 'CheckRun' ? context.detailsUrl : context.targetUrl
    const isPending =
      context.__typename === 'CheckRun'
        ? context.status !== 'COMPLETED'
        : context.state === 'PENDING' || context.state === 'EXPECTED'
    const isFailing =
      context.__typename === 'CheckRun'
        ? context.status === 'COMPLETED' && context.conclusion !== null && FAILING_CONCLUSIONS.has(context.conclusion)
        : context.state === 'FAILURE' || context.state === 'ERROR'

    const isRequired = !hasProtection || context.isRequired
    if (isFailing) (isRequired ? summary.failing : summary.advisoryFailing).push({ name, url })
    else if (isPending && isRequired) summary.pending.push(name)
  }

  if (summary.failing.length) summary.state = 'failing'
  else if (summary.pending.length) summary.state = 'pending'
  else if (contexts.length) summary.state = 'passing'
  return summary
}

function isCodeRabbit(login: string | undefined) {
  return login?.startsWith(CODERABBIT_LOGIN) ?? false
}

function summariseCodeRabbit(raw: GithubPr): CodeRabbitSummary {
  const review = raw.latestOpinionatedReviews.nodes.find((r) => isCodeRabbit(r.author?.login))?.state
  return {
    review: review === 'APPROVED' || review === 'CHANGES_REQUESTED' || review === 'COMMENTED' ? review : null,
    unresolvedThreads: raw.reviewThreads.nodes.filter(
      (thread) => !thread.isResolved && isCodeRabbit(thread.comments.nodes[0]?.author?.login),
    ).length,
  }
}

type Status = { status: Pr['status']; waitingOn: WaitingOn }

/** Ordered so the first thing the author has to act on wins. */
function deriveStatus(raw: GithubPr, checks: CheckSummary, coderabbit: CodeRabbitSummary, unresolved: number): Status {
  if (raw.mergedAt) return { status: { label: 'Merged', tone: 'good' }, waitingOn: 'merge' }
  if (raw.isDraft) return { status: { label: 'Draft', tone: 'neutral' }, waitingOn: 'draft' }
  if (raw.mergeStateStatus === 'DIRTY') return { status: { label: 'Merge conflicts', tone: 'bad' }, waitingOn: 'you' }
  if (checks.state === 'failing')
    return { status: { label: `CI failing (${checks.failing.length})`, tone: 'bad' }, waitingOn: 'you' }
  if (raw.reviewDecision === 'CHANGES_REQUESTED')
    return { status: { label: 'Changes requested', tone: 'bad' }, waitingOn: 'you' }
  if (coderabbit.review === 'CHANGES_REQUESTED')
    return { status: { label: 'CodeRabbit wants changes', tone: 'warn' }, waitingOn: 'you' }
  if (checks.state === 'pending')
    return { status: { label: `CI running (${checks.pending.length})`, tone: 'neutral' }, waitingOn: 'ci' }
  if (unresolved > 0)
    return { status: { label: `${unresolved} unresolved thread${unresolved === 1 ? '' : 's'}`, tone: 'warn' }, waitingOn: 'you' }
  if (raw.mergeStateStatus === 'BEHIND') return { status: { label: 'Behind base', tone: 'warn' }, waitingOn: 'you' }
  if (raw.reviewDecision === 'APPROVED' || ['CLEAN', 'HAS_HOOKS', 'UNSTABLE'].includes(raw.mergeStateStatus))
    return { status: { label: 'Ready to merge', tone: 'good' }, waitingOn: 'merge' }
  // BLOCKED with green checks and nothing outstanding is almost always "awaiting a human approval".
  return { status: { label: 'Needs reviewer', tone: 'neutral' }, waitingOn: 'reviewer' }
}

function deriveMismatches(raw: GithubPr, tickets: Ticket[], ticketKeys: string[]): Mismatch[] {
  if (ticketKeys.length === 0) return ['no-ticket']
  const mismatches: Mismatch[] = []
  if (raw.mergedAt) {
    if (tickets.some((t) => !CLOSED_TICKET_TYPES.has(t.stateType))) mismatches.push('pr-merged-ticket-open')
    return mismatches
  }
  if (tickets.length && tickets.every((t) => CLOSED_TICKET_TYPES.has(t.stateType)))
    mismatches.push('ticket-closed-pr-open')
  if (!raw.isDraft && tickets.some((t) => NOT_STARTED_TICKET_TYPES.has(t.stateType)))
    mismatches.push('ticket-not-started')
  return mismatches
}

/**
 * @param ticketsByKey null when Linear isn't configured — keys are then kept as-is
 * instead of being filtered down to tickets that exist.
 */
export function derivePr(raw: GithubPr, ticketsByKey: Map<string, Ticket> | null): Pr {
  const extractedKeys = extractTicketKeys(raw)
  const ticketKeys = ticketsByKey ? extractedKeys.filter((key) => ticketsByKey.has(key)) : extractedKeys
  const tickets = ticketKeys.flatMap((key) => ticketsByKey?.get(key) ?? [])

  const checks = summariseChecks(raw)
  const coderabbit = summariseCodeRabbit(raw)
  const unresolvedThreads = raw.reviewThreads.nodes.filter((thread) => !thread.isResolved).length
  const humanReviews = raw.latestOpinionatedReviews.nodes.filter((r) => !isCodeRabbit(r.author?.login))
  const reviewersWith = (state: string) =>
    humanReviews.filter((r) => r.state === state).flatMap((r) => r.author?.login ?? [])

  return {
    number: raw.number,
    title: raw.title,
    url: raw.url,
    repo: raw.repository.nameWithOwner,
    author: raw.author?.login ?? 'ghost',
    isDraft: raw.isDraft,
    headRef: raw.headRefName,
    baseRef: raw.baseRefName,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
    mergedAt: raw.mergedAt,
    additions: raw.additions,
    deletions: raw.deletions,
    ...deriveStatus(raw, checks, coderabbit, unresolvedThreads),
    checks,
    coderabbit,
    reviewDecision: raw.reviewDecision,
    approvals: reviewersWith('APPROVED'),
    changesRequestedBy: reviewersWith('CHANGES_REQUESTED'),
    pendingReviewers: raw.reviewRequests.nodes.flatMap((r) => r.requestedReviewer?.login ?? r.requestedReviewer?.name ?? []),
    unresolvedThreads,
    ticketKeys,
    tickets,
    mismatches: deriveMismatches(raw, tickets, ticketKeys),
    stackedOn: null,
  }
}

/** Links each PR to the open PR in the same repo whose head branch it targets. */
export function linkStacks(prs: Pr[]): Pr[] {
  const byHead = new Map(prs.map((pr) => [`${pr.repo}:${pr.headRef}`, pr.number]))
  return prs.map((pr) => ({ ...pr, stackedOn: byHead.get(`${pr.repo}:${pr.baseRef}`) ?? null }))
}
