import type { Person, Pr, Ticket } from '../../shared/prs'
import type { Deadline, InboxItem, InboxKind, NeedsYouItem, NeedsYouKind, NudgeTarget, OpenTicket, TodayResponse, UpNextItem } from '../../shared/today'
import { ticketRef, prRef } from '../../shared/store'
import { localDate } from '../activity/week'
import { ticketAgesFor } from '../activity/cards'
import { IntegrationNotConfigured } from '../integrations/errors'
import { getMyNotifications, getMyOpenTickets, type RawNotification } from '../integrations/linear'
import { getPrs } from '../prs/route'
import { getTeamMembers } from '../integrations/github'
import { createSwrCache } from '../lib/swrCache'

/** How "Up next" weighs a ticket. Each part also becomes a reason shown beside it. */
const PRIORITY_POINTS: Record<number, [number, string | null]> = {
  1: [40, 'Urgent'],
  2: [30, 'High priority'],
  3: [20, null],
  4: [10, null],
  0: [5, null],
}
const RELEASE_BLOCKER = /release blocker/i
const RELEASE_BLOCKER_POINTS = 40
const NEW_ASSIGNMENT_DAYS = 2
const NEW_ASSIGNMENT_POINTS = 10
const READY_TO_START_POINTS = 5

/** Deadlines worth showing: cycles ending within two weeks, project targets within a month. */
const CYCLE_HORIZON_DAYS = 14
const PROJECT_HORIZON_DAYS = 30
/** A target date this far past is a stale plan, not a deadline; it stops counting. */
const PROJECT_OVERDUE_LIMIT_DAYS = 30
const FINISHED_PROJECT = new Set(['completed', 'canceled'])

/** The project's target date if it's a live deadline: project still active and not long past. */
function liveTarget(project: OpenTicket['projectInfo'], today: string): { date: string; days: number } | null {
  if (!project?.targetDate || (project.statusType && FINISHED_PROJECT.has(project.statusType))) return null
  const days = daysBetween(today, project.targetDate)
  return days < -PROJECT_OVERDUE_LIMIT_DAYS ? null : { date: project.targetDate, days }
}

/** Not started yet, so a candidate for what to pick up next. */
const NOT_STARTED = new Set(['unstarted', 'backlog', 'triage'])

function daysBetween(fromDate: string, toDate: string): number {
  return Math.round((Date.parse(`${toDate}T12:00:00Z`) - Date.parse(`${fromDate}T12:00:00Z`)) / 86_400_000)
}

function plural(count: number, word: string): string {
  return `${count} ${word}${Math.abs(count) === 1 ? '' : 's'}`
}

function due(days: number, what: string): string {
  if (days < 0) return `${what} ${plural(-days, 'day')} overdue`
  if (days === 0) return `${what} due today`
  return `${what} due in ${plural(days, 'day')}`
}

function rankUpNext(tickets: OpenTicket[], today: string, timeZone: string, now: number): UpNextItem[] {
  return tickets
    .filter((ticket) => NOT_STARTED.has(ticket.stateType) && !/duplicate/i.test(ticket.state))
    .map((ticket) => {
      const reasons: string[] = []
      const [priorityPoints, priorityReason] = PRIORITY_POINTS[ticket.priority] ?? [0, null]
      let score = priorityPoints
      if (priorityReason) reasons.push(priorityReason)

      if (ticket.labels.some((label) => RELEASE_BLOCKER.test(label))) {
        score += RELEASE_BLOCKER_POINTS
        reasons.push('Release Blocker')
      }

      const target = liveTarget(ticket.projectInfo, today)
      if (target) {
        const { days } = target
        const points = days < 0 ? 25 : days <= 7 ? 20 : days <= 14 ? 10 : 0
        if (points) {
          score += points
          reasons.push(due(days, 'Project'))
        }
      }

      if (ticket.cycle) {
        const days = daysBetween(today, localDate(ticket.cycle.endsAt, timeZone))
        const points = days <= 3 ? 20 : days <= 7 ? 12 : days <= 14 ? 5 : 0
        if (points) {
          score += points
          reasons.push(days <= 0 ? 'Cycle ends today' : `Cycle ends in ${plural(days, 'day')}`)
        }
      }

      if (ticket.assignedAt && now - Date.parse(ticket.assignedAt) < NEW_ASSIGNMENT_DAYS * 86_400_000) {
        score += NEW_ASSIGNMENT_POINTS
        reasons.push('Newly assigned')
      }
      if (ticket.stateType === 'unstarted') score += READY_TO_START_POINTS
      if (ticket.stateType === 'triage') reasons.push('Needs triage')

      return { ticket, score, reasons }
    })
    .sort((a, b) => b.score - a.score || (a.ticket.priority || 9) - (b.ticket.priority || 9) || a.ticket.createdAt.localeCompare(b.ticket.createdAt))
}

/** The oldest PR list Today will build from. */
const PR_LIST_MAX_AGE_MS = 15_000

/** How far back the Linear inbox feed reaches. */
const INBOX_DAYS = 14
const SNIPPET_CHARS = 140

const NOTIFICATION_WORDS: Record<string, [InboxKind, string]> = {
  issueAssignedToYou: ['assigned', 'assigned you'],
  issueUnassignedFromYou: ['assigned', 'unassigned you from'],
  issueNewComment: ['comment', 'commented on'],
  issueCommentMention: ['mention', 'mentioned you on'],
  issueMention: ['mention', 'mentioned you on'],
  issueCommentReaction: ['comment', 'reacted to your comment on'],
  issueEmojiReaction: ['comment', 'reacted to'],
  issueStatusChanged: ['status', 'changed the status of'],
  issuePriorityUrgent: ['priority', 'marked urgent'],
  issueDue: ['priority', 'is due:'],
  issueBlocking: ['status', 'unblocked'],
  issueCreated: ['other', 'created'],
  issueSubscribed: ['other', 'subscribed you to'],
  issueReminder: ['other', 'reminder for'],
  projectAddedAsLead: ['project', 'made you lead of'],
  projectAddedAsMember: ['project', 'added you to'],
  projectNewComment: ['project', 'commented on'],
  projectUpdateCreated: ['project', 'posted an update on'],
  projectUpdateMentionPrompt: ['project', 'mentioned you in an update on'],
}

/** First words of a comment or update, as plain text: markdown marks and links reduced to their words. */
function snippet(text: string | null | undefined): string | null {
  const flat = text
    ?.replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[*_`~>#]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  if (!flat) return null
  return flat.length > SNIPPET_CHARS ? `${flat.slice(0, SNIPPET_CHARS).trimEnd()}…` : flat
}

function toInboxItem(raw: RawNotification): InboxItem {
  const [kind, verb] = NOTIFICATION_WORDS[raw.type] ?? ['other', raw.type.replace(/([A-Z])/g, ' $1').toLowerCase()]
  const issue = raw.issue ?? null
  return {
    id: raw.id,
    kind,
    at: raw.createdAt,
    unread: !raw.readAt,
    actor: raw.actor,
    // A status change says where it went, since that's the news.
    verb: raw.type === 'issueStatusChanged' && issue ? `moved to ${issue.state.name}` : verb,
    ticket: issue ? { key: issue.identifier, title: issue.title, url: issue.url, state: issue.state.name, stateColor: issue.state.color } : null,
    project: raw.project ?? null,
    snippet: snippet(raw.comment?.body ?? raw.projectUpdate?.body),
    url: raw.comment?.url ?? raw.projectUpdate?.url ?? issue?.url ?? raw.project?.url ?? null,
  }
}

/** A comment that mentions you arrives as both a comment and a mention; keep the mention. */
function dropEchoes(items: InboxItem[]): InboxItem[] {
  const mentions = items.filter((item) => item.kind === 'mention')
  return items.filter(
    (item) =>
      item.kind !== 'comment' ||
      !mentions.some(
        (mention) =>
          mention.ticket?.key === item.ticket?.key &&
          mention.actor?.name === item.actor?.name &&
          Math.abs(Date.parse(mention.at) - Date.parse(item.at)) < 60_000,
      ),
  )
}

/** Teams change rarely; their members are re-read in the background hourly. */
const TEAM_STALE_AFTER_MS = 60 * 60_000
const teamMembers = createSwrCache<string, Person[]>({
  load: async (key) => {
    const [org, slug] = key.split('/') as [string, string]
    return (await getTeamMembers(org, slug)).map((member) => ({
      kind: 'user',
      id: member.login,
      name: member.name ?? member.login,
      avatarUrl: member.avatarUrl,
      url: `https://github.com/${member.login}`,
    }))
  },
  staleAfterMs: TEAM_STALE_AFTER_MS,
})

/**
 * Who a slow review waits on: its code owners (or, without code-owner rules, the reviewers asked),
 * each team with its members. You and the PR's author are left out: nudging yourself helps no one.
 */
async function nudgeTargets(pr: Pr, viewer: string, warnings: string[]): Promise<NudgeTarget[][]> {
  const gate = pr.reviewGate
  // Each code-owner group is one approval still needed; without code-owner rules, anyone asked counts.
  const groups: Person[][] = gate?.codeOwners.length ? gate.codeOwners : gate?.optional.length ? [gate.optional] : []
  const skip = new Set([viewer.toLowerCase(), pr.author.toLowerCase()])
  const expand = async (owner: Person): Promise<NudgeTarget> => {
    if (owner.kind !== 'team') return { owner, members: [] }
    try {
      const members = await teamMembers.get(owner.id)
      return { owner, members: members.filter((member) => !skip.has(member.id.toLowerCase())) }
    } catch (error) {
      warnings.push(`Couldn't list ${owner.name}'s members: ${String(error)}`)
      return { owner, members: [] }
    }
  }
  const expanded = await Promise.all(groups.map((group) => Promise.all(group.filter((owner) => !skip.has(owner.id.toLowerCase())).map(expand))))
  return expanded.filter((group) => group.length > 0)
}

function prPath(pr: Pr): string {
  return `/prs/${pr.repo}/${pr.number}`
}

const KIND_ORDER: NeedsYouKind[] = [
  'conflicts',
  'ci-failing',
  'changes-requested',
  'stuck-review',
  'threads',
  'behind',
  'slow-review',
  'ready',
  'merged-not-done',
]

/** What each of your open PRs needs from you, if anything; null means it's waiting on others. */
function prNeed(pr: Pr, ageMessage: { level: 'warn' | 'alert'; text: string } | null): Omit<NeedsYouItem, 'id' | 'ticket' | 'pr' | 'ref'> | null {
  const detailPage = { href: prPath(pr), external: false }
  const label = pr.status.label
  if (label === 'Merge conflicts')
    return { kind: 'conflicts', tone: 'bad', title: 'Merge conflicts', detail: `with ${pr.baseRef}`, action: { label: 'Resolve', ...detailPage } }
  if (label.startsWith('CI failing')) {
    const first = pr.checks.failing[0]
    return {
      kind: 'ci-failing',
      tone: 'bad',
      title: 'Required CI failing',
      detail: pr.checks.failing.map((check) => check.name).join(', ') || null,
      action: first?.url ? { label: 'Open check', href: first.url, external: true } : { label: 'See checks', ...detailPage },
    }
  }
  if (label === 'Changes requested')
    return {
      kind: 'changes-requested',
      tone: 'bad',
      title: 'Changes requested',
      detail: pr.changesRequestedBy.map((person) => person.name).join(', ') || null,
      action: { label: 'See review', ...detailPage },
    }
  if (label === 'CodeRabbit wants changes' || label.includes('unresolved thread'))
    return { kind: 'threads', tone: 'warn', title: label, detail: null, action: { label: 'Reply', ...detailPage } }
  if (label === 'Behind base')
    return { kind: 'behind', tone: 'warn', title: `Behind ${pr.baseRef}`, detail: 'The branch has to be up to date to merge', action: { label: 'Update', ...detailPage } }
  if (label === 'Ready to merge')
    return { kind: 'ready', tone: 'good', title: 'Ready to merge', detail: null, action: { label: 'Merge', href: pr.url, external: true } }
  if (pr.waitingOn === 'reviewer' && ageMessage)
    // Who it waits on is listed in full (teams and their members) under the item.
    return {
      kind: ageMessage.level === 'alert' ? 'stuck-review' : 'slow-review',
      tone: ageMessage.level === 'alert' ? 'bad' : 'warn',
      title: ageMessage.level === 'alert' ? 'Stuck in review' : 'Review is slow',
      detail: ageMessage.text,
      action: { label: 'Nudge', ...detailPage },
    }
  return null
}

export async function buildToday(timeZone: string): Promise<Omit<TodayResponse, 'lastSeenAt'>> {
  const warnings: string[] = []
  // Today is only as fresh as the PR lists it's built from, so it takes them recent too.
  const [mine, reviewing, tickets, notifications] = await Promise.all([
    getPrs('mine', PR_LIST_MAX_AGE_MS),
    getPrs('reviewing', PR_LIST_MAX_AGE_MS).catch((error: unknown) => {
      warnings.push(`Review requests: ${String(error)}`)
      return null
    }),
    getMyOpenTickets().catch((error: unknown) => {
      warnings.push(error instanceof IntegrationNotConfigured ? `Linear: ${error.message}` : `Linear: ${String(error)}`)
      return [] as OpenTicket[]
    }),
    getMyNotifications().catch((error: unknown) => {
      if (!(error instanceof IntegrationNotConfigured)) warnings.push(`Linear inbox: ${String(error)}`)
      return [] as RawNotification[]
    }),
  ])

  // A ticket created already assigned to you has no assignment in its history; the inbox's
  // "assigned you" has the time, and failing that it was yours from creation.
  const assignedByInbox = new Map<string, string>()
  for (const raw of notifications)
    if (raw.type === 'issueAssignedToYou' && raw.issue && raw.createdAt > (assignedByInbox.get(raw.issue.identifier) ?? ''))
      assignedByInbox.set(raw.issue.identifier, raw.createdAt)
  for (const ticket of tickets) ticket.assignedAt ??= assignedByInbox.get(ticket.key) ?? ticket.createdAt
  warnings.push(...mine.warnings.filter((warning) => !warning.startsWith('Linear: LINEAR_API_KEY')))

  const now = Date.now()
  const today = localDate(new Date(now), timeZone)
  const openPrs = mine.open.filter((pr) => !pr.isDraft)

  // How long each PR's ticket has sat in review, for the stuck and slow flags.
  const prTickets = [...new Map(openPrs.flatMap((pr) => pr.tickets).map((ticket) => [ticket.key, ticket])).values()]
  const ages = await ticketAgesFor(prTickets, timeZone, warnings)

  const needsYou: NeedsYouItem[] = []
  const waiting: Pr[] = []
  for (const pr of openPrs) {
    const ticket: Ticket | null = pr.tickets[0] ?? null
    const age = ticket ? ages[ticket.key] : undefined
    const need = prNeed(pr, age && age.level !== 'ok' && age.message ? { level: age.level, text: age.message } : null)
    if (!need) {
      waiting.push(pr)
      continue
    }
    needsYou.push({
      ...need,
      id: `${need.kind}:${pr.repo}#${pr.number}`,
      ticket,
      pr,
      ref: ticket ? ticketRef(ticket.key) : prRef(pr.repo, pr.number),
      nudge: need.kind === 'stuck-review' || need.kind === 'slow-review' ? await nudgeTargets(pr, mine.viewer, warnings) : undefined,
    })
  }

  // Merged in GitHub, still open in Linear: worth closing so the board tells the truth.
  for (const ticket of tickets.filter((ticket) => /merged/i.test(ticket.state)))
    needsYou.push({
      id: `merged-not-done:${ticket.key}`,
      kind: 'merged-not-done',
      tone: 'neutral',
      title: `Still "${ticket.state}" in Linear`,
      detail: 'The PR is merged; move the ticket on once it ships',
      ticket,
      pr: null,
      action: { label: 'Open ticket', href: ticket.url, external: true },
      ref: ticketRef(ticket.key),
    })

  needsYou.sort((a, b) => KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind) || (b.pr?.updatedAt ?? '').localeCompare(a.pr?.updatedAt ?? ''))

  // Reviews asked of you personally; reviews you've already given don't count.
  const reviewRequests = (reviewing?.open ?? []).filter((pr) =>
    [...(pr.reviewGate?.codeOwners.flat() ?? []), ...(pr.reviewGate?.optional ?? [])].some(
      (person) => person.kind === 'user' && person.id.toLowerCase() === mine.viewer.toLowerCase(),
    ),
  )

  const deadlines: Deadline[] = []
  const cycles = new Map<string, { cycle: NonNullable<OpenTicket['cycle']>; count: number }>()
  const projects = new Map<string, { project: NonNullable<OpenTicket['projectInfo']>; count: number }>()
  for (const ticket of tickets) {
    if (ticket.cycle) {
      const key = `${ticket.cycle.number}:${ticket.cycle.endsAt}`
      const entry = cycles.get(key) ?? { cycle: ticket.cycle, count: 0 }
      entry.count++
      cycles.set(key, entry)
    }
    if (ticket.projectInfo && liveTarget(ticket.projectInfo, today)) {
      const entry = projects.get(ticket.projectInfo.name) ?? { project: ticket.projectInfo, count: 0 }
      entry.count++
      projects.set(ticket.projectInfo.name, entry)
    }
  }
  for (const { cycle, count } of cycles.values()) {
    const date = localDate(cycle.endsAt, timeZone)
    const daysLeft = daysBetween(today, date)
    if (daysLeft >= 0 && daysLeft <= CYCLE_HORIZON_DAYS)
      deadlines.push({ kind: 'cycle', name: `Cycle ${cycle.number}`, url: null, date, daysLeft, ticketCount: count })
  }
  for (const { project, count } of projects.values()) {
    const daysLeft = daysBetween(today, project.targetDate!)
    if (daysLeft <= PROJECT_HORIZON_DAYS)
      deadlines.push({ kind: 'project', name: project.name, url: project.url, date: project.targetDate!, daysLeft, ticketCount: count })
  }
  deadlines.sort((a, b) => a.date.localeCompare(b.date))

  return {
    viewer: mine.viewer,
    timeZone,
    needsYou,
    upNext: rankUpNext(tickets, today, timeZone, now),
    tickets,
    reviewRequests,
    inbox: dropEchoes(
      notifications
        .filter((raw) => now - Date.parse(raw.createdAt) < INBOX_DAYS * 86_400_000)
        .map(toInboxItem)
        .sort((a, b) => b.at.localeCompare(a.at)),
    ),
    deadlines,
    waiting,
    warnings,
    fetchedAt: new Date().toISOString(),
  }
}

