import { Link } from '@tanstack/react-router'
import {
  Clock,
  ExternalLink,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  Info,
  MessageSquare,
  TriangleAlert,
} from 'lucide-react'
import type { ActivityDay, ActivityResponse, DayGroup, LinkedPr, TicketAge, TicketCard } from '../../../shared/activity'
import { Avatar } from '../Avatar'
import { TicketChip, TONE_CLASSES } from '../PrRow'
import { ItemControls, NoteLine } from '../today/rows'
import { useParking } from '../../store'
import { ticketRef } from '../../../shared/store'
import { dateAt, dayHeading, dayOfMonth, monthGrid, todayIn, weekdayShort, addDays } from './calendar'
import { dayCounts, Entry, KindIcons } from './entries'

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const MONTH_CELL_GROUPS = 3
const WEEK_COLUMN_GROUPS = 6

function byDate(data: ActivityResponse): Map<string, ActivityDay> {
  return new Map(data.days.map((day) => [day.date, day]))
}

type Flag = { level: 'warn' | 'alert'; message: string }

const FLAG_RANK = { alert: 0, warn: 1 } as const

/**
 * Where a stuck ticket is flagged in Week and Month: only on the last day it shows up in the range,
 * so one ticket stuck for weeks doesn't paint every day it was touched.
 */
function flagsByDay(data: ActivityResponse, isParked: (key: string) => boolean): Map<string, Map<string, Flag>> {
  const lastDay = new Map<string, string>()
  for (const day of data.days) for (const group of day.groups) if (group.ticket) lastDay.set(group.ticket.key, day.date)
  const flags = new Map<string, Map<string, Flag>>()
  for (const [key, date] of lastDay) {
    const age = data.ticketAges[key]
    if (!age || age.level === 'ok' || !age.message || isParked(key)) continue
    if (!flags.has(date)) flags.set(date, new Map())
    flags.get(date)!.set(key, { level: age.level, message: age.message })
  }
  return flags
}

/** Flagged tickets first, worst first, so they survive a cell's "+N more". */
function flaggedFirst(groups: DayGroup[], flags: Map<string, Flag> | undefined): DayGroup[] {
  const rank = (group: DayGroup) => {
    const flag = group.ticket && flags?.get(group.ticket.key)
    return flag ? FLAG_RANK[flag.level] : 2
  }
  return [...groups].sort((a, b) => rank(a) - rank(b))
}

const FLAG_PILL = { warn: 'bg-warn-soft text-warn', alert: 'bg-bad-soft text-bad' } as const
const FLAG_CARD = { warn: 'border-warn/60 bg-warn-soft/40', alert: 'border-bad/60 bg-bad-soft/40' } as const

function FlagIcon({ level, className }: { level: Flag['level']; className?: string }) {
  return level === 'alert' ? <TriangleAlert className={className} /> : <Clock className={className} />
}

/** "1 stuck · 3 slow", naming the tickets on hover; nothing when all is well. */
export function AttentionSummary({ data }: { data: ActivityResponse }) {
  const parking = useParking()
  const ages = Object.entries(data.ticketAges).filter(([key]) => !parking.forTicket(key))
  const stuck = ages.filter(([, age]) => age.level === 'alert')
  const slow = ages.filter(([, age]) => age.level === 'warn')
  if (stuck.length === 0 && slow.length === 0) return null
  const describe = (list: typeof ages) => list.map(([key, age]) => `${key}: ${age.message}`).join('\n')
  return (
    <span className="flex items-center gap-2 text-xs">
      {stuck.length > 0 && (
        <span className="flex items-center gap-1 rounded-md bg-bad-soft px-1.5 py-0.5 font-medium text-bad" title={describe(stuck)}>
          <TriangleAlert className="size-3.5" />
          {stuck.length} stuck
        </span>
      )}
      {slow.length > 0 && (
        <span className="flex items-center gap-1 rounded-md bg-warn-soft px-1.5 py-0.5 font-medium text-warn" title={describe(slow)}>
          <Clock className="size-3.5" />
          {slow.length} getting slow
        </span>
      )}
    </span>
  )
}

/** A ticket's key with its state colour, small enough for a calendar cell; tinted when stuck. */
function GroupPill({ group, flag }: { group: DayGroup; flag: Flag | undefined }) {
  const label = group.ticket?.key ?? (group.key.includes('#') ? `#${group.key.split('#')[1]}` : 'branch')
  return (
    <span
      className={`flex min-w-0 items-center gap-1.5 rounded px-1 py-0.5 text-[0.7rem] ${flag ? FLAG_PILL[flag.level] : 'hover:bg-accent'}`}
      title={flag ? `${group.title}\n${flag.message}` : group.title}
    >
      {flag ? (
        <FlagIcon level={flag.level} className="size-3 shrink-0" />
      ) : (
        <span className="size-1.5 shrink-0 rounded-full" style={{ background: group.ticket?.stateColor ?? 'var(--faint)' }} />
      )}
      <span className="truncate font-mono">{label}</span>
      <span className="ml-auto shrink-0">
        <KindIcons kinds={group.entries.map((entry) => entry.kind)} />
      </span>
    </span>
  )
}

function DayLink({ date, className, children }: { date: string; className?: string; children: React.ReactNode }) {
  return (
    <Link to="/activity" search={(prev) => ({ ...prev, view: 'day', date })} className={className}>
      {children}
    </Link>
  )
}

/** A month at a glance: each day shows the tickets touched and what shipped, nothing more. */
export function MonthView({ data }: { data: ActivityResponse }) {
  const days = byDate(data)
  const parking = useParking()
  const flags = flagsByDay(data, (key) => Boolean(parking.forTicket(key)))
  const today = todayIn(data.range.timeZone)
  const month = data.range.start.slice(0, 7)

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card">
      <div className="grid grid-cols-7 border-b border-border bg-muted/40 text-xs text-muted-foreground">
        {WEEKDAYS.map((weekday) => (
          <div key={weekday} className="px-2 py-1.5">
            {weekday}
          </div>
        ))}
      </div>
      {monthGrid(data.range.start, data.range.end).map((week) => (
        <div key={week[0]} className="grid grid-cols-7 border-b border-border last:border-b-0">
          {week.map((date) => {
            const inMonth = date.startsWith(month)
            const future = date > today
            const day = inMonth ? days.get(date) : undefined
            const counts = day ? dayCounts(day) : null
            const cellClass = `flex min-h-28 min-w-0 flex-col gap-1 border-r border-border p-1.5 last:border-r-0 ${
              inMonth && !future ? 'hover:bg-accent/40' : 'bg-muted/30'
            }`
            const body = (
              <>
                <div className="flex items-center justify-between">
                  <span
                    className={`flex size-6 items-center justify-center rounded-full text-xs ${
                      date === today ? 'bg-foreground font-semibold text-background' : inMonth ? '' : 'text-faint'
                    }`}
                  >
                    {dayOfMonth.format(dateAt(date))}
                  </span>
                  {counts && (
                    <span className="flex items-center gap-1.5 text-[0.65rem] text-muted-foreground">
                      {counts.merged > 0 && (
                        <span className="flex items-center gap-0.5 text-good" title={`${counts.merged} merged`}>
                          <GitMerge className="size-3" />
                          {counts.merged}
                        </span>
                      )}
                      {counts.opened > 0 && (
                        <span className="flex items-center gap-0.5 text-info" title={`${counts.opened} opened`}>
                          <GitPullRequest className="size-3" />
                          {counts.opened}
                        </span>
                      )}
                      {counts.reviews > 0 && (
                        <span className="flex items-center gap-0.5" title={`${counts.reviews} reviewed`}>
                          <MessageSquare className="size-3" />
                          {counts.reviews}
                        </span>
                      )}
                    </span>
                  )}
                </div>
                {day && (
                  <div className="flex min-w-0 flex-col">
                    {flaggedFirst(day.groups, flags.get(date))
                      .slice(0, MONTH_CELL_GROUPS)
                      .map((group) => (
                        <GroupPill key={group.key} group={group} flag={group.ticket ? flags.get(date)?.get(group.ticket.key) : undefined} />
                      ))}
                    {day.groups.length > MONTH_CELL_GROUPS && (
                      <span className="px-1 text-[0.65rem] text-faint">+{day.groups.length - MONTH_CELL_GROUPS} more</span>
                    )}
                  </div>
                )}
              </>
            )
            return inMonth && !future ? (
              <DayLink key={date} date={date} className={cellClass}>
                {body}
              </DayLink>
            ) : (
              <div key={date} className={cellClass}>
                {body}
              </div>
            )
          })}
        </div>
      ))}
    </div>
  )
}

/** Seven columns, one card per ticket a day; the day's heading opens its detail. */
export function WeekView({ data }: { data: ActivityResponse }) {
  const days = byDate(data)
  const parking = useParking()
  const flags = flagsByDay(data, (key) => Boolean(parking.forTicket(key)))
  const today = todayIn(data.range.timeZone)
  const dates = Array.from({ length: 7 }, (_, i) => addDays(data.range.start, i))

  return (
    <div className="grid grid-cols-1 overflow-hidden rounded-lg border border-border bg-card sm:grid-cols-7">
      {dates.map((date) => {
        const day = days.get(date)
        const future = date > today
        return (
          <div key={date} className="flex min-h-64 min-w-0 flex-col border-b border-border sm:border-r sm:border-b-0 sm:last:border-r-0">
            {future ? (
              <div className="border-b border-border bg-muted/30 px-2 py-1.5 text-xs text-faint">
                {weekdayShort.format(dateAt(date))} {dayOfMonth.format(dateAt(date))}
              </div>
            ) : (
              <DayLink
                date={date}
                className={`flex items-center justify-between border-b border-border px-2 py-1.5 text-xs hover:bg-accent/50 ${
                  date === today ? 'bg-muted font-semibold' : 'text-muted-foreground'
                }`}
              >
                <span>
                  {weekdayShort.format(dateAt(date))} {dayOfMonth.format(dateAt(date))}
                </span>
                {day && <span className="text-faint">{day.groups.length}</span>}
              </DayLink>
            )}
            <div className={`flex flex-1 flex-col gap-1.5 p-1.5 ${future ? 'bg-muted/30' : ''}`}>
              {day &&
                flaggedFirst(day.groups, flags.get(date))
                  .slice(0, WEEK_COLUMN_GROUPS)
                  .map((group) => {
                    const flag = group.ticket ? flags.get(date)?.get(group.ticket.key) : undefined
                    return (
                      <DayLink
                        key={group.key}
                        date={date}
                        className={`flex flex-col gap-1 rounded-md border px-2 py-1.5 hover:bg-accent/50 ${flag ? FLAG_CARD[flag.level] : 'border-border'}`}
                      >
                        <span className="flex items-center justify-between gap-1">
                          <span className="flex min-w-0 items-center gap-1.5 text-[0.7rem]">
                            <span className="size-1.5 shrink-0 rounded-full" style={{ background: group.ticket?.stateColor ?? 'var(--faint)' }} />
                            <span className="truncate font-mono">{group.ticket?.key ?? 'PR'}</span>
                          </span>
                          <KindIcons kinds={group.entries.map((entry) => entry.kind)} />
                        </span>
                        <span className="line-clamp-2 text-xs leading-snug text-muted-foreground">{group.title}</span>
                        {flag && (
                          <span
                            className={`flex items-center gap-1 text-[0.65rem] font-medium ${flag.level === 'alert' ? 'text-bad' : 'text-warn'}`}
                            title={flag.message}
                          >
                            <FlagIcon level={flag.level} className="size-3 shrink-0" />
                            <span className="truncate">{data.ticketAges[group.ticket!.key]!.state} · {data.ticketAges[group.ticket!.key]!.workingDays}d</span>
                          </span>
                        )}
                      </DayLink>
                    )
                  })}
              {day && day.groups.length > WEEK_COLUMN_GROUPS && (
                <DayLink date={date} className="px-1 text-[0.7rem] text-info hover:underline">
                  +{day.groups.length - WEEK_COLUMN_GROUPS} more
                </DayLink>
              )}
              {day && day.reviews.length > 0 && (
                <DayLink date={date} className="flex items-center gap-1.5 rounded-md bg-muted/60 px-2 py-1 text-[0.7rem] text-muted-foreground">
                  <MessageSquare className="size-3" />
                  {day.reviews.length} review{day.reviews.length === 1 ? '' : 's'}
                </DayLink>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}

const AGE_STYLES = {
  warn: { card: 'border-warn/60 ring-1 ring-warn/25', strip: 'bg-warn-soft text-warn' },
  alert: { card: 'border-bad/60 ring-1 ring-bad/25', strip: 'bg-bad-soft text-bad' },
} as const

function prIcon(pr: LinkedPr): { icon: typeof GitPullRequest; className: string; label: string } {
  if (pr.state === 'MERGED') return { icon: GitMerge, className: 'text-good', label: 'merged' }
  if (pr.state === 'CLOSED') return { icon: GitPullRequestClosed, className: 'text-bad', label: 'closed' }
  if (pr.isDraft) return { icon: GitPullRequestDraft, className: 'text-muted-foreground', label: 'draft' }
  return { icon: GitPullRequest, className: 'text-info', label: 'open' }
}

function LinkedPrRow({ pr }: { pr: LinkedPr }) {
  const { icon: Icon, className, label } = prIcon(pr)
  const [owner = '', repo = ''] = pr.repo.split('/')
  return (
    <li className="flex min-w-0 items-center gap-2 text-xs">
      <Icon className={`size-3.5 shrink-0 ${className}`} aria-label={label} />
      <Link
        to="/prs/$owner/$repo/$number"
        params={{ owner, repo, number: String(pr.number) }}
        search={{ scope: 'mine' }}
        className="min-w-0 truncate hover:underline"
        title={pr.title}
      >
        <span className="text-faint">#{pr.number}</span> {pr.title}
      </Link>
      <span className="ml-auto flex shrink-0 items-center gap-1.5">
        {pr.status ? (
          <span className={`rounded px-1.5 py-0.5 text-[0.65rem] font-medium ${TONE_CLASSES[pr.status.tone]}`}>{pr.status.label}</span>
        ) : (
          <span className="text-[0.65rem] text-faint">{label}</span>
        )}
        <a href={pr.url} target="_blank" rel="noreferrer" aria-label="Open on GitHub" className="text-faint hover:text-foreground">
          <ExternalLink className="size-3" />
        </a>
      </span>
    </li>
  )
}

/** One ticket's day: its status (flagged when it has sat too long), its PRs, and what happened. */
function TicketCardView({ group, card, age }: { group: DayGroup; card: TicketCard | undefined; age: TicketAge | undefined }) {
  const parked = useParking().forTicket(group.ticket?.key ?? '')
  const flagged = age && age.level !== 'ok' && !parked ? AGE_STYLES[age.level] : null
  return (
    <article className={`flex min-w-0 flex-col overflow-hidden rounded-lg border bg-card ${flagged ? flagged.card : 'border-border'}`}>
      {flagged && age?.message && (
        <p className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium ${flagged.strip}`}>
          {age.level === 'alert' ? <TriangleAlert className="size-3.5" /> : <Clock className="size-3.5" />}
          {age.message}
        </p>
      )}
      <div className="flex flex-col gap-2.5 p-3">
        <header className="flex min-w-0 flex-col gap-1.5">
          <div className="flex items-center gap-2">
            {group.ticket ? (
              <TicketChip ticket={group.ticket} />
            ) : (
              <span className="rounded-md border border-border px-1.5 py-0.5 font-mono text-xs text-muted-foreground">
                {group.key.includes('#') ? 'PR' : 'branch'}
              </span>
            )}
            {parked && (
              <span className="rounded bg-info-soft px-1.5 py-0.5 text-[0.65rem] text-info" title={parked.reason ?? undefined}>
                Parked
              </span>
            )}
            {age && (age.level === 'ok' || parked) && (
              <span className="text-[0.65rem] text-faint">
                {age.state} for {age.workingDays} working day{age.workingDays === 1 ? '' : 's'}
              </span>
            )}
          </div>
          <div className="flex items-start gap-1">
            <h3 className="line-clamp-2 min-w-0 flex-1 text-sm font-medium leading-snug" title={group.title}>
              {group.ticket ? (
                <a href={group.ticket.url} target="_blank" rel="noreferrer" className="hover:underline">
                  {group.title}
                </a>
              ) : (
                group.title
              )}
            </h3>
            {group.ticket && (
              <ItemControls
                refId={ticketRef(group.ticket.key)}
                title={`${group.ticket.key} ${group.title}`}
                url={group.ticket.url}
                prs={card?.prs.filter((pr) => pr.state === 'OPEN').map((pr) => ({ repo: pr.repo, number: pr.number }))}
              />
            )}
          </div>
          {group.ticket && <NoteLine refId={ticketRef(group.ticket.key)} />}
        </header>

        {group.ticket && (
          <section>
            <h4 className="mb-1 text-[0.65rem] font-medium tracking-wide text-faint uppercase">Pull requests</h4>
            {card && card.prs.length > 0 ? (
              <ul className="flex flex-col gap-1">
                {card.prs.map((pr) => (
                  <LinkedPrRow key={pr.url} pr={pr} />
                ))}
              </ul>
            ) : (
              <p className="text-xs text-faint">No PR yet</p>
            )}
          </section>
        )}

        <section>
          <h4 className="mb-1 text-[0.65rem] font-medium tracking-wide text-faint uppercase">Activity</h4>
          <div className="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
            {group.entries.map((entry) => (
              <Entry key={`${entry.kind}-${entry.text}`} entry={entry} />
            ))}
          </div>
        </section>
      </div>
    </article>
  )
}

/** Everything about one day: a card per ticket, flagged ones first, then reviews. */
export function DayView({ data }: { data: ActivityResponse }) {
  const day = data.days[0]
  const parking = useParking()
  const rank = (group: DayGroup) =>
    parking.forTicket(group.ticket?.key ?? '') ? 3 : { alert: 0, warn: 1, ok: 2 }[data.ticketAges[group.ticket?.key ?? '']?.level ?? 'ok']
  const groups = day ? [...day.groups].sort((a, b) => rank(a) - rank(b)) : []
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold">{dayHeading.format(dateAt(data.range.start))}</h2>
        {day && !day.detailed && (
          <p className="flex items-center gap-1.5 text-xs text-faint">
            <Info className="size-3.5" />
            This far back GitHub no longer has pushes and replies; PRs, reviews and ticket moves are shown.
          </p>
        )}
      </div>
      {!day && <p className="rounded-lg border border-border bg-card px-4 py-6 text-center text-sm text-faint">Nothing recorded on this day.</p>}
      {day && (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          {groups.map((group) => (
            <TicketCardView
              key={group.key}
              group={group}
              card={group.ticket ? data.ticketCards[group.ticket.key] : undefined}
              age={group.ticket ? data.ticketAges[group.ticket.key] : undefined}
            />
          ))}
        </div>
      )}
      {day && day.reviews.length > 0 && (
        <section className="rounded-lg border border-border bg-card px-4 py-3">
          <h3 className="mb-1.5 text-xs font-medium text-muted-foreground">Reviewed</h3>
          <ul className="flex flex-col gap-1 text-xs">
            {day.reviews.map((review) => (
              <li key={review.pr.url} className="flex min-w-0 items-center gap-2">
                <Entry entry={review} />
                <span className="truncate text-muted-foreground" title={review.pr.title}>
                  {review.pr.title}
                </span>
                {review.pr.author && <Avatar person={review.pr.author} className="size-4 shrink-0 ring-0" />}
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}
