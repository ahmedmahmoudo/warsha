import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useSearch } from '@tanstack/react-router'
import { Check, ChevronLeft, ChevronRight, ClipboardCopy, Info, RefreshCw } from 'lucide-react'
import { useState } from 'react'
import type { ActivityPr, ActivityResponse, ActivityView } from '../../shared/activity'
import { Button } from '@/components/ui/button'
import { ApiError, fetchActivity } from '../api'
import { rangeLabel, step, todayIn } from '../components/activity/calendar'
import { AttentionSummary, DayView, MonthView, WeekView } from '../components/activity/views'
import { timeAgo } from '../format'

const REFRESH_MS = 60_000
const COPIED_MS = 2000
const SYDNEY = 'Australia/Sydney'
const ZONE_STORAGE_KEY = 'workbench-activity-zone'
const VIEWS: { value: ActivityView; label: string }[] = [
  { value: 'day', label: 'Day' },
  { value: 'week', label: 'Week' },
  { value: 'month', label: 'Month' },
]

type ZoneChoice = 'sydney' | 'local'

const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone

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

/** "Australia/Sydney" → "Sydney". */
function city(zone: string): string {
  return zone.split('/').at(-1)!.replaceAll('_', ' ')
}

/** A paste-ready summary for a standup or update, covering whatever range is shown. */
function summary(data: ActivityResponse): string {
  // "fix(MX-2475): rename…" becomes "MX-2475: rename…": the ticket says what the prefix did.
  const line = (pr: ActivityPr) =>
    pr.ticketKeys[0]
      ? `${pr.ticketKeys[0]}: ${pr.title.replace(/^\w+(\([^)]*\))?!?:\s*/, '')} (#${pr.number})`
      : `${pr.title} (#${pr.number})`
  const inReview = data.opened.filter((pr) => pr.state === 'OPEN')
  const label = rangeLabel(data.range.view, data.range.start, data.range.end)
  return [
    `*${data.range.view === 'week' ? `Week of ${label}` : label}*`,
    data.shipped.length && ['*Shipped*', ...data.shipped.map((pr) => `• ${line(pr)}`)].join('\n'),
    inReview.length && ['*In review*', ...inReview.map((pr) => `• ${line(pr)}`)].join('\n'),
    data.reviewsGiven.length &&
      [
        '*Reviewed*',
        ...data.reviewsGiven.map(
          (given) => `• ${given.pr.title} (#${given.pr.number}${given.pr.author ? ` by ${given.pr.author.name}` : ''})`,
        ),
      ].join('\n'),
    data.totals.ticketsCompleted > 0 &&
      `${data.totals.ticketsCompleted} ticket${data.totals.ticketsCompleted === 1 ? '' : 's'} completed.`,
  ]
    .filter(Boolean)
    .join('\n\n')
}

function CopySummaryButton({ data }: { data: ActivityResponse }) {
  const [result, setResult] = useState<'copied' | 'failed' | null>(null)
  return (
    <Button
      size="sm"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(summary(data))
          setResult('copied')
        } catch {
          setResult('failed')
        }
        setTimeout(() => setResult(null), COPIED_MS)
      }}
    >
      {result === 'copied' ? <Check /> : <ClipboardCopy />}
      {result === 'copied' ? 'Copied' : result === 'failed' ? 'Copy failed' : 'Copy summary'}
    </Button>
  )
}

function Segmented<T extends string>({
  options,
  value,
  onChange,
  label,
}: {
  options: { value: T; label: string; title?: string }[]
  value: T
  onChange: (value: T) => void
  label: string
}) {
  return (
    <div role="radiogroup" aria-label={label} className="flex items-center gap-0.5 rounded-lg border border-border bg-card p-0.5 text-sm">
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={option.value === value}
          title={option.title}
          onClick={() => onChange(option.value)}
          className={`rounded-md px-2.5 py-1 ${option.value === value ? 'bg-muted font-medium' : 'text-muted-foreground hover:text-foreground'}`}
        >
          {option.label}
        </button>
      ))}
    </div>
  )
}

/** One quiet line of totals rather than a row of cards. */
function TotalsLine({ data }: { data: ActivityResponse }) {
  const { totals } = data
  const parts = [
    `${totals.prsMerged} merged`,
    `${totals.prsOpened} opened`,
    `${totals.prsReviewed} reviewed`,
    `${totals.ticketsCompleted} tickets done`,
    totals.pushes !== null && `${totals.pushes} pushes`,
  ].filter(Boolean)
  return <p className="text-sm text-muted-foreground">{parts.join(' · ')}</p>
}

export function ActivityPage() {
  const search = useSearch({ from: '/activity' })
  const navigate = useNavigate()
  const view = search.view ?? 'week'
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const [zoneChoice, setZoneChoice] = useState<ZoneChoice>(readZone)
  const timeZone = zoneChoice === 'local' ? localZone : SYDNEY
  const today = todayIn(timeZone)
  const date = search.date ?? today
  const queryKey = ['activity', timeZone, view, date]

  const query = useQuery({
    queryKey,
    queryFn: () => fetchActivity({ view, date, timeZone }),
    refetchInterval: REFRESH_MS,
    // Keep the last range on screen (dimmed) while the next one loads.
    placeholderData: (previous) => previous,
  })

  async function refresh() {
    setRefreshing(true)
    try {
      await queryClient.fetchQuery({ queryKey, queryFn: () => fetchActivity({ view, date, timeZone }, true), staleTime: 0 })
    } finally {
      setRefreshing(false)
    }
  }

  const data = query.data
  const next = step(view, date, 1)
  // Moving forward only makes sense once the next range has started.
  const canGoForward = view === 'month' ? next.slice(0, 7) <= today.slice(0, 7) : view === 'week' ? next <= today : next <= today

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h1 className="mr-1 text-lg font-semibold">Activity</h1>
        <Segmented
          label="View"
          options={VIEWS}
          value={view}
          onChange={(value) => void navigate({ to: '/activity', search: { view: value, date: search.date } })}
        />
        <div className="flex items-center gap-1">
          <Link
            to="/activity"
            search={{ view, date: step(view, date, -1) }}
            aria-label="Earlier"
            className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
          >
            <ChevronLeft className="size-4" />
          </Link>
          <span className="min-w-40 text-center text-sm font-medium tabular-nums">
            {data ? rangeLabel(data.range.view, data.range.start, data.range.end) : '…'}
          </span>
          {canGoForward ? (
            <Link
              to="/activity"
              search={{ view, date: next }}
              aria-label="Later"
              className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              <ChevronRight className="size-4" />
            </Link>
          ) : (
            <span className="p-1 text-faint" aria-hidden>
              <ChevronRight className="size-4" />
            </span>
          )}
          {search.date && data && !data.range.isCurrent && (
            <Link to="/activity" search={{ view }} className="ml-1 rounded-md border border-border px-2 py-0.5 text-xs hover:bg-accent">
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
            title={data ? `Updated ${timeAgo(data.fetchedAt)}. Refresh` : 'Refresh'}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-60"
          >
            <RefreshCw className={`size-4 ${refreshing || query.isFetching ? 'animate-spin' : ''}`} />
          </button>
          {data && <CopySummaryButton data={data} />}
        </div>
      </div>

      {query.error && (
        <div className="rounded-lg border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad">
          {query.error instanceof ApiError && query.error.setup ? `Setup needed: ${query.error.message}` : query.error.message}
        </div>
      )}
      {query.isPending && <p className="text-sm text-muted-foreground">Gathering activity… the first load takes a few seconds.</p>}

      {data && (
        <div className={`flex flex-col gap-3 transition-opacity ${query.isPlaceholderData ? 'opacity-50' : ''}`}>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex flex-wrap items-center gap-3">
              <TotalsLine data={data} />
              <AttentionSummary data={data} />
            </div>
            {data.dayByDay !== 'complete' && (
              <span className="flex items-center gap-1.5 text-xs text-faint" title={data.warnings.join('\n')}>
                <Info className="size-3.5" />
                Pushes and replies only reach back a few weeks
              </span>
            )}
          </div>
          {data.warnings
            .filter((warning) => !warning.startsWith('Pushes and replies') && !warning.startsWith('No pushes or replies'))
            .map((warning) => (
              <p key={warning} className="flex items-center gap-1.5 text-xs text-warn">
                <Info className="size-3.5" />
                {warning}
              </p>
            ))}
          {data.range.view === 'month' && <MonthView data={data} />}
          {data.range.view === 'week' && <WeekView data={data} />}
          {data.range.view === 'day' && <DayView data={data} />}
        </div>
      )}
    </div>
  )
}
