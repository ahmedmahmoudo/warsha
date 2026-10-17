import type {
  ActivityItem,
  ActivitySummary,
  ChangeRequest,
  CheckItem,
  MergeBlocker,
  MergeReadiness,
  PrActions,
  PrDetail,
  PrState,
  ReviewThread,
} from '../../shared/prDetail'
import type { Person, Pr } from '../../shared/prs'
import type { GithubPrDetail, RawDetailActor, RawTimelineItem } from '../integrations/github'
import { isCodeRabbit, listChecks, mergeRules, userPerson } from './derive'

const EXCERPT_CHARS = 600
const MAX_COMMIT_HEADLINES = 5
/** Consecutive events of the same kind by the same person this close together read as one. */
const MERGE_WINDOW_MS = 10 * 60_000

function excerpt(text: string | null | undefined): string | null {
  const trimmed = text?.trim()
  if (!trimmed) return null
  return trimmed.length > EXCERPT_CHARS ? `${trimmed.slice(0, EXCERPT_CHARS).trimEnd()}…` : trimmed
}

function isBotActor(actor: RawDetailActor | null | undefined): boolean {
  if (!actor) return false
  return actor.__typename === 'Bot' || actor.login.endsWith('[bot]') || isCodeRabbit(actor.login)
}

function actorPerson(actor: RawDetailActor | null | undefined): Person | null {
  return actor ? userPerson(actor) : null
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? '' : 's'}`
}

const EVENT_TITLES: Record<string, (item: RawTimelineItem) => string> = {
  ReadyForReviewEvent: () => 'marked this ready for review',
  ConvertToDraftEvent: () => 'converted this to a draft',
  MergedEvent: () => 'merged this',
  ClosedEvent: () => 'closed this',
  ReopenedEvent: () => 'reopened this',
  AddedToMergeQueueEvent: () => 'added this to the merge queue',
  RemovedFromMergeQueueEvent: (item) =>
    `removed this from the merge queue${item.reason ? ` (${item.reason.toLowerCase().replaceAll('_', ' ')})` : ''}`,
  HeadRefForcePushedEvent: () => 'force-pushed the branch',
  ReviewDismissedEvent: () => 'dismissed a review',
  BaseRefChangedEvent: (item) => `changed the base from ${item.previousRefName} to ${item.currentRefName}`,
}

function timelineEntry(item: RawTimelineItem): ActivityItem | null {
  const at = item.createdAt ?? item.commit?.committedDate
  if (!at) return null
  const base = { id: item.id, at, url: item.url ?? null }

  switch (item.__typename) {
    case 'PullRequestCommit': {
      const user = item.commit?.author?.user
      return {
        ...base,
        kind: 'commits',
        actor: user ? userPerson(user) : null,
        isBot: false,
        title: 'pushed 1 commit',
        body: item.commit?.messageHeadline ?? null,
      }
    }
    case 'PullRequestReview': {
      const kind = item.state === 'APPROVED' ? 'approved' : item.state === 'CHANGES_REQUESTED' ? 'changes-requested' : 'reviewed'
      const title =
        kind === 'approved'
          ? 'approved'
          : kind === 'changes-requested'
            ? 'requested changes'
            : item.state === 'DISMISSED'
              ? 'reviewed (since dismissed)'
              : item.bodyText?.trim()
                ? 'reviewed'
                : 'commented on the code'
      return { ...base, kind, actor: actorPerson(item.author), isBot: isBotActor(item.author), title, body: excerpt(item.bodyText) }
    }
    case 'IssueComment':
      return {
        ...base,
        kind: 'comment',
        actor: actorPerson(item.author),
        isBot: isBotActor(item.author),
        title: 'commented',
        body: excerpt(item.bodyText),
      }
    case 'ReviewRequestedEvent': {
      const reviewer = item.requestedReviewer?.login ?? item.requestedReviewer?.name ?? 'someone'
      return {
        ...base,
        kind: 'review-requested',
        actor: actorPerson(item.actor),
        isBot: isBotActor(item.actor),
        title: `requested review from ${reviewer}`,
        body: null,
      }
    }
    default: {
      const title = EVENT_TITLES[item.__typename]?.(item)
      if (!title) return null
      const body = item.__typename === 'ReviewDismissedEvent' ? excerpt(item.dismissalMessage) : null
      return { ...base, kind: 'event', actor: actorPerson(item.actor), isBot: isBotActor(item.actor), title, body }
    }
  }
}

/** Folds runs of commits, review requests and inline-comment reviews into one line each. */
function mergeRuns(items: ActivityItem[]): ActivityItem[] {
  const merged: ActivityItem[] = []
  for (const item of items) {
    const last = merged.at(-1)
    const sameRun =
      last &&
      last.kind === item.kind &&
      last.actor?.id === item.actor?.id &&
      Date.parse(item.at) - Date.parse(last.at) < MERGE_WINDOW_MS
    if (sameRun && item.kind === 'commits') {
      const headlines = [...(last.body ?? '').split('\n'), item.body ?? ''].filter(Boolean)
      const count = Number(last.title.match(/\d+/)?.[0] ?? 1) + 1
      merged[merged.length - 1] = { ...last, at: item.at, title: `pushed ${plural(count, 'commit')}`, body: headlines.join('\n') }
    } else if (sameRun && item.kind === 'review-requested') {
      const who = item.title.replace('requested review from ', '')
      merged[merged.length - 1] = { ...last, title: `${last.title}, ${who}` }
    } else if (sameRun && item.kind === 'reviewed' && !item.body && !last.body) {
      merged[merged.length - 1] = { ...last, at: item.at }
    } else merged.push(item)
  }
  // Long pushes keep the latest headlines and say how many more there were.
  return merged.map((item) => {
    if (item.kind !== 'commits' || !item.body) return item
    const headlines = item.body.split('\n')
    if (headlines.length <= MAX_COMMIT_HEADLINES) return item
    const shown = headlines.slice(-MAX_COMMIT_HEADLINES)
    return { ...item, body: [...shown, `…and ${headlines.length - MAX_COMMIT_HEADLINES} earlier`].join('\n') }
  })
}

function buildActivity(raw: GithubPrDetail): ActivityItem[] {
  const opened: ActivityItem = {
    id: `${raw.id}-opened`,
    kind: 'opened',
    at: raw.createdAt,
    actor: raw.author ? userPerson(raw.author) : null,
    isBot: false,
    title: 'opened this pull request',
    body: null,
    url: raw.url,
  }
  const entries = raw.timelineItems.nodes.flatMap((item) => timelineEntry(item) ?? [])
  // Newest first: what happened last is what the reader came for.
  return mergeRuns([opened, ...entries]).reverse()
}

function summariseActivity(raw: GithubPrDetail, activity: ActivityItem[]): ActivitySummary {
  const commits = raw.timelineItems.nodes.filter((item) => item.__typename === 'PullRequestCommit').length
  const comments = activity.filter((item) => item.kind === 'comment')
  return {
    commits,
    approvals: activity.filter((item) => item.kind === 'approved' && !item.isBot).length,
    changeRequests: activity.filter((item) => item.kind === 'changes-requested' && !item.isBot).length,
    comments: comments.filter((item) => !item.isBot).length,
    botComments: comments.filter((item) => item.isBot).length,
    lastActivityAt: activity[0]?.at ?? raw.updatedAt,
  }
}

function openThreads(raw: GithubPrDetail): ReviewThread[] {
  return raw.threads.nodes
    .filter((thread) => !thread.isResolved)
    .flatMap((thread): ReviewThread[] => {
      const first = thread.comments.nodes[0]
      if (!first) return []
      return [
        {
          id: thread.id,
          path: thread.path,
          line: thread.line,
          author: actorPerson(first.author),
          isBot: isBotActor(first.author),
          isOutdated: thread.isOutdated,
          body: excerpt(first.bodyText) ?? '',
          replies: thread.comments.totalCount - 1,
          url: first.url,
          createdAt: first.createdAt,
        },
      ]
    })
    .sort((a, b) => Number(a.isOutdated) - Number(b.isOutdated) || a.createdAt.localeCompare(b.createdAt))
}

function changeRequests(raw: GithubPrDetail, threads: ReviewThread[]): ChangeRequest[] {
  return raw.reviews.nodes
    .filter((review) => review.state === 'CHANGES_REQUESTED' && review.author && !isBotActor(review.author))
    .map((review) => ({
      reviewer: userPerson(review.author!),
      at: review.submittedAt ?? raw.updatedAt,
      body: excerpt(review.bodyText) ?? '',
      url: review.url,
      threadIds: threads.filter((thread) => thread.author?.id === review.author!.login).map((thread) => thread.id),
    }))
}

function mergeReadiness(raw: GithubPrDetail, pr: Pr, checks: CheckItem[], threads: ReviewThread[]): MergeReadiness {
  const queue = raw.mergeQueueEntry
    ? { position: raw.mergeQueueEntry.position, state: raw.mergeQueueEntry.state, enqueuedAt: raw.mergeQueueEntry.enqueuedAt }
    : null
  if (raw.state !== 'OPEN') return { applicable: false, ready: false, queue: null, blockers: [], notes: [] }

  const rules = mergeRules(raw)
  const blockers: MergeBlocker[] = []
  const notes: string[] = []
  const failing = checks.filter((check) => check.required && check.state === 'failed')
  const pending = checks.filter((check) => check.required && check.state === 'pending')
  const advisoryFailing = checks.filter((check) => !check.required && check.state === 'failed')

  if (raw.isDraft) blockers.push({ kind: 'draft', label: 'Still a draft', items: [] })
  if (raw.mergeStateStatus === 'DIRTY') blockers.push({ kind: 'conflicts', label: 'Merge conflicts with the base branch', items: [] })
  if (raw.mergeStateStatus === 'BEHIND') {
    if (rules.strictChecks) blockers.push({ kind: 'behind', label: `Behind ${raw.baseRefName}; update the branch`, items: [] })
    else notes.push(`Behind ${raw.baseRefName}, which this branch doesn't require updating for`)
  }
  if (failing.length)
    blockers.push({ kind: 'ci-failing', label: `${plural(failing.length, 'required check')} failing`, items: failing.map((c) => c.name) })
  if (pending.length)
    blockers.push({ kind: 'ci-pending', label: `${plural(pending.length, 'required check')} still running`, items: pending.map((c) => c.name) })
  if (pr.changesRequestedBy.length)
    blockers.push({
      kind: 'changes-requested',
      label: 'Changes requested',
      items: pr.changesRequestedBy.map((person) => person.name),
    })
  if (pr.reviewGate?.codeOwners.length)
    blockers.push({
      kind: 'code-owners',
      label: `Needs ${plural(pr.reviewGate.codeOwners.length, 'code-owner approval')}`,
      items: pr.reviewGate.codeOwners.map((group) => group.map((person) => person.name).join(' or ')),
    })
  if (pr.reviewGate?.approvalsNeeded)
    blockers.push({ kind: 'approvals', label: `Needs ${plural(pr.reviewGate.approvalsNeeded, 'more approval')}`, items: [] })
  if (rules.threadResolution && threads.length)
    blockers.push({ kind: 'threads', label: `${plural(threads.length, 'unresolved conversation')}`, items: [] })
  else if (threads.length) notes.push(`${plural(threads.length, 'unresolved conversation')}, not required to merge`)

  if (advisoryFailing.length) notes.push(`${plural(advisoryFailing.length, 'advisory check')} failing, not required to merge`)
  if (pr.coderabbit.review === 'CHANGES_REQUESTED') notes.push('CodeRabbit wants changes')
  if (pr.reviewGate && !pr.reviewGate.complete) notes.push("Some changed files couldn't be read, so code owners may be incomplete")

  return { applicable: true, ready: blockers.length === 0, queue, blockers, notes }
}

function prState(raw: GithubPrDetail, merge: MergeReadiness): PrState {
  if (raw.state === 'MERGED') return 'merged'
  if (raw.state === 'CLOSED') return 'closed'
  if (merge.queue) return 'queued'
  if (raw.isDraft) return 'draft'
  return merge.ready ? 'ready' : 'open'
}

export function buildDetail(raw: GithubPrDetail, pr: Pr, actions: PrActions): PrDetail {
  const checks = listChecks(raw)
  const threads = openThreads(raw)
  const merge = mergeReadiness(raw, pr, checks, threads)
  // GitHub only says BEHIND when the base requires an up-to-date branch; the comparison always knows.
  const behind = actions.updateBranch
  if (behind && merge.applicable && !merge.blockers.some((blocker) => blocker.kind === 'behind'))
    merge.notes = [
      ...merge.notes.filter((note) => !note.startsWith('Behind ')),
      `${plural(behind.behindBy, 'commit')} behind ${behind.base}, which isn't required to merge`,
    ]
  const activity = buildActivity(raw)
  return {
    pr,
    state: prState(raw, merge),
    headOid: raw.headRefOid,
    bodyHtml: raw.bodyHTML,
    closedAt: raw.closedAt,
    checks,
    merge,
    activity,
    activitySummary: summariseActivity(raw, activity),
    openThreads: threads,
    changeRequests: changeRequests(raw, threads),
    actions,
    fetchedAt: new Date().toISOString(),
  }
}
