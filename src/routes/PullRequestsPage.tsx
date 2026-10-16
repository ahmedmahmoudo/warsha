import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useSearch } from '@tanstack/react-router'
import { useState } from 'react'
import type { Pr, PrScope, WaitingOn } from '../../shared/prs'
import { Button } from '@/components/ui/button'
import { ApiError, fetchPrs } from '../api'
import { PrRow } from '../components/PrRow'
import { timeAgo } from '../format'

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

function PrList({ prs, viewer, all }: { prs: Pr[]; viewer: string; all: Pr[] }) {
  return (
    <ul className="overflow-hidden rounded-lg border border-border bg-card">
      {prs.map((pr) => (
        <PrRow key={pr.url} pr={pr} viewer={viewer} stackParent={all.find((p) => p.number === pr.stackedOn)} />
      ))}
    </ul>
  )
}

export function PullRequestsPage() {
  const { scope } = useSearch({ from: '/prs' })
  const queryClient = useQueryClient()
  const [mismatchesOnly, setMismatchesOnly] = useState(false)
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
  const visible = (prs: Pr[]) => (mismatchesOnly ? prs.filter((pr) => pr.mismatches.length > 0) : prs)
  const open = data ? visible(data.open) : []
  const merged = data ? visible(data.recentlyMerged) : []
  const mismatchCount = data ? [...data.open, ...data.recentlyMerged].filter((pr) => pr.mismatches.length).length : 0

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
          {data && <span>Updated {timeAgo(data.fetchedAt)}</span>}
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
              const count = data.open.filter((pr) => pr.waitingOn === waitingOn).length
              return (
                <a
                  key={waitingOn}
                  href={`#${waitingOn}`}
                  className="flex min-w-32 flex-col rounded-lg border border-border bg-card px-3 py-2 hover:bg-accent"
                >
                  <span className="text-2xl font-semibold tabular-nums">{count}</span>
                  <span className="text-xs text-muted-foreground">{sectionTitle(waitingOn, scope)}</span>
                </a>
              )
            })}
            <button
              type="button"
              onClick={() => setMismatchesOnly((on) => !on)}
              aria-pressed={mismatchesOnly}
              className={`flex min-w-32 flex-col rounded-lg border px-3 py-2 text-left ${
                mismatchesOnly ? 'border-warn bg-warn-soft' : 'border-border bg-card hover:bg-accent'
              }`}
            >
              <span className={`text-2xl font-semibold tabular-nums ${mismatchCount ? 'text-warn' : ''}`}>{mismatchCount}</span>
              <span className="text-xs text-muted-foreground">{mismatchesOnly ? 'Showing mismatches' : 'Ticket mismatches'}</span>
            </button>
          </div>

          {SECTION_ORDER.map((waitingOn) => {
            const prs = open.filter((pr) => pr.waitingOn === waitingOn)
            if (prs.length === 0) return null
            return (
              <section key={waitingOn} id={waitingOn} className="scroll-mt-16">
                <h2 className="mb-2 text-sm font-semibold">
                  {sectionTitle(waitingOn, scope)} <span className="font-normal text-faint">{prs.length}</span>
                </h2>
                <PrList prs={prs} viewer={data.viewer} all={data.open} />
              </section>
            )
          })}

          {open.length === 0 && (
            <p className="text-sm text-muted-foreground">{mismatchesOnly ? 'No open PRs with mismatches.' : 'No open pull requests.'}</p>
          )}

          {merged.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-semibold">
                Merged in the last 7 days <span className="font-normal text-faint">{merged.length}</span>
              </h2>
              <PrList prs={merged} viewer={data.viewer} all={data.recentlyMerged} />
            </section>
          )}
        </>
      )}
    </div>
  )
}
