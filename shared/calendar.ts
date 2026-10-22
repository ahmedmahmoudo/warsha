/** The contract between `/api/calendar/*` and the Today and Calendar pages. */

/** What happened to a meeting since Warsha last saw it. */
export type MeetingChange =
  /** Its time moved; `previous*` is the time you last knew it at. */
  | { kind: 'rescheduled'; previousStart: string; previousEnd: string; at: string }
  /** Gone from your calendar. Kept for a day after `at`, then forgotten. */
  | { kind: 'deleted'; at: string }

/** A meeting on your primary Google Calendar. Timed ones are UTC ISO instants; all-day ones are YYYY-MM-DD with an exclusive end. */
export type Meeting = {
  id: string
  title: string
  start: string
  end: string
  allDay: boolean
  joinUrl: string | null
  htmlUrl: string | null
  location: string | null
  declined: boolean
  change: MeetingChange | null
}

export type CalendarConnection = 'unconfigured' | 'disconnected' | 'connected'

export type MeetingsTodayResponse = {
  connection: CalendarConnection
  /** The zone "today" follows (TIMEZONE), shown beside your browser's own. */
  timeZone: string
  /** Today's meetings in `timeZone`, in time order; deleted ones are under `changes` instead. */
  today: Meeting[]
  /** Rescheduled and deleted meetings, any day, newest change first, until dismissed. */
  changes: Meeting[]
  syncedAt: string | null
  error: string | null
}

export type CalendarRangeResponse = {
  connection: CalendarConnection
  timeZone: string
  /** Everything overlapping the range, deleted meetings included (marked by `change`). */
  meetings: Meeting[]
  error: string | null
}
