import type { ActivityView } from '../../../shared/activity'

/** Calendar maths on YYYY-MM-DD strings. Noon UTC keeps the day fixed whatever the display zone. */

const DAY_MS = 86_400_000

export function dateAt(date: string): Date {
  return new Date(`${date}T12:00:00Z`)
}

export function addDays(date: string, days: number): string {
  return new Date(dateAt(date).getTime() + days * DAY_MS).toISOString().slice(0, 10)
}

export function addMonths(date: string, months: number): string {
  const [y, m] = date.split('-').map(Number) as [number, number]
  return new Date(Date.UTC(y, m - 1 + months, 1, 12)).toISOString().slice(0, 10)
}

export function mondayOf(date: string): string {
  return addDays(date, -((dateAt(date).getUTCDay() + 6) % 7))
}

/** Today's date in a zone. */
export function todayIn(timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
}

/** Every day from the Monday before the 1st to the Sunday after the last, in weeks. */
export function monthGrid(monthStart: string, monthEnd: string): string[][] {
  const weeks: string[][] = []
  for (let day = mondayOf(monthStart); day <= monthEnd; day = addDays(day, 7))
    weeks.push(Array.from({ length: 7 }, (_, i) => addDays(day, i)))
  return weeks
}

/** The date to move to for the previous or next day, week or month. */
export function step(view: ActivityView, date: string, by: 1 | -1): string {
  return view === 'day' ? addDays(date, by) : view === 'week' ? addDays(date, 7 * by) : addMonths(date, by)
}

const fmt = (options: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('en-AU', { ...options, timeZone: 'UTC' })
const dayLong = fmt({ weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })
const dayShort = fmt({ day: 'numeric', month: 'short' })
const monthYear = fmt({ month: 'long', year: 'numeric' })
const yearOnly = fmt({ year: 'numeric' })
export const weekdayShort = fmt({ weekday: 'short' })
export const dayOfMonth = fmt({ day: 'numeric' })
export const dayHeading = fmt({ weekday: 'long', day: 'numeric', month: 'long' })

export function rangeLabel(view: ActivityView, start: string, end: string): string {
  if (view === 'day') return dayLong.format(dateAt(start))
  if (view === 'month') return monthYear.format(dateAt(start))
  return `${dayShort.format(dateAt(start))} – ${dayShort.format(dateAt(end))} ${yearOnly.format(dateAt(end))}`
}
