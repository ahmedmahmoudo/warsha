/** A meeting on your primary Google Calendar. `start`/`end` are ISO times, or YYYY-MM-DD for all-day events. */
export type CalendarEvent = {
  id: string
  title: string
  start: string
  end: string
  allDay: boolean
  url: string | null
}

export type GoogleStatus =
  | { state: 'unconfigured' }
  | { state: 'disconnected' }
  /** `events` is the next few meetings, fetched live to prove the connection works; `error` when that failed. */
  | { state: 'connected'; email: string | null; events: CalendarEvent[]; error: string | null }
