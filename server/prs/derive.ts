import type { CheckItem, CheckState } from '../../shared/prDetail'
import type { CheckSummary, CodeRabbitSummary, Mismatch, Person, Pr, ReviewGate, Ticket, WaitingOn } from '../../shared/prs'
import type { GithubPr, RawActor, RawCheckContext, RawReviewer, RawRule } from '../integrations/github'
import type { Codeowners } from './codeowners'

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

const SKIPPED_CONCLUSIONS = new Set(['SKIPPED', 'NEUTRAL', 'STALE'])

/**
 * Every check on the head commit, each read the same way the summary reads it. A required check
 * that hasn't reported yet (common right after a push) is listed as pending, because GitHub
 * treats it as "expected" and won't merge without it.
 */
export function listChecks(raw: Pick<GithubPr, 'commits' | 'mergedAt' | 'baseRef'>): CheckItem[] {
  const contexts: RawCheckContext[] = raw.commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes ?? []
  const requiredNames = raw.mergedAt ? [] : mergeRules(raw).requiredChecks
  // Without branch protection nothing is "required", so every check counts.
  const hasProtection = requiredNames.length > 0 || contexts.some((context) => context.isRequired)
  const reported = contexts.map((context): CheckItem => {
    const required = !hasProtection || context.isRequired
    if (context.__typename === 'CheckRun') {
      const state: CheckState =
        context.status !== 'COMPLETED'
          ? 'pending'
          : context.conclusion !== null && FAILING_CONCLUSIONS.has(context.conclusion)
            ? 'failed'
            : context.conclusion !== null && SKIPPED_CONCLUSIONS.has(context.conclusion)
              ? 'skipped'
              : 'passed'
      return { name: context.name, state, required, url: context.detailsUrl }
    }
    const state: CheckState =
      context.state === 'PENDING' || context.state === 'EXPECTED'
        ? 'pending'
        : context.state === 'FAILURE' || context.state === 'ERROR'
          ? 'failed'
          : 'passed'
    return { name: context.context, state, required, url: context.targetUrl }
  })
  const names = new Set(reported.map((check) => check.name))
  const expected = requiredNames
    .filter((name) => !names.has(name))
    .map((name): CheckItem => ({ name, state: 'pending', required: true, url: null, expected: true }))
  return [...reported, ...expected]
}

function summariseChecks(raw: GithubPr): CheckSummary {
  const checks = listChecks(raw)
  const summary: CheckSummary = { state: 'none', failing: [], pending: [], advisoryFailing: [], total: checks.length }
  for (const check of checks) {
    if (check.state === 'failed') (check.required ? summary.failing : summary.advisoryFailing).push(check)
    else if (check.state === 'pending' && check.required) summary.pending.push(check.name)
  }
  if (summary.failing.length) summary.state = 'failing'
  else if (summary.pending.length) summary.state = 'pending'
  else if (checks.length) summary.state = 'passing'
  return summary
}

export function isCodeRabbit(login: string | undefined) {
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

/** What the route gathered beyond the PR itself so code-owner review can be worked out. */
export type ReviewContext = {
  codeowners: Codeowners | null
  files: string[]
  filesComplete: boolean
  /** The org's teams keyed by lower-case "org/slug", for owners GitHub didn't request. */
  teams: Map<string, Person>
}

export function userPerson(actor: RawActor): Person {
  return { kind: 'user', id: actor.login, name: actor.login, avatarUrl: actor.avatarUrl, url: `https://github.com/${actor.login}` }
}

function reviewerPerson(reviewer: RawReviewer): Person | null {
  if (reviewer.__typename === 'Mannequin') return null
  if (reviewer.__typename !== 'Team') return userPerson(reviewer)
  const org = reviewer.organization.login
  return {
    kind: 'team',
    id: `${org}/${reviewer.slug}`,
    name: reviewer.name,
    avatarUrl: reviewer.avatarUrl,
    url: `https://github.com/orgs/${org}/teams/${reviewer.slug}`,
  }
}

/** A CODEOWNERS entry ("@org/team" or "@login"), using the requested reviewer's details when there is one. */
function ownerPerson(owner: string, requested: Map<string, Person>, teams: Map<string, Person>): Person {
  const id = owner.slice(1)
  const known = requested.get(id.toLowerCase()) ?? teams.get(id.toLowerCase())
  if (known) return known
  const [org, slug] = id.split('/')
  if (slug) return { kind: 'team', id, name: slug, avatarUrl: null, url: `https://github.com/orgs/${org}/teams/${slug}` }
  return { kind: 'user', id, name: id, avatarUrl: `https://github.com/${id}.png?size=48`, url: `https://github.com/${id}` }
}

export type MergeRules = {
  approvals: number
  codeOwners: boolean
  /** Unresolved review threads block the merge. */
  threadResolution: boolean
  /** The branch must be up to date with its base before merging. */
  strictChecks: boolean
  /** Check names that must pass, whether or not they've reported yet. */
  requiredChecks: string[]
}

/**
 * The rules that bind the PR's base branch. A ruleset that also restricts updates only lets its
 * bypass actors merge, and they skip its rules, so none of its rules apply in practice.
 */
export function mergeRules(raw: Pick<GithubPr, 'baseRef'>): MergeRules {
  const rules: RawRule[] = raw.baseRef?.rules.nodes ?? []
  const restricted = new Set(rules.filter((rule) => rule.type === 'UPDATE').map((rule) => rule.repositoryRuleset?.id))
  const binding = rules.filter((rule) => !restricted.has(rule.repositoryRuleset?.id))
  const pullRequestRules = binding.filter((rule) => rule.type === 'PULL_REQUEST')
  const protection = raw.baseRef?.branchProtectionRule
  return {
    approvals: Math.max(
      protection?.requiredApprovingReviewCount ?? 0,
      ...pullRequestRules.map((rule) => rule.parameters?.requiredApprovingReviewCount ?? 0),
    ),
    codeOwners:
      (protection?.requiresCodeOwnerReviews ?? false) ||
      pullRequestRules.some((rule) => rule.parameters?.requireCodeOwnerReview === true),
    threadResolution:
      (protection?.requiresConversationResolution ?? false) ||
      pullRequestRules.some((rule) => rule.parameters?.requiredReviewThreadResolution === true),
    strictChecks:
      (protection?.requiresStrictStatusChecks ?? false) ||
      binding.some((rule) => rule.type === 'REQUIRED_STATUS_CHECKS' && rule.parameters?.strictRequiredStatusChecksPolicy === true),
    requiredChecks: [
      ...new Set([
        ...(protection?.requiredStatusCheckContexts ?? []),
        ...binding.flatMap((rule) =>
          rule.type === 'REQUIRED_STATUS_CHECKS' ? (rule.parameters?.requiredStatusChecks ?? []).map((check) => check.context) : [],
        ),
      ]),
    ],
  }
}

/**
 * Who still has to approve before the PR can merge: one approval per code-owner group whose
 * files are untouched by an approval so far, plus any approvals still short of the required count.
 * Reviews made "on behalf of" a team clear that team; the author can't clear their own files.
 */
function deriveReviewGate(raw: GithubPr, approvals: Person[], review: ReviewContext | undefined): ReviewGate {
  const rules = mergeRules(raw)
  const org = raw.repository.nameWithOwner.split('/')[0]!.toLowerCase()
  const author = raw.author?.login.toLowerCase()

  const requested = new Map<string, Person>()
  for (const request of raw.reviewRequests.nodes) {
    const person = request.requestedReviewer && reviewerPerson(request.requestedReviewer)
    if (person && !isCodeRabbit(person.id)) requested.set(person.id.toLowerCase(), person)
  }

  const approvedBy = new Set<string>()
  for (const r of raw.latestOpinionatedReviews.nodes) {
    if (r.state !== 'APPROVED' || !r.author || isCodeRabbit(r.author.login)) continue
    approvedBy.add(r.author.login.toLowerCase())
    for (const team of r.onBehalfOf.nodes) approvedBy.add(`${org}/${team.slug.toLowerCase()}`)
  }

  const groups = new Map<string, Person[]>()
  if (rules.codeOwners && review?.codeowners) {
    for (const file of review.files) {
      const owners = review.codeowners.ownersOf(file).filter((owner) => owner.slice(1).toLowerCase() !== author)
      if (owners.length === 0 || owners.some((owner) => approvedBy.has(owner.slice(1).toLowerCase()))) continue
      const key = owners.map((owner) => owner.toLowerCase()).sort().join(' ')
      if (!groups.has(key)) groups.set(key, owners.map((owner) => ownerPerson(owner, requested, review.teams)))
    }
  }

  const blocking = new Set([...groups.values()].flat().map((person) => person.id.toLowerCase()))
  return {
    codeOwners: [...groups.values()],
    approvalsNeeded: Math.max(0, rules.approvals - approvals.length),
    optional: [...requested.values()].filter((person) => !blocking.has(person.id.toLowerCase())),
    complete: !rules.codeOwners || (review?.codeowners != null && review.filesComplete),
  }
}

type Status = { status: Pr['status']; waitingOn: WaitingOn }

/** Ordered so the first thing the author has to act on wins. */
function deriveStatus(
  raw: GithubPr,
  checks: CheckSummary,
  coderabbit: CodeRabbitSummary,
  unresolved: number,
  changesRequested: boolean,
  gate: ReviewGate | null,
): Status {
  if (raw.mergedAt) return { status: { label: 'Merged', tone: 'good' }, waitingOn: 'merge' }
  if (raw.isDraft) return { status: { label: 'Draft', tone: 'neutral' }, waitingOn: 'draft' }
  if (raw.mergeStateStatus === 'DIRTY') return { status: { label: 'Merge conflicts', tone: 'bad' }, waitingOn: 'you' }
  if (checks.state === 'failing')
    return { status: { label: `CI failing (${checks.failing.length})`, tone: 'bad' }, waitingOn: 'you' }
  // reviewDecision only reflects classic branch protection, so rulesets need the reviews themselves.
  if (raw.reviewDecision === 'CHANGES_REQUESTED' || changesRequested)
    return { status: { label: 'Changes requested', tone: 'bad' }, waitingOn: 'you' }
  if (coderabbit.review === 'CHANGES_REQUESTED')
    return { status: { label: 'CodeRabbit wants changes', tone: 'warn' }, waitingOn: 'you' }
  if (checks.state === 'pending')
    return { status: { label: `CI running (${checks.pending.length})`, tone: 'neutral' }, waitingOn: 'ci' }
  if (unresolved > 0)
    return { status: { label: `${unresolved} unresolved thread${unresolved === 1 ? '' : 's'}`, tone: 'warn' }, waitingOn: 'you' }
  if (raw.mergeStateStatus === 'BEHIND') return { status: { label: 'Behind base', tone: 'warn' }, waitingOn: 'you' }
  if (gate?.codeOwners.length)
    return { status: { label: 'Needs code owner', tone: 'neutral' }, waitingOn: 'reviewer' }
  if (gate?.approvalsNeeded)
    return {
      status: { label: `Needs ${gate.approvalsNeeded} approval${gate.approvalsNeeded === 1 ? '' : 's'}`, tone: 'neutral' },
      waitingOn: 'reviewer',
    }
  // With the review rules read and nothing outstanding, BLOCKED just means "use the merge queue".
  if (
    (gate?.complete ?? false) ||
    raw.reviewDecision === 'APPROVED' ||
    ['CLEAN', 'HAS_HOOKS', 'UNSTABLE'].includes(raw.mergeStateStatus)
  )
    return { status: { label: 'Ready to merge', tone: 'good' }, waitingOn: 'merge' }
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
export function derivePr(raw: GithubPr, ticketsByKey: Map<string, Ticket> | null, review?: ReviewContext): Pr {
  const extractedKeys = extractTicketKeys(raw)
  const ticketKeys = ticketsByKey ? extractedKeys.filter((key) => ticketsByKey.has(key)) : extractedKeys
  const tickets = ticketKeys.flatMap((key) => ticketsByKey?.get(key) ?? [])

  const checks = summariseChecks(raw)
  const coderabbit = summariseCodeRabbit(raw)
  const unresolvedThreads = raw.reviewThreads.nodes.filter((thread) => !thread.isResolved).length
  const humanReviews = raw.latestOpinionatedReviews.nodes.filter((r) => !isCodeRabbit(r.author?.login))
  const reviewersWith = (state: string) =>
    humanReviews.filter((r) => r.state === state).flatMap((r) => (r.author ? [userPerson(r.author)] : []))
  const approvals = reviewersWith('APPROVED')
  const changesRequestedBy = reviewersWith('CHANGES_REQUESTED')
  const reviewGate = raw.mergedAt ? null : deriveReviewGate(raw, approvals, review)

  return {
    number: raw.number,
    title: raw.title,
    url: raw.url,
    repo: raw.repository.nameWithOwner,
    author: raw.author?.login ?? 'ghost',
    authorAvatarUrl: raw.author?.avatarUrl ?? null,
    isDraft: raw.isDraft,
    headRef: raw.headRefName,
    baseRef: raw.baseRefName,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
    mergedAt: raw.mergedAt,
    additions: raw.additions,
    deletions: raw.deletions,
    ...deriveStatus(raw, checks, coderabbit, unresolvedThreads, changesRequestedBy.length > 0, reviewGate),
    checks,
    coderabbit,
    reviewDecision: raw.reviewDecision,
    approvals,
    changesRequestedBy,
    reviewGate,
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
