import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useSearch } from '@tanstack/react-router'
import { RefreshCw } from 'lucide-react'
import { useState } from 'react'
import type { Pr, PrScope, WaitingOn } from '../../shared/prs'
import type { PrView } from '../router'
import { Button } from '@/components/ui/button'
import { ApiError, fetchPrs } from '../api'
import { PrRow } from '../components/PrRow'
import { timeAgo } from '../format'
import { useParking } from '../store'

/** The server refreshes in the background, so polling it is cheap. */
const REFRESH_MS = 30_000

const SCOPE_LABELS: Record<PrScope, string> = { mine: 'Mine', reviewing: 'Reviewing', team: 'Team' }

const SECTION_ORDER: WaitingOn[] = ['you', 'merge', 'ci', 'reviewer', 'draft']

function sectionTitle(waitingOn: WaitingOn, scope: PrScope): string {
  switch (waitingOn) {
    case 'you':
      return scope === 'mine' ? 'Needs you' : 'Waiting on author'
    case 'merge':
      return 'Ready to merge'
    case 'ci':
      return 'Waiting on CI'
    case 'reviewer':
      return 'Waiting on review'
    case 'draft':
      return 'Drafts'
  }
}

function PrList({ prs, viewer, all, scope }: { prs: Pr[]; viewer: string; all: Pr[]; scope: PrScope }) {
  return (
    <ul className="overflow-hidden rounded-lg border border-border bg-card">
      {prs.map((pr) => (
        <PrRow key={pr.url} pr={pr} viewer={viewer} scope={scope} stackParent={all.find((p) => p.number === pr.stackedOn)} />
      ))}
    </ul>
  )
}

export function PullRequestsPage() {
  const { scope, view } = useSearch({ from: '/prs' })
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)

  const query = useQuery({
    queryKey: ['prs', scope],
    queryFn: () => fetchPrs(scope),
    refetchInterval: REFRESH_MS,
  })

  async function refresh() {
    setRefreshing(true)
    try {
      await queryClient.fetchQuery({ queryKey: ['prs', scope], queryFn: () => fetchPrs(scope, true), staleTime: 0 })
    } finally {
      setRefreshing(false)
    }
  }

  const data = query.data
  const parking = useParking()
  // Parked PRs (or PRs of parked tickets) don't count in the cards; they're listed at the bottom.
  const parkedOpen = data ? data.open.filter((pr) => parking.forPr(pr)) : []
  const activeOpen = data ? data.open.filter((pr) => !parking.forPr(pr)) : []
  const mismatchesOnly = view === 'mismatches'
  const visible = (prs: Pr[]) => (mismatchesOnly ? prs.filter((pr) => pr.mismatches.length > 0) : prs)
  const open = visible(activeOpen)
  // A waiting-on card is about open PRs only, so merged ones show with no filter or with mismatches.
  const merged = data && (!view || mismatchesOnly) ? visible(data.recentlyMerged) : []
  const sections = SECTION_ORDER.filter((waitingOn) => !view || mismatchesOnly || view === waitingOn)
  const mismatchCount = data ? [...activeOpen, ...data.recentlyMerged].filter((pr) => pr.mismatches.length).length : 0
  /** Clicking the active card clears the filter. */
  const toggle = (next: PrView) => ({ scope, view: view === next ? undefined : next })
  const cardClass = (active: boolean) =>
    `flex min-w-32 flex-col rounded-lg border px-3 py-2 text-left ${
      active ? 'border-foreground/40 bg-muted' : 'border-border bg-card hover:bg-accent'
    }`

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-1 rounded-lg border border-border bg-card p-0.5 text-sm">
          {(Object.keys(SCOPE_LABELS) as PrScope[]).map((value) => (
            <Link
              key={value}
              to="/prs"
              search={{ scope: value }}
              className={`rounded-md px-3 py-1 ${value === scope ? 'bg-muted font-medium' : 'text-muted-foreground hover:text-foreground'}`}
            >
              {SCOPE_LABELS[value]}
            </Link>
          ))}
        </div>
        <div className="flex items-center gap-3 text-xs text-muted-foreground">
          {data &&
            (query.isFetching ? (
              <span className="flex items-center gap-1">
                <RefreshCw className="size-3 animate-spin" />
                Updating…
              </span>
            ) : (
              <span>Updated {timeAgo(data.fetchedAt)}</span>
            ))}
          <Button variant="outline" size="sm" onClick={refresh} disabled={refreshing}>
            {refreshing ? 'Refreshing…' : 'Refresh'}
          </Button>
        </div>
      </div>

      {query.error && (
        <div className="rounded-lg border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad">
          {query.error instanceof ApiError && query.error.setup ? (
            <>Setup needed: {query.error.message}. Copy <code>.env.example</code> to <code>.env.local</code> and restart.</>
          ) : (
            query.error.message
          )}
        </div>
      )}

      {query.isPending && <p className="text-sm text-muted-foreground">Loading pull requests…</p>}

      {data && (
        <>
          {data.warnings.map((warning) => (
            <div key={warning} className="rounded-lg bg-warn-soft px-4 py-2 text-sm text-warn">
              {warning}
            </div>
          ))}

          <div className="flex flex-wrap gap-2">
            {SECTION_ORDER.map((waitingOn) => {
              const count = activeOpen.filter((pr) => pr.waitingOn === waitingOn).length
              return (
                <Link
                  key={waitingOn}
                  to="/prs"
                  search={toggle(waitingOn)}
                  aria-pressed={view === waitingOn}
                  className={cardClass(view === waitingOn)}
                >
                  <span className={`text-2xl font-semibold tabular-nums ${count ? '' : 'text-faint'}`}>{count}</span>
                  <span className="text-xs text-muted-foreground">{sectionTitle(waitingOn, scope)}</span>
                </Link>
              )
            })}
            <Link to="/prs" search={toggle('mismatches')} aria-pressed={mismatchesOnly} className={cardClass(mismatchesOnly)}>
              <span className={`text-2xl font-semibold tabular-nums ${mismatchCount ? 'text-warn' : 'text-faint'}`}>
                {mismatchCount}
              </span>
              <span className="text-xs text-muted-foreground">Ticket mismatches</span>
            </Link>
          </div>

          {view && (
            <p className="-mt-2 text-xs text-muted-foreground">
              Showing {mismatchesOnly ? 'ticket mismatches' : sectionTitle(view, scope).toLowerCase()} only ·{' '}
              <Link to="/prs" search={{ scope }} className="text-info hover:underline">
                Show all
              </Link>
            </p>
          )}

          {sections.map((waitingOn) => {
            const prs = open.filter((pr) => pr.waitingOn === waitingOn)
            if (prs.length === 0) return null
            return (
              <section key={waitingOn}>
                <h2 className="mb-2 text-sm font-semibold">
                  {sectionTitle(waitingOn, scope)} <span className="font-normal text-faint">{prs.length}</span>
                </h2>
                <PrList prs={prs} viewer={data.viewer} all={data.open} scope={scope} />
              </section>
            )
          })}

          {open.filter((pr) => sections.includes(pr.waitingOn)).length === 0 && (
            <p className="text-sm text-muted-foreground">
              {mismatchesOnly
                ? 'No open PRs with mismatches.'
                : view
                  ? `Nothing in ${sectionTitle(view, scope).toLowerCase()}.`
                  : 'No open pull requests.'}
            </p>
          )}

          {parkedOpen.length > 0 && !view && (
            <details className="group">
              <summary className="mb-2 cursor-pointer text-sm font-semibold text-muted-foreground">
                Parked <span className="font-normal text-faint">{parkedOpen.length}</span>
              </summary>
              <PrList prs={parkedOpen} viewer={data.viewer} all={data.open} scope={scope} />
            </details>
          )}

          {merged.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-semibold">
                Merged in the last 7 days <span className="font-normal text-faint">{merged.length}</span>
              </h2>
              <PrList prs={merged} viewer={data.viewer} all={data.recentlyMerged} scope={scope} />
            </section>
          )}
        </>
      )}
    </div>
  )
}
