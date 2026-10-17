import type {
  ActivityDay,
  ActivityPr,
  ActivityResponse,
  DayByDayCoverage,
  DayEntry,
  DayGroup,
  ReviewGiven,
  ShippedPr,
  TicketActivity,
} from '../../shared/activity'
import type { Ticket } from '../../shared/prs'
import { IntegrationNotConfigured } from '../integrations/errors'
import {
  getPrsByNumber,
  getUserEvents,
  searchActivityPrs,
  type RawActivityPr,
  type RawActivityReview,
  type RawEvent,
} from '../integrations/github'
import { getMyIssueActivity, getTicketsByKey, toTicket, type LinearIssueActivity } from '../integrations/linear'
import { extractTicketKeys, userPerson } from '../prs/derive'
import { buildTicketAges, buildTicketCards } from './cards'
import { localDate, startOfDate, type Range } from './week'

/** GitHub keeps events for 90 days at most, however few there are. */
const EVENTS_MAX_AGE_MS = 90 * 86_400_000
const CLOSED_TICKET_TYPES = new Set(['completed', 'canceled'])

/** GitHub search takes ISO times with an explicit offset. */
function searchTime(instant: Date): string {
  return instant.toISOString().replace(/\.\d{3}Z$/, '+00:00')
}

function inRange(at: string | null | undefined, range: Range): at is string {
  if (!at) return false
  const time = Date.parse(at)
  return time >= range.from.getTime() && time < range.to.getTime()
}

function toActivityPr(raw: RawActivityPr): ActivityPr {
  return {
    repo: raw.repository.nameWithOwner,
    number: raw.number,
    title: raw.title,
    url: raw.url,
    author: raw.author ? userPerson(raw.author) : null,
    state: raw.state,
    isDraft: raw.isDraft,
    createdAt: raw.createdAt,
    mergedAt: raw.mergedAt,
    headRef: raw.headRefName,
    ticketKeys: extractTicketKeys({ headRefName: raw.headRefName, title: raw.title, body: raw.body }),
  }
}

const prKey = (repo: string, number: number) => `${repo.toLowerCase()}#${number}`

/** The ticket a branch belongs to, the same way PRs are matched to tickets. */
function branchTicketKey(branch: string): string | null {
  return extractTicketKeys({ headRefName: branch, title: '', body: '' })[0] ?? null
}

function eventPrNumber(event: RawEvent): number | null {
  return event.payload.pull_request?.number ?? event.payload.issue?.number ?? event.payload.number ?? null
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? '' : 's'}`
}

const REVIEW_KIND = {
  approved: 'approved',
  changes_requested: 'changes-requested',
  commented: 'reviewed',
} as const

/**
 * The week, day by day, from the events feed. Pushes and replies are counted per ticket per day;
 * reviews of other people's PRs are listed apart.
 */
function buildDays(
  events: RawEvent[],
  range: Range,
  viewer: string,
  prs: Map<string, ActivityPr>,
  tickets: Map<string, Ticket>,
  ticketActivity: TicketActivity[],
  older: { coverageFrom: string | null; opened: ActivityPr[]; merged: ActivityPr[]; reviewsGiven: ReviewGiven[] },
): ActivityDay[] {
  type GroupDraft = { key: string; ticketKey: string | null; title: string; entries: Map<string, DayEntry & { count: number }> }
  const days = new Map<string, { groups: Map<string, GroupDraft>; reviews: Map<string, DayEntry & { pr: ActivityPr; count: number; comments: number }> }>()
  const dayOf = (at: string) => {
    const date = localDate(at, range.timeZone)
    let day = days.get(date)
    if (!day) days.set(date, (day = { groups: new Map(), reviews: new Map() }))
    return day
  }

  /** Same-kind entries in a group on a day fold into one, counted. */
  function add(at: string, groupKey: string, ticketKey: string | null, title: string, entryKey: string, entry: DayEntry) {
    const day = dayOf(at)
    let group = day.groups.get(groupKey)
    if (!group) day.groups.set(groupKey, (group = { key: groupKey, ticketKey, title, entries: new Map() }))
    const existing = group.entries.get(entryKey)
    if (existing) {
      existing.count++
      if (at > existing.at) existing.at = at
    } else group.entries.set(entryKey, { ...entry, count: 1 })
  }

  function groupFor(repo: string, branch: string | null, pr: ActivityPr | undefined) {
    const ticketKey = (branch && branchTicketKey(branch)) ?? pr?.ticketKeys[0] ?? null
    const key = ticketKey ?? (pr ? prKey(pr.repo, pr.number) : `${repo}:${branch}`)
    const title = (ticketKey && tickets.get(ticketKey)?.title) ?? pr?.title ?? branch ?? repo
    return { key, ticketKey, title }
  }

  for (const event of events) {
    if (!inRange(event.created_at, range)) continue
    const repo = event.repo.name
    const number = eventPrNumber(event)
    const pr = number === null ? undefined : prs.get(prKey(repo, number))
    const own = pr ? pr.author?.id.toLowerCase() === viewer.toLowerCase() : true

    switch (event.type) {
      case 'PushEvent': {
        const branch = event.payload.ref?.replace(/^refs\/heads\//, '') ?? null
        if (!branch) break
        const group = groupFor(repo, branch, undefined)
        add(event.created_at, group.key, group.ticketKey, group.title, 'pushed', { kind: 'pushed', at: event.created_at, text: 'pushed', url: null })
        break
      }
      case 'PullRequestEvent': {
        const action = event.payload.action
        if (!pr || !action || !['opened', 'merged', 'closed', 'reopened'].includes(action)) break
        const group = groupFor(repo, pr.headRef, pr)
        add(event.created_at, group.key, group.ticketKey, group.title, `${action}#${pr.number}`, {
          kind: action as DayEntry['kind'],
          at: event.created_at,
          text: `${action} #${pr.number}`,
          url: pr.url,
        })
        break
      }
      case 'PullRequestReviewCommentEvent':
      case 'PullRequestReviewEvent': {
        if (!pr) break
        if (own) {
          // Answering feedback on your own PR: GitHub logs each reply as a comment and a review.
          if (event.type !== 'PullRequestReviewCommentEvent') break
          const group = groupFor(repo, pr.headRef, pr)
          add(event.created_at, group.key, group.ticketKey, group.title, `replied#${pr.number}`, {
            kind: 'replied',
            at: event.created_at,
            text: `replied to review comments on #${pr.number}`,
            url: event.payload.comment?.html_url ?? pr.url,
          })
          break
        }
        const day = dayOf(event.created_at)
        const key = prKey(repo, pr.number)
        const existing = day.reviews.get(key)
        if (event.type === 'PullRequestReviewCommentEvent') {
          if (existing) existing.comments++
          else day.reviews.set(key, { kind: 'reviewed', at: event.created_at, text: '', url: event.payload.comment?.html_url ?? pr.url, pr, count: 0, comments: 1 })
          break
        }
        const kind = REVIEW_KIND[event.payload.review?.state as keyof typeof REVIEW_KIND] ?? 'reviewed'
        // The strongest verdict of the day wins: changes requested, then approved, then comments.
        const rank = (k: DayEntry['kind']) => ['reviewed', 'approved', 'changes-requested'].indexOf(k)
        if (existing) {
          existing.count++
          if (rank(kind) > rank(existing.kind)) {
            existing.kind = kind
            existing.url = event.payload.review?.html_url ?? existing.url
          }
        } else day.reviews.set(key, { kind, at: event.created_at, text: '', url: event.payload.review?.html_url ?? pr.url, pr, count: 1, comments: 0 })
        break
      }
      case 'IssueCommentEvent': {
        if (!pr || !event.payload.issue?.pull_request) break
        const group = groupFor(repo, pr.headRef, pr)
        add(event.created_at, group.key, group.ticketKey, group.title, `commented#${pr.number}`, {
          kind: 'commented',
          at: event.created_at,
          text: `commented on #${pr.number}${own ? '' : ` by ${pr.author?.name ?? 'someone'}`}`,
          url: event.payload.comment?.html_url ?? pr.url,
        })
        break
      }
    }
  }

  // Before the events feed begins, search still knows when PRs were opened, merged and reviewed.
  const uncovered = (at: string | null): at is string =>
    inRange(at, range) && (older.coverageFrom === null || at! < older.coverageFrom)
  for (const [prsOf, action] of [
    [older.opened, 'opened'],
    [older.merged, 'merged'],
  ] as const)
    for (const pr of prsOf) {
      const at = action === 'opened' ? pr.createdAt : pr.mergedAt
      if (!uncovered(at)) continue
      const group = groupFor(pr.repo, pr.headRef, pr)
      add(at, group.key, group.ticketKey, group.title, `${action}#${pr.number}`, { kind: action, at, text: `${action} #${pr.number}`, url: pr.url })
    }
  const reviewKinds = { APPROVED: 'approved', CHANGES_REQUESTED: 'changes-requested' } as Record<string, DayEntry['kind']>
  for (const given of older.reviewsGiven)
    for (const review of given.reviews) {
      if (!uncovered(review.at)) continue
      const day = dayOf(review.at)
      const key = prKey(given.pr.repo, given.pr.number)
      if (day.reviews.has(key)) continue
      day.reviews.set(key, {
        kind: reviewKinds[review.state] ?? 'reviewed',
        at: review.at,
        text: '',
        url: review.url,
        pr: given.pr,
        count: 1,
        comments: review.comments,
      })
    }

  // Ticket moves count as the day's work on that ticket too.
  for (const activity of ticketActivity)
    for (const move of activity.transitions)
      add(move.at, activity.ticket.key, activity.ticket.key, activity.ticket.title, `ticket-${move.to}`, {
        kind: 'ticket',
        at: move.at,
        text: `moved to ${move.to}`,
        url: activity.ticket.url,
      })

  const verdict = { approved: 'approved', 'changes-requested': 'requested changes on', reviewed: 'reviewed' } as Record<string, string>
  return [...days.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, day]) => ({
      date,
      detailed: older.coverageFrom !== null && Date.parse(older.coverageFrom) <= startOfDate(date, range.timeZone).getTime(),
      groups: [...day.groups.values()]
        .map(
          (group): DayGroup => ({
            key: group.key,
            ticket: group.ticketKey ? (tickets.get(group.ticketKey) ?? null) : null,
            title: group.title,
            entries: [...group.entries.values()]
              .sort((a, b) => a.at.localeCompare(b.at))
              .map(({ count, ...entry }) => ({
                ...entry,
                text:
                  entry.kind === 'pushed'
                    ? `pushed${count > 1 ? ` ${count}×` : ''}`
                    : entry.kind === 'replied'
                      ? `replied to ${plural(count, 'review comment')} on ${entry.text.split(' on ')[1]}`
                      : entry.text,
              })),
          }),
        )
        .sort((a, b) => (b.entries.at(-1)?.at ?? '').localeCompare(a.entries.at(-1)?.at ?? '')),
      reviews: [...day.reviews.values()].map(({ count: _count, comments, ...review }) => ({
        ...review,
        text: `${verdict[review.kind] ?? 'reviewed'} #${review.pr.number}${comments ? ` · ${plural(comments, 'comment')}` : ''}`,
      })),
    }))
}

function ticketTransitions(issues: LinearIssueActivity[], range: Range): TicketActivity[] {
  return issues
    .map((issue) => ({
      ticket: toTicket(issue),
      created: issue.creator?.isMe === true && inRange(issue.createdAt, range),
      transitions: issue.history.nodes
        .filter((entry) => entry.toState && inRange(entry.createdAt, range))
        .map((entry) => ({
          at: entry.createdAt,
          from: entry.fromState?.name ?? null,
          to: entry.toState!.name,
          toType: entry.toState!.type,
          by: entry.actor?.name ?? null,
        }))
        .sort((a, b) => a.at.localeCompare(b.at)),
    }))
    .filter((activity) => activity.created || activity.transitions.length > 0)
    .sort((a, b) => (b.transitions.at(-1)?.at ?? '').localeCompare(a.transitions.at(-1)?.at ?? ''))
}

export async function buildActivity(viewer: string, range: Range): Promise<ActivityResponse> {
  const warnings: string[] = []
  const searchRange = `${searchTime(range.from)}..${searchTime(range.to)}`

  const [opened, merged, reviewed, feed, linear] = await Promise.all([
    searchActivityPrs(`is:pr author:${viewer} created:${searchRange}`, viewer),
    searchActivityPrs(`is:pr author:${viewer} merged:${searchRange}`, viewer),
    // Updated since the week began catches every PR reviewed in it; the reviews' own times decide.
    searchActivityPrs(`is:pr reviewed-by:${viewer} -author:${viewer} updated:>=${searchTime(range.from)}`, viewer),
    getUserEvents(viewer).catch((error: unknown) => {
      warnings.push(`GitHub events: ${error instanceof Error ? error.message : String(error)}`)
      return { events: [] as RawEvent[], capped: true }
    }),
    getMyIssueActivity(range.from.toISOString(), range.to.toISOString()).catch((error: unknown) => {
      warnings.push(error instanceof IntegrationNotConfigured ? `Linear: ${error.message}` : `Linear: ${String(error)}`)
      return { issues: [] as LinearIssueActivity[], truncated: false }
    }),
  ])
  const issues = linear.issues
  if (linear.truncated) warnings.push('Linear: too many tickets changed since then; some ticket moves may be missing.')

  // Every PR the week touches, by repo#number: from search, then the events' leftovers looked up.
  const prs = new Map<string, ActivityPr>()
  for (const raw of [...opened, ...merged, ...reviewed]) prs.set(prKey(raw.repository.nameWithOwner, raw.number), toActivityPr(raw))
  const rangeEvents = feed.events.filter((event) => inRange(event.created_at, range))
  const missing = new Map<string, { repo: string; number: number }>()
  for (const event of rangeEvents) {
    const number = eventPrNumber(event)
    if (number !== null && !prs.has(prKey(event.repo.name, number))) missing.set(prKey(event.repo.name, number), { repo: event.repo.name, number })
  }
  if (missing.size) for (const raw of await getPrsByNumber([...missing.values()])) prs.set(prKey(raw.repository.nameWithOwner, raw.number), toActivityPr(raw))

  // Tickets: everything Linear reported, plus any key named by a PR or pushed branch.
  const tickets = new Map(issues.map((issue) => [issue.identifier, toTicket(issue)]))
  const keys = new Set<string>([...prs.values()].flatMap((pr) => pr.ticketKeys))
  for (const event of rangeEvents) {
    const key = event.type === 'PushEvent' && event.payload.ref ? branchTicketKey(event.payload.ref.replace(/^refs\/heads\//, '')) : null
    if (key) keys.add(key)
  }
  const unknown = [...keys].filter((key) => !tickets.has(key))
  if (unknown.length) {
    try {
      for (const [key, ticket] of await getTicketsByKey(unknown)) tickets.set(key, ticket)
    } catch (error) {
      if (!(error instanceof IntegrationNotConfigured)) warnings.push(`Linear ticket lookup: ${String(error)}`)
    }
  }

  const ticketActivity = ticketTransitions(issues, range)

  const oldest = feed.events.reduce<string | null>((min, event) => (!min || event.created_at < min ? event.created_at : min), null)
  const coverageFrom = feed.capped ? oldest : new Date(Date.now() - EVENTS_MAX_AGE_MS).toISOString()
  const dayByDay: DayByDayCoverage =
    coverageFrom === null ? 'unavailable' : Date.parse(coverageFrom) <= range.from.getTime() ? 'complete' : Date.parse(coverageFrom) < range.to.getTime() ? 'partial' : 'unavailable'

  const shipped: ShippedPr[] = merged
    .map((raw) => {
      const pr = prs.get(prKey(raw.repository.nameWithOwner, raw.number))!
      const prTickets = pr.ticketKeys.flatMap((key) => tickets.get(key) ?? [])
      return { ...pr, tickets: prTickets, ticketLagging: prTickets.some((ticket) => !CLOSED_TICKET_TYPES.has(ticket.stateType)) }
    })
    .sort((a, b) => (b.mergedAt ?? '').localeCompare(a.mergedAt ?? ''))

  const reviewsGiven: ReviewGiven[] = reviewed
    .map((raw) => ({
      pr: prs.get(prKey(raw.repository.nameWithOwner, raw.number))!,
      reviews: raw.reviews.nodes
        .filter((review): review is RawActivityReview & { state: ReviewGiven['reviews'][number]['state'] } =>
          review.state !== 'PENDING' && inRange(review.submittedAt, range),
        )
        .map((review) => ({ state: review.state, at: review.submittedAt!, url: review.url, comments: review.comments.totalCount })),
    }))
    .filter((given) => given.reviews.length > 0)
    .sort((a, b) => (b.reviews.at(-1)?.at ?? '').localeCompare(a.reviews.at(-1)?.at ?? ''))

  if (dayByDay !== 'complete')
    warnings.push(
      dayByDay === 'partial'
        ? `Pushes and replies start ${localDate(coverageFrom!, range.timeZone)}: GitHub only keeps your last 300 events. PRs, reviews and tickets are complete.`
        : 'No pushes or replies this far back: GitHub only keeps your last 300 events. PRs, reviews and ticket moves are still complete.',
    )

  const days = buildDays(rangeEvents, range, viewer, prs, tickets, ticketActivity, {
    coverageFrom,
    opened: opened.map((raw) => prs.get(prKey(raw.repository.nameWithOwner, raw.number))!),
    merged: shipped,
    reviewsGiven,
  })
  // Linked PRs cost two more lookups, so only the Day view asks for them; ages every view needs.
  const [ticketCards, ticketAges] = await Promise.all([
    range.view === 'day' ? buildTicketCards(viewer, range, days, prs.values(), warnings) : {},
    buildTicketAges(days, tickets, range.timeZone, warnings),
  ])

  return {
    range: { view: range.view, start: range.start, end: range.end, timeZone: range.timeZone, isCurrent: range.isCurrent },
    viewer,
    totals: {
      prsOpened: opened.length,
      prsMerged: merged.length,
      prsReviewed: reviewsGiven.length,
      ticketsCompleted: ticketActivity.filter((a) => a.transitions.some((move) => move.toType === 'completed')).length,
      pushes: dayByDay === 'complete' ? rangeEvents.filter((event) => event.type === 'PushEvent').length : null,
    },
    dayByDay,
    coverageFrom,
    days,
    ticketCards,
    ticketAges,
    shipped,
    opened: opened.map((raw) => prs.get(prKey(raw.repository.nameWithOwner, raw.number))!).sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    reviewsGiven,
    tickets: ticketActivity,
    warnings,
    fetchedAt: new Date().toISOString(),
  }
}
