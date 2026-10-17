import type { ActivityDay, ActivityPr, LinkedPr, TicketAge, TicketCard } from '../../shared/activity'
import type { Ticket } from '../../shared/prs'
import { IntegrationNotConfigured } from '../integrations/errors'
import { searchActivityPrs } from '../integrations/github'
import { getTicketStateSince } from '../integrations/linear'
import { extractTicketKeys } from '../prs/derive'
import { getMyOpenPrs } from '../prs/route'
import { addDays, localDate, type Range } from './week'

/**
 * How long a status can last before the Day view flags it, in working days. Review should move
 * faster than building, so it turns yellow and red sooner.
 */
const AGE_LIMITS = {
  review: { warn: 2, alert: 5 },
  progress: { warn: 3, alert: 7 },
} as const

/** Linked PRs are looked for this far back, so a ticket started weeks ago still finds its PR. */
const LINKED_PR_LOOKBACK_DAYS = 60
const MAX_WORKING_DAYS_COUNTED = 400

/** Weekdays after `since` up to today, both read in the zone. */
function workingDaysSince(since: string, timeZone: string, now = new Date()): number {
  const today = localDate(now, timeZone)
  let count = 0
  let day = addDays(localDate(since, timeZone), 1)
  for (let i = 0; day <= today && i < MAX_WORKING_DAYS_COUNTED; i++, day = addDays(day, 1)) {
    const weekday = new Date(`${day}T12:00:00Z`).getUTCDay()
    if (weekday !== 0 && weekday !== 6) count++
  }
  return count
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? '' : 's'}`
}

/** Only in-flight statuses age: In Progress and In Review, not Merged, Done or Backlog. */
function ticketAge(ticket: Ticket, since: string | undefined, timeZone: string): TicketAge | null {
  if (!since || ticket.stateType !== 'started' || /merged/i.test(ticket.state)) return null
  const kind = /review/i.test(ticket.state) ? 'review' : 'progress'
  const workingDays = workingDaysSince(since, timeZone)
  const limits = AGE_LIMITS[kind]
  const level = workingDays >= limits.alert ? 'alert' : workingDays >= limits.warn ? 'warn' : 'ok'
  const hint =
    level === 'alert'
      ? kind === 'review'
        ? 'stuck in review'
        : 'consider flagging or splitting it'
      : kind === 'review'
        ? 'worth a nudge'
        : 'taking a while'
  return {
    state: ticket.state,
    since,
    workingDays,
    level,
    message: level === 'ok' ? null : `${ticket.state} for ${plural(workingDays, 'working day')}, ${hint}`,
  }
}

const STATE_SINCE_CHUNK = 25

function ticketKeysIn(days: ActivityDay[]): string[] {
  return [...new Set(days.flatMap((day) => day.groups.flatMap((group) => (group.ticket ? [group.ticket.key] : []))))]
}

/** Status age for every in-flight ticket the range touches. */
export function buildTicketAges(
  days: ActivityDay[],
  tickets: Map<string, Ticket>,
  timeZone: string,
  warnings: string[],
): Promise<Record<string, TicketAge>> {
  return ticketAgesFor(ticketKeysIn(days).flatMap((key) => tickets.get(key) ?? []), timeZone, warnings)
}

/** Status age for each in-flight ticket, looked up a chunk of keys at a time. */
export async function ticketAgesFor(list: Ticket[], timeZone: string, warnings: string[]): Promise<Record<string, TicketAge>> {
  const tickets = new Map(list.map((ticket) => [ticket.key, ticket]))
  // Only tickets that can age need their history.
  const keys = [...tickets.keys()].filter((key) => {
    const ticket = tickets.get(key)!
    return ticket.stateType === 'started' && !/merged/i.test(ticket.state)
  })
  const chunks: string[][] = []
  for (let i = 0; i < keys.length; i += STATE_SINCE_CHUNK) chunks.push(keys.slice(i, i + STATE_SINCE_CHUNK))
  let since: Map<string, string>
  try {
    since = new Map((await Promise.all(chunks.map(getTicketStateSince))).flatMap((chunk) => [...chunk]))
  } catch (error) {
    if (!(error instanceof IntegrationNotConfigured)) warnings.push(`Linear status history: ${String(error)}`)
    return {}
  }
  return Object.fromEntries(
    keys.flatMap((key) => {
      const age = ticketAge(tickets.get(key)!, since.get(key), timeZone)
      return age ? [[key, age]] : []
    }),
  )
}

const OPEN_FIRST = { OPEN: 0, MERGED: 1, CLOSED: 2 } as const

/**
 * For the Day view: every ticket in the day with the PRs that belong to it, open ones carrying the
 * PR list's status.
 */
export async function buildTicketCards(
  viewer: string,
  range: Range,
  days: ActivityDay[],
  known: Iterable<ActivityPr>,
  warnings: string[],
): Promise<Record<string, TicketCard>> {
  const keys = ticketKeysIn(days)
  if (keys.length === 0) return {}

  const lookbackFrom = new Date(range.from.getTime() - LINKED_PR_LOOKBACK_DAYS * 86_400_000)
  const [recent, open] = await Promise.all([
    searchActivityPrs(`is:pr author:${viewer} updated:>=${lookbackFrom.toISOString().replace(/\.\d{3}Z$/, '+00:00')}`, viewer).catch(
      (error: unknown) => {
        warnings.push(`Couldn't look up linked PRs: ${String(error)}`)
        return []
      },
    ),
    getMyOpenPrs().catch(() => []),
  ])

  const pool = new Map<string, ActivityPr>()
  for (const pr of known) pool.set(pr.url, pr)
  for (const raw of recent)
    if (!pool.has(raw.url))
      pool.set(raw.url, {
        repo: raw.repository.nameWithOwner,
        number: raw.number,
        title: raw.title,
        url: raw.url,
        author: null,
        state: raw.state,
        isDraft: raw.isDraft,
        createdAt: raw.createdAt,
        mergedAt: raw.mergedAt,
        headRef: raw.headRefName,
        ticketKeys: [],
      })
  // Search results arrive without ticket keys worked out; match them the same way PRs are matched.
  for (const raw of recent) {
    const pr = pool.get(raw.url)!
    if (pr.ticketKeys.length === 0) pr.ticketKeys = extractTicketKeys({ headRefName: raw.headRefName, title: raw.title, body: raw.body })
  }
  const statusByUrl = new Map(open.map((pr) => [pr.url, pr.status]))

  return Object.fromEntries(
    keys.map((key): [string, TicketCard] => {
      const prs: LinkedPr[] = [...pool.values()]
        .filter((pr) => pr.ticketKeys.includes(key))
        .sort((a, b) => OPEN_FIRST[a.state] - OPEN_FIRST[b.state] || b.createdAt.localeCompare(a.createdAt))
        .map((pr) => ({ ...pr, status: pr.state === 'OPEN' ? (statusByUrl.get(pr.url) ?? null) : null }))
      return [key, { prs }]
    }),
  )
}
