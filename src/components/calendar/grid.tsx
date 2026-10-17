import { Popover } from 'radix-ui'
import { CalendarX2, ExternalLink, History, MapPin } from 'lucide-react'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { Meeting } from '../../../shared/calendar'
import { dateAt, dayOfMonth, monthGrid, weekdayShort } from '../activity/calendar'
import { BothZones, JoinButton, useDismissChange } from './MeetingBits'
import { clock, onDay, timeRange, zoned } from './time'

/** Google Calendar-like views: a time grid for days and weeks, a month grid of chips. */

const HOUR_PX = 48
const DAY_MINUTES = 24 * 60
/** Short meetings still get room for a title. */
const MIN_BLOCK_PX = 20
const SCROLL_TO_HOUR = 7
const MONTH_CHIPS = 3

/** A meeting's block on one day, or a dashed ghost where a rescheduled one used to be. */
type Block = { meeting: Meeting; startMin: number; endMin: number; ghost: boolean }
type Placed = Block & { column: number; columns: number }

function blockOn(meeting: Meeting, start: string, end: string, day: string, timeZone: string, ghost: boolean): Block | null {
  const from = zoned(start, timeZone)
  const to = zoned(end, timeZone)
  if (from.date > day || to.date < day || (to.date === day && to.minutes === 0 && from.date < day)) return null
  const startMin = from.date < day ? 0 : from.minutes
  const endMin = to.date > day ? DAY_MINUTES : to.minutes
  return { meeting, startMin, endMin: Math.max(endMin, startMin + 15), ghost }
}

/** Overlapping blocks share the width side by side, the way Google lays them out. */
function layout(blocks: Block[]): Placed[] {
  const sorted = [...blocks].sort((a, b) => a.startMin - b.startMin || b.endMin - a.endMin)
  const placed: Placed[] = []
  let cluster: Placed[] = []
  let columnEnds: number[] = []
  let clusterEnd = -1
  const close = () => {
    for (const block of cluster) block.columns = columnEnds.length
    cluster = []
    columnEnds = []
  }
  for (const block of sorted) {
    if (block.startMin >= clusterEnd) close()
    let column = columnEnds.findIndex((end) => end <= block.startMin)
    if (column === -1) column = columnEnds.push(0) - 1
    columnEnds[column] = block.endMin
    const item = { ...block, column, columns: 1 }
    cluster.push(item)
    placed.push(item)
    clusterEnd = Math.max(clusterEnd, block.endMin)
  }
  close()
  return placed
}

function blockClasses(meeting: Meeting, ghost: boolean): string {
  if (ghost) return 'border border-dashed border-warn/60 bg-transparent text-warn/80'
  if (meeting.change?.kind === 'deleted') return 'border border-dashed border-bad/50 bg-bad-soft/40 text-muted-foreground line-through'
  if (meeting.declined) return 'border border-primary/30 bg-transparent text-muted-foreground'
  if (meeting.change?.kind === 'rescheduled') return 'border-l-[3px] border-warn bg-warn-soft text-foreground'
  return 'border-l-[3px] border-primary bg-primary/15 text-foreground'
}

/** What a meeting is, when (both zones), and what changed, opened from any block or chip. */
export function MeetingDetails({ meeting, homeZone, children }: { meeting: Meeting; homeZone: string; children: ReactNode }) {
  const dismiss = useDismissChange()
  const change = meeting.change
  return (
    <Popover.Root>
      <Popover.Trigger asChild>{children}</Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          side="right"
          align="start"
          sideOffset={6}
          collisionPadding={12}
          className="z-50 flex w-80 flex-col gap-2 rounded-lg border border-border bg-popover p-3 text-sm text-popover-foreground shadow-lg"
        >
          <p className={`font-semibold ${change?.kind === 'deleted' ? 'line-through' : ''}`}>{meeting.title}</p>
          <p className="text-xs text-muted-foreground">
            <BothZones meeting={meeting} homeZone={homeZone} withDay />
          </p>
          {meeting.location && !meeting.location.startsWith('http') && (
            <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <MapPin className="size-3.5" />
              {meeting.location}
            </p>
          )}
          {change?.kind === 'rescheduled' && (
            <p className="flex items-start gap-1.5 rounded-md bg-warn-soft px-2 py-1.5 text-xs text-warn">
              <History className="mt-px size-3.5 shrink-0" />
              <span>Rescheduled from {timeRange({ start: change.previousStart, end: change.previousEnd, allDay: meeting.allDay }, homeZone, true)}</span>
            </p>
          )}
          {change?.kind === 'deleted' && (
            <p className="flex items-center gap-1.5 rounded-md bg-bad-soft px-2 py-1.5 text-xs text-bad">
              <CalendarX2 className="size-3.5" />
              Deleted from your calendar
            </p>
          )}
          {meeting.declined && <p className="text-xs text-muted-foreground">You declined this one.</p>}
          <div className="flex items-center gap-2 pt-1">
            <JoinButton meeting={meeting} />
            {meeting.htmlUrl && change?.kind !== 'deleted' && (
              <a href={meeting.htmlUrl} target="_blank" rel="noreferrer" className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground">
                Open in Google Calendar
                <ExternalLink className="size-3" />
              </a>
            )}
            {change && (
              <button
                type="button"
                onClick={() => dismiss.mutate(meeting.id)}
                disabled={dismiss.isPending}
                className="ml-auto text-xs text-muted-foreground hover:text-foreground disabled:opacity-60"
              >
                Dismiss
              </button>
            )}
          </div>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}

function useNow(): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(timer)
  }, [])
  return now
}

/** Days side by side with an hour scale, all-day meetings in a strip on top. */
export function TimeGrid({ days, meetings, timeZone, homeZone, today }: { days: string[]; meetings: Meeting[]; timeZone: string; homeZone: string; today: string }) {
  const scroller = useRef<HTMLDivElement>(null)
  const now = useNow()
  const nowAt = zoned(new Date(now).toISOString(), timeZone)

  useEffect(() => {
    if (scroller.current) scroller.current.scrollTop = SCROLL_TO_HOUR * HOUR_PX
  }, [])

  const allDay = meetings.filter((meeting) => meeting.allDay)
  const timed = meetings.filter((meeting) => !meeting.allDay)
  const columns = `3rem repeat(${days.length}, minmax(0, 1fr))`

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card">
      <div className="grid border-b border-border" style={{ gridTemplateColumns: columns }}>
        <div />
        {days.map((day) => (
          <div key={day} className="flex flex-col items-center gap-0.5 border-l border-border py-2 text-xs">
            <span className="text-muted-foreground">{weekdayShort.format(dateAt(day))}</span>
            <span className={`flex size-7 items-center justify-center rounded-full text-base ${day === today ? 'bg-primary font-semibold text-primary-foreground' : ''}`}>
              {dayOfMonth.format(dateAt(day))}
            </span>
          </div>
        ))}
      </div>
      {allDay.length > 0 && (
        <div className="grid border-b border-border" style={{ gridTemplateColumns: columns }}>
          <div className="py-1 pr-1 text-right text-[0.6rem] text-faint">all day</div>
          {days.map((day) => (
            <div key={day} className="flex min-w-0 flex-col gap-0.5 border-l border-border p-0.5">
              {allDay
                .filter((meeting) => onDay(meeting, day, timeZone))
                .map((meeting) => (
                  <MeetingDetails key={meeting.id} meeting={meeting} homeZone={homeZone}>
                    <button type="button" className={`truncate rounded px-1.5 py-0.5 text-left text-xs ${blockClasses(meeting, false)}`}>
                      {meeting.title}
                    </button>
                  </MeetingDetails>
                ))}
            </div>
          ))}
        </div>
      )}
      <div ref={scroller} className="max-h-[70vh] overflow-y-auto">
        <div className="relative grid" style={{ gridTemplateColumns: columns, height: 24 * HOUR_PX }}>
          <div className="relative">
            {Array.from({ length: 23 }, (_, i) => i + 1).map((hour) => (
              <span key={hour} className="absolute right-1.5 -translate-y-1/2 text-[0.65rem] text-faint" style={{ top: hour * HOUR_PX }}>
                {clock(`2000-01-01T${String(hour).padStart(2, '0')}:00:00Z`, 'UTC').replace(':00', '')}
              </span>
            ))}
          </div>
          {days.map((day) => {
            const blocks = timed.flatMap((meeting) => {
              const own = blockOn(meeting, meeting.start, meeting.end, day, timeZone, false)
              const was = meeting.change?.kind === 'rescheduled' ? blockOn(meeting, meeting.change.previousStart, meeting.change.previousEnd, day, timeZone, true) : null
              return [own, was].filter((block): block is Block => block !== null)
            })
            return (
              <div key={day} className="relative border-l border-border">
                {Array.from({ length: 23 }, (_, i) => (
                  <div key={i} className="absolute inset-x-0 border-t border-border/60" style={{ top: (i + 1) * HOUR_PX }} />
                ))}
                {layout(blocks).map((block) => {
                  const top = (block.startMin / 60) * HOUR_PX
                  const height = Math.max(((block.endMin - block.startMin) / 60) * HOUR_PX - 2, MIN_BLOCK_PX)
                  const short = height < 36
                  return (
                    <MeetingDetails key={`${block.meeting.id}${block.ghost ? ':was' : ''}`} meeting={block.meeting} homeZone={homeZone}>
                      <button
                        type="button"
                        title={block.ghost ? `${block.meeting.title} (moved from here)` : block.meeting.title}
                        className={`absolute overflow-hidden rounded-md px-1.5 py-0.5 text-left text-xs leading-tight hover:z-10 hover:shadow-md ${blockClasses(block.meeting, block.ghost)}`}
                        style={{
                          top,
                          height,
                          left: `calc(${(block.column / block.columns) * 100}% + 1px)`,
                          width: `calc(${100 / block.columns}% - 3px)`,
                        }}
                      >
                        <span className={`block truncate font-medium ${short ? 'inline' : ''}`}>
                          {block.ghost && 'Moved: '}
                          {block.meeting.title}
                        </span>
                        <span className={`truncate text-[0.65rem] opacity-80 ${short ? 'ml-1 inline' : 'block'}`}>
                          {block.ghost ? 'was here' : clock(block.meeting.start, timeZone)}
                        </span>
                      </button>
                    </MeetingDetails>
                  )
                })}
                {day === nowAt.date && (
                  <div className="pointer-events-none absolute inset-x-0 z-20 flex items-center" style={{ top: (nowAt.minutes / 60) * HOUR_PX }}>
                    <span className="-ml-1 size-2 rounded-full bg-bad" />
                    <span className="h-px flex-1 bg-bad" />
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

/** Weeks of days, each with its first few meetings as chips. */
export function MonthGrid({
  monthStart,
  monthEnd,
  meetings,
  timeZone,
  homeZone,
  today,
  onOpenDay,
}: {
  monthStart: string
  monthEnd: string
  meetings: Meeting[]
  timeZone: string
  homeZone: string
  today: string
  onOpenDay: (day: string) => void
}) {
  const weeks = monthGrid(monthStart, monthEnd)
  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card">
      <div className="grid grid-cols-7 border-b border-border bg-muted/40 text-xs text-muted-foreground">
        {weeks[0]!.map((day) => (
          <div key={day} className="px-2 py-1.5">
            {weekdayShort.format(dateAt(day))}
          </div>
        ))}
      </div>
      {weeks.map((week) => (
        <div key={week[0]} className="grid grid-cols-7 border-b border-border last:border-b-0">
          {week.map((day) => {
            const inMonth = day >= monthStart && day <= monthEnd
            const onThisDay = meetings.filter((meeting) => onDay(meeting, day, timeZone))
            return (
              <div key={day} className={`flex min-h-28 min-w-0 flex-col gap-0.5 border-l border-border p-1 first:border-l-0 ${inMonth ? '' : 'bg-muted/30'}`}>
                <button
                  type="button"
                  onClick={() => onOpenDay(day)}
                  className={`flex size-6 items-center justify-center self-center rounded-full text-xs hover:bg-accent ${
                    day === today ? 'bg-primary font-semibold text-primary-foreground hover:bg-primary' : inMonth ? '' : 'text-faint'
                  }`}
                >
                  {dayOfMonth.format(dateAt(day))}
                </button>
                {onThisDay.slice(0, MONTH_CHIPS).map((meeting) => (
                  <MeetingDetails key={meeting.id} meeting={meeting} homeZone={homeZone}>
                    <button type="button" className={`flex min-w-0 items-center gap-1 truncate rounded px-1 py-0.5 text-left text-[0.7rem] ${blockClasses(meeting, false)}`}>
                      {!meeting.allDay && <span className="shrink-0 opacity-70">{clock(meeting.start, timeZone)}</span>}
                      <span className="truncate">{meeting.title}</span>
                    </button>
                  </MeetingDetails>
                ))}
                {onThisDay.length > MONTH_CHIPS && (
                  <button type="button" onClick={() => onOpenDay(day)} className="px-1 text-left text-[0.7rem] text-muted-foreground hover:text-foreground">
                    {onThisDay.length - MONTH_CHIPS} more
                  </button>
                )}
              </div>
            )
          })}
        </div>
      ))}
    </div>
  )
}
