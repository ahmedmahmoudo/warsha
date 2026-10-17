import { Hono } from 'hono'
import type { CalendarConnection, CalendarRangeResponse, Meeting, MeetingsTodayResponse } from '../../shared/calendar'
import { localDate, startOfDate } from '../activity/week'
import { env } from '../env'
import { googleAccount, googleConfigured, listEvents } from '../integrations/google'
import { createSwrCache } from '../lib/swrCache'
import { meetings } from '../store/repo'
import { lastSync, overlaps, syncMeetings } from './sync'

const DAY_MS = 86_400_000
/** The widest range the Calendar page may ask for: a month view plus its padding. */
const MAX_RANGE_MS = 50 * DAY_MS
const RANGE_STALE_AFTER_MS = 30_000

const connection = (): CalendarConnection => (!googleConfigured() ? 'unconfigured' : googleAccount() ? 'connected' : 'disconnected')

const byStart = (a: Meeting, b: Meeting) => a.start.localeCompare(b.start)
const changedAt = (meeting: Meeting) => meeting.change?.at ?? ''

/** Ranges the Calendar page shows, read live from Google; the saved meetings add what changed. */
const ranges = createSwrCache<string, Meeting[]>({
  load: async (key) => {
    const [timeMin, timeMax] = key.split('|') as [string, string]
    const events = await listEvents({ timeMin, timeMax })
    return events.map((event) => ({
      id: event.id,
      title: event.title,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
      joinUrl: event.joinUrl,
      htmlUrl: event.htmlUrl,
      location: event.location,
      declined: event.response === 'declined',
      change: null,
    }))
  },
  staleAfterMs: RANGE_STALE_AFTER_MS,
})

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$/

export const calendarRoute = new Hono()
  /** Today's meetings and every change, after syncing with Google (Refresh forces it). */
  .get('/today', async (c) => {
    const base = { connection: connection(), timeZone: env.timeZone }
    if (base.connection !== 'connected') return c.json<MeetingsTodayResponse>({ ...base, today: [], changes: [], syncedAt: null, error: null })
    await syncMeetings({ force: c.req.query('fresh') === '1' })

    const today = localDate(new Date(), env.timeZone)
    const from = startOfDate(today, env.timeZone).getTime()
    const saved = meetings.list()
    const sync = lastSync()
    return c.json<MeetingsTodayResponse>({
      ...base,
      today: saved.filter((meeting) => meeting.change?.kind !== 'deleted' && overlaps(meeting, from, from + DAY_MS)).sort(byStart),
      changes: saved.filter((meeting) => meeting.change).sort((a, b) => changedAt(b).localeCompare(changedAt(a))),
      syncedAt: sync?.at ?? null,
      error: sync?.error ?? null,
    })
  })
  /** Every meeting overlapping [start, end) (UTC ISO instants), with change marks from the saved ones. */
  .get('/range', async (c) => {
    const base = { connection: connection(), timeZone: env.timeZone }
    if (base.connection !== 'connected') return c.json<CalendarRangeResponse>({ ...base, meetings: [], error: null })
    const { start = '', end = '', fresh } = c.req.query()
    const from = Date.parse(start)
    const to = Date.parse(end)
    if (!ISO.test(start) || !ISO.test(end) || !(to > from) || to - from > MAX_RANGE_MS) return c.json({ error: 'start and end must be UTC ISO times, under 50 days apart' }, 400)

    await syncMeetings({ force: fresh === '1' })
    let live: Meeting[] = []
    let error: string | null = null
    try {
      live = await ranges.get(`${start}|${end}`, { force: fresh === '1' })
    } catch (failure) {
      error = failure instanceof Error ? failure.message : String(failure)
    }
    const saved = new Map(meetings.list().map((meeting) => [meeting.id, meeting]))
    const merged = new Map(live.map((meeting) => [meeting.id, { ...meeting, change: saved.get(meeting.id)?.change ?? null }]))
    // Deleted meetings are gone from Google's list; the saved copy shows them until they're forgotten.
    for (const meeting of saved.values())
      if (meeting.change?.kind === 'deleted' && overlaps(meeting, from, to)) merged.set(meeting.id, meeting)
    return c.json<CalendarRangeResponse>({ ...base, meetings: [...merged.values()].sort(byStart), error: error ?? lastSync()?.error ?? null })
  })
  /** Dismisses a change: a reschedule becomes the known time; a deleted meeting is forgotten now. */
  .post('/changes/:id/dismiss', (c) => {
    const meeting = meetings.get(c.req.param('id'))
    if (!meeting?.change) return c.json({ error: 'No change to dismiss' }, 404)
    if (meeting.change.kind === 'deleted') meetings.remove(meeting.id)
    else meetings.acknowledge(meeting.id)
    return c.json({ ok: true })
  })
