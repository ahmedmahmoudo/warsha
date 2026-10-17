import type { Meeting } from '../../shared/calendar'
import { localDate, startOfDate } from '../activity/week'
import { env } from '../env'
import { getEvent, googleAccount, listEvents } from '../integrations/google'
import { meetings } from '../store/repo'

/**
 * Keeps the saved meetings in step with Google: from the start of today to SYNC_DAYS ahead, every
 * meeting Google returns is saved (a new time marks it rescheduled), and a saved one Google no
 * longer has is marked deleted. Runs when the server starts and when a page asks, at most once a
 * minute unless forced.
 */

const SYNC_DAYS = 30
const MIN_INTERVAL_MS = 60_000
const DAY_MS = 86_400_000
/** A deleted meeting stays visible this long after it was noticed, then is forgotten. */
const KEEP_DELETED_MS = DAY_MS
/** Saved meetings missing from the list are looked up one by one; this caps the lookups per sync. */
const MAX_LOOKUPS = 25

let last: { at: number; error: string | null } | null = null
let running: Promise<void> | null = null

export const lastSync = () => (last ? { at: new Date(last.at).toISOString(), error: last.error } : null)

/** When a meeting ends, as epoch ms; an all-day end date counts from its start of day in TIMEZONE. */
function endsAt(meeting: Meeting): number {
  return meeting.allDay ? startOfDate(meeting.end, env.timeZone).getTime() : Date.parse(meeting.end)
}

function startsAt(meeting: Pick<Meeting, 'start' | 'allDay'>): number {
  return meeting.allDay ? startOfDate(meeting.start, env.timeZone).getTime() : Date.parse(meeting.start)
}

export function overlaps(meeting: Meeting, from: number, to: number): boolean {
  return startsAt(meeting) < to && endsAt(meeting) > from
}

export async function syncMeetings({ force = false }: { force?: boolean } = {}): Promise<void> {
  if (!googleAccount()) return
  if (!force && last && Date.now() - last.at < MIN_INTERVAL_MS) return
  running ??= run()
    .then(() => {
      last = { at: Date.now(), error: null }
    })
    .catch((error: unknown) => {
      last = { at: Date.now(), error: error instanceof Error ? error.message : String(error) }
      console.error('[calendar] sync failed', error)
    })
    .finally(() => {
      running = null
    })
  return running
}

async function run(): Promise<void> {
  const now = Date.now()
  const at = new Date(now).toISOString()
  const from = startOfDate(localDate(new Date(now), env.timeZone), env.timeZone).getTime()
  const to = from + SYNC_DAYS * DAY_MS

  const events = await listEvents({ timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(), showDeleted: true })
  const returned = new Set<string>()
  for (const event of events) {
    returned.add(event.id)
    // A cancelled event only matters if you'd seen it; one never saved stays unknown.
    if (event.cancelled) meetings.markDeleted(event.id, at)
    else meetings.save(event, at)
  }

  // Saved and due in the window, yet not returned at all: deleted outright, or moved out of the window.
  const missing = meetings.list().filter((meeting) => meeting.change?.kind !== 'deleted' && !returned.has(meeting.id) && overlaps(meeting, from, to))
  for (const meeting of missing.slice(0, MAX_LOOKUPS)) {
    const event = await getEvent(meeting.id)
    if (!event || event.cancelled) meetings.markDeleted(meeting.id, at)
    else meetings.save(event, at)
  }

  // Forget meetings that are over, and deletions shown for long enough.
  for (const meeting of meetings.list()) {
    const expired =
      meeting.change?.kind === 'deleted' ? now - Date.parse(meeting.change.at) > KEEP_DELETED_MS : endsAt(meeting) < from
    if (expired) meetings.remove(meeting.id)
  }
}
