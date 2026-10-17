/**
 * Calendar days and weeks in a given time zone. A "date" is YYYY-MM-DD as people there see it;
 * instants are real moments. Weeks run Monday to Sunday.
 */

const DAY_MS = 86_400_000

function parts(instant: Date, timeZone: string): Record<string, number> {
  const formatted = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(instant)
  return Object.fromEntries(formatted.filter((p) => p.type !== 'literal').map((p) => [p.type, Number(p.value)]))
}

/** How far the zone is ahead of UTC at that instant. */
function offsetMs(instant: Date, timeZone: string): number {
  const p = parts(instant, timeZone)
  return Date.UTC(p.year!, p.month! - 1, p.day!, p.hour!, p.minute!, p.second!) - Math.floor(instant.getTime() / 1000) * 1000
}

/** The calendar date of an instant in the zone. */
export function localDate(instant: Date | string, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(
    new Date(instant),
  )
}

/** The instant a calendar date starts in the zone, allowing for daylight saving. */
export function startOfDate(date: string, timeZone: string): Date {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  const guess = Date.UTC(y, m - 1, d)
  let instant = guess - offsetMs(new Date(guess), timeZone)
  const corrected = guess - offsetMs(new Date(instant), timeZone)
  if (corrected !== instant) instant = corrected
  return new Date(instant)
}

export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  return new Date(Date.UTC(y, m - 1, d) + days * DAY_MS).toISOString().slice(0, 10)
}

/** The Monday on or before the date. */
export function mondayOf(date: string): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay()
  return addDays(date, -((weekday + 6) % 7))
}

export const isDate = (value: string) => /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value))

export type ActivityView = 'day' | 'week' | 'month'

/** A span of whole calendar days in a zone; `from` is inclusive and `to` exclusive. */
export type Range = {
  view: ActivityView
  /** First day, YYYY-MM-DD. */
  start: string
  /** Last day, YYYY-MM-DD (inclusive). */
  end: string
  from: Date
  to: Date
  timeZone: string
  /** Today falls inside it. */
  isCurrent: boolean
}

function lastOfMonth(date: string): string {
  const [y, m] = date.split('-').map(Number) as [number, number]
  return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10)
}

/** The day, the Monday-to-Sunday week, or the calendar month containing `date`. */
export function rangeOf(view: ActivityView, date: string, timeZone: string, now = new Date()): Range {
  const start = view === 'day' ? date : view === 'week' ? mondayOf(date) : `${date.slice(0, 7)}-01`
  const end = view === 'day' ? date : view === 'week' ? addDays(start, 6) : lastOfMonth(start)
  const today = localDate(now, timeZone)
  return {
    view,
    start,
    end,
    from: startOfDate(start, timeZone),
    to: startOfDate(addDays(end, 1), timeZone),
    timeZone,
    isCurrent: start <= today && today <= end,
  }
}

/** True for a zone name the runtime knows, e.g. "Europe/London". */
export function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat('en', { timeZone: value })
    return true
  } catch {
    return false
  }
}
