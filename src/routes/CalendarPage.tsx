import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { ChevronLeft, ChevronRight, RefreshCw } from 'lucide-react'
import { useState } from 'react'
import type { ActivityView } from '../../shared/activity'
import { fetchCalendarRange } from '../api'
import { addDays, addMonths, monthGrid, mondayOf, rangeLabel, step, todayIn } from '../components/activity/calendar'
import { MonthGrid, TimeGrid } from '../components/calendar/grid'
import { city, localZone } from '../components/calendar/time'
import { Segmented } from '../components/Segmented'

const REFRESH_MS = 60_000
const SYDNEY = 'Australia/Sydney'
const ZONE_STORAGE_KEY = 'warsha-calendar-zone'
const VIEWS: { value: ActivityView; label: string }[] = [
  { value: 'day', label: 'Day' },
  { value: 'week', label: 'Week' },
  { value: 'month', label: 'Month' },
]

type ZoneChoice = 'sydney' | 'local'

function readZone(): ZoneChoice {
  try {
    return localStorage.getItem(ZONE_STORAGE_KEY) === 'local' ? 'local' : 'sydney'
  } catch {
    return 'sydney'
  }
}

function writeZone(choice: ZoneChoice) {
  try {
    localStorage.setItem(ZONE_STORAGE_KEY, choice)
  } catch {
    // Storage blocked: the choice still applies until the page reloads.
  }
}

/** The days a view shows around `date`, and the month bounds for the month view. */
function rangeOf(view: ActivityView, date: string): { days: string[]; first: string; last: string } {
  if (view === 'day') return { days: [date], first: date, last: date }
  if (view === 'week') {
    const monday = mondayOf(date)
    const days = Array.from({ length: 7 }, (_, i) => addDays(monday, i))
    return { days, first: monday, last: days[6]! }
  }
  const first = `${date.slice(0, 7)}-01`
  const last = addDays(addMonths(first, 1), -1)
  return { days: monthGrid(first, last).flat(), first, last }
}

export function CalendarPage() {
  const search = useSearch({ from: '/calendar' })
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const view = search.view ?? 'week'
  const [zoneChoice, setZoneChoice] = useState<ZoneChoice>(readZone)
  const [refreshing, setRefreshing] = useState(false)
  const timeZone = zoneChoice === 'local' ? localZone : SYDNEY
  const today = todayIn(timeZone)
  const date = search.date ?? today
  const { days, first, last } = rangeOf(view, date)

  // A day either side covers every zone's idea of where the shown days begin and end.
  const timeMin = `${addDays(days[0]!, -1)}T00:00:00Z`
  const timeMax = `${addDays(days.at(-1)!, 2)}T00:00:00Z`
  const queryKey = ['calendar', timeMin, timeMax]
  const query = useQuery({
    queryKey,
    queryFn: () => fetchCalendarRange(timeMin, timeMax),
    refetchInterval: REFRESH_MS,
    placeholderData: keepPreviousData,
  })
  const data = query.data

  async function refresh() {
    setRefreshing(true)
    try {
      await queryClient.fetchQuery({ queryKey, queryFn: () => fetchCalendarRange(timeMin, timeMax, true), staleTime: 0 })
      await queryClient.invalidateQueries({ queryKey: ['meetings-today'] })
    } finally {
      setRefreshing(false)
    }
  }

  const homeZone = data?.timeZone ?? SYDNEY
  const meetings = data?.meetings ?? []

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-lg font-semibold">Calendar</h1>
        <Segmented
          label="View"
          options={VIEWS}
          value={view}
          onChange={(value) => void navigate({ to: '/calendar', search: { view: value, date: search.date } })}
        />
        <div className="flex items-center gap-1">
          <Link
            to="/calendar"
            search={{ view, date: step(view, date, -1) }}
            aria-label="Earlier"
            className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
          >
            <ChevronLeft className="size-4" />
          </Link>
          <span className="min-w-40 text-center text-sm font-medium tabular-nums">{rangeLabel(view, first, last)}</span>
          <Link
            to="/calendar"
            search={{ view, date: step(view, date, 1) }}
            aria-label="Later"
            className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
          >
            <ChevronRight className="size-4" />
          </Link>
          {search.date && search.date !== today && (
            <Link to="/calendar" search={{ view }} className="ml-1 rounded-md border border-border px-2 py-0.5 text-xs hover:bg-accent">
              Today
            </Link>
          )}
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Segmented
            label="Time zone"
            options={[
              { value: 'sydney', label: 'Sydney', title: SYDNEY },
              { value: 'local', label: localZone === SYDNEY ? 'Local' : `Local · ${city(localZone)}`, title: localZone },
            ]}
            value={zoneChoice}
            onChange={(choice) => {
              writeZone(choice)
              setZoneChoice(choice)
            }}
          />
          <button
            type="button"
            onClick={refresh}
            disabled={refreshing}
            aria-label="Refresh"
            title="Check Google for changes now"
            className="rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-60"
          >
            <RefreshCw className={`size-4 ${refreshing || query.isFetching ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {query.error && <div className="rounded-lg border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad">{query.error.message}</div>}
      {data && data.connection !== 'connected' && (
        <p className="text-sm text-muted-foreground">
          <Link to="/settings" search={{}} className="underline">
            Connect Google Calendar
          </Link>{' '}
          to see your meetings here.
        </p>
      )}
      {data?.error && <p className="text-xs text-warn">Google: {data.error}</p>}

      <div className={`transition-opacity ${query.isPlaceholderData || query.isPending ? 'opacity-50' : ''}`}>
        {view === 'month' ? (
          <MonthGrid
            monthStart={first}
            monthEnd={last}
            meetings={meetings}
            timeZone={timeZone}
            homeZone={homeZone}
            today={today}
            onOpenDay={(day) => void navigate({ to: '/calendar', search: { view: 'day', date: day } })}
          />
        ) : (
          <TimeGrid days={days} meetings={meetings} timeZone={timeZone} homeZone={homeZone} today={today} />
        )}
      </div>
    </div>
  )
}
