import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RefreshCw } from 'lucide-react'
import { useMemo, useState } from 'react'
import { ApiError, fetchMeetingsToday, fetchToday, markTodaySeen } from '../api'
import { todayIn } from '../components/activity/calendar'
import { MeetingChangesSection, MeetingsTodaySection } from '../components/today/meetings'
import {
  DeadlinesSection,
  FocusSection,
  ParkedSection,
  NeedsYouSection,
  NewForYouSection,
  TodosSection,
  UpNextSection,
  WaitingSection,
} from '../components/today/sections'
import { timeAgo } from '../format'
import { useParking } from '../store'
import { ticketRef } from '../../shared/store'
import type { TodayResponse } from '../../shared/today'

const REFRESH_MS = 60_000
/** Before you've ever marked Today as seen, "new" means the last few days. */
const FIRST_VISIT_WINDOW_MS = 3 * 86_400_000

const heading = new Intl.DateTimeFormat('en-AU', { weekday: 'long', day: 'numeric', month: 'long' })

function greeting(hour: number): string {
  return hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening'
}

export function TodayPage() {
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const query = useQuery({ queryKey: ['today'], queryFn: () => fetchToday(), refetchInterval: REFRESH_MS })
  // Meetings load on their own, so they show even while GitHub and Linear are slow or failing.
  const meetings = useQuery({ queryKey: ['meetings-today'], queryFn: () => fetchMeetingsToday(), refetchInterval: REFRESH_MS })
  const seen = useMutation({
    mutationFn: markTodaySeen,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['today'] }),
  })

  async function refresh() {
    setRefreshing(true)
    try {
      await Promise.all([
        queryClient.fetchQuery({ queryKey: ['today'], queryFn: () => fetchToday(true), staleTime: 0 }),
        queryClient.fetchQuery({ queryKey: ['meetings-today'], queryFn: () => fetchMeetingsToday(true), staleTime: 0 }),
      ])
    } finally {
      setRefreshing(false)
    }
  }

  const parking = useParking()
  // Parked tickets and PRs leave everything that asks for attention; they're listed under Parked.
  const data = useMemo((): TodayResponse | undefined => {
    const raw = query.data
    if (!raw) return raw
    const parkedTicket = (key: string) => parking.isParked(ticketRef(key))
    return {
      ...raw,
      needsYou: raw.needsYou.filter((item) => !parking.isParked(item.ref) && !(item.pr && parking.forPr(item.pr))),
      upNext: raw.upNext.filter((item) => !parkedTicket(item.ticket.key)),
      waiting: raw.waiting.filter((pr) => !parking.forPr(pr)),
    }
  }, [query.data, parking])
  // Fixed once per load, so "New" doesn't shift under you between refreshes.
  const [firstVisitSince] = useState(() => new Date(Date.now() - FIRST_VISIT_WINDOW_MS).toISOString())
  const since = data?.lastSeenAt ?? firstVisitSince
  const today = todayIn(data?.timeZone ?? 'Australia/Sydney')

  const counts = data && {
    fix: data.needsYou.filter((item) => item.tone === 'bad').length,
    address: data.needsYou.filter((item) => item.tone === 'warn').length,
    ready: data.needsYou.filter((item) => item.tone === 'good').length,
    fresh: data.inbox.filter((item) => item.at > since).length + data.reviewRequests.length,
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold">{greeting(new Date().getHours())}</h1>
          <p className="text-sm text-muted-foreground">
            {heading.format(new Date())}
            {counts && (
              <>
                {' · '}
                {[
                  counts.fix && `${counts.fix} to fix`,
                  counts.address && `${counts.address} to address`,
                  counts.ready && `${counts.ready} ready to merge`,
                  counts.fresh && `${counts.fresh} new`,
                ]
                  .filter(Boolean)
                  .join(' · ') || 'nothing urgent'}
              </>
            )}
          </p>
        </div>
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
      </div>

      {query.error && (
        <div className="rounded-lg border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad">
          {query.error instanceof ApiError && query.error.setup ? `Setup needed: ${query.error.message}` : query.error.message}
        </div>
      )}
      {query.isPending && <p className="text-sm text-muted-foreground">Gathering your day… the first load takes a few seconds.</p>}
      {data?.warnings.map((warning) => (
        <p key={warning} className="text-xs text-warn">
          {warning}
        </p>
      ))}

      <div className="grid grid-cols-1 items-start gap-5 lg:grid-cols-[minmax(0,1fr)_22rem]">
        <div className="flex min-w-0 flex-col gap-5">
          {meetings.data && <MeetingChangesSection data={meetings.data} />}
          <FocusSection data={data} />
          {data && (
            <>
              <NeedsYouSection data={data} />
              <UpNextSection data={data} since={since} />
            </>
          )}
        </div>
        <aside className="flex min-w-0 flex-col gap-5">
          <MeetingsTodaySection data={meetings.data} error={meetings.error} />
          {data && <NewForYouSection data={data} since={since} onSeen={() => seen.mutate()} marking={seen.isPending} />}
          <TodosSection today={today} />
          <ParkedSection />
          {data && (
            <>
              <DeadlinesSection data={data} />
              <WaitingSection data={data} />
            </>
          )}
        </aside>
      </div>
    </div>
  )
}
