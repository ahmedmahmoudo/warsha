import type { Meeting } from '../../../shared/calendar'
import { addDays } from '../activity/calendar'

/** Meeting times in a chosen zone: which day they fall on and where in it. */

export const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone

/** "Australia/Sydney" → "Sydney". */
export function city(zone: string): string {
  return zone.split('/').at(-1)!.replaceAll('_', ' ')
}

const partsFormats = new Map<string, Intl.DateTimeFormat>()

/** The calendar date and minute of the day an instant falls on in a zone. */
export function zoned(iso: string, timeZone: string): { date: string; minutes: number } {
  let format = partsFormats.get(timeZone)
  if (!format) {
    format = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    partsFormats.set(timeZone, format)
  }
  const part = Object.fromEntries(format.formatToParts(new Date(iso)).map((p) => [p.type, p.value]))
  return { date: `${part.year}-${part.month}-${part.day}`, minutes: Number(part.hour) * 60 + Number(part.minute) }
}

/** The days a meeting covers in a zone (all-day ones by their own dates, whatever the zone). */
export function meetingDays(meeting: Pick<Meeting, 'start' | 'end' | 'allDay'>, timeZone: string): { first: string; last: string } {
  if (meeting.allDay) return { first: meeting.start, last: addDays(meeting.end, -1) }
  const end = zoned(meeting.end, timeZone)
  const first = zoned(meeting.start, timeZone).date
  // Ending exactly at midnight belongs to the day before.
  const last = end.minutes === 0 && end.date > first ? addDays(end.date, -1) : end.date
  return { first, last }
}

export const onDay = (meeting: Meeting, day: string, timeZone: string) => {
  const { first, last } = meetingDays(meeting, timeZone)
  return first <= day && day <= last
}

const formats = new Map<string, Intl.DateTimeFormat>()
function format(timeZone: string, options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const key = `${timeZone}|${JSON.stringify(options)}`
  let found = formats.get(key)
  if (!found) {
    found = new Intl.DateTimeFormat('en-AU', { ...options, timeZone })
    formats.set(key, found)
  }
  return found
}

const TIME: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit' }
const DAY: Intl.DateTimeFormatOptions = { weekday: 'short', day: 'numeric', month: 'short' }

export const clock = (iso: string, timeZone: string) => format(timeZone, TIME).format(new Date(iso))

/** "10:00 – 10:30 am", "Tue 20 Oct, 10:00 – 10:30 am" with `withDay`, or "All day". */
export function timeRange(meeting: Pick<Meeting, 'start' | 'end' | 'allDay'>, timeZone: string, withDay: boolean): string {
  if (meeting.allDay) {
    const day = format('UTC', DAY).format(new Date(`${meeting.start}T12:00:00Z`))
    return withDay ? `${day}, all day` : 'All day'
  }
  const range = format(timeZone, TIME).formatRange(new Date(meeting.start), new Date(meeting.end))
  return withDay ? `${format(timeZone, DAY).format(new Date(meeting.start))}, ${range}` : range
}
