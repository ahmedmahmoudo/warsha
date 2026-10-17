import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useParams, useSearch } from '@tanstack/react-router'
import {
  ArrowLeft,
  Check,
  CircleAlert,
  CircleCheck,
  CircleDashed,
  CircleDot,
  CircleMinus,
  CircleX,
  ChevronDown,
  ExternalLink,
  FileCode,
  GitCommitHorizontal,
  GitMerge,
  GitPullRequest,
  Info,
  ListPlus,
  MessageSquare,
  RefreshCw,
  UserPlus,
  type LucideIcon,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type {
  ActivityItem,
  ActivityKind,
  ChangeRequest,
  CheckItem,
  CheckState,
  MergeBlocker,
  PrDetail,
  PrState,
  ReviewThread,
} from '../../shared/prDetail'
import { Button } from '@/components/ui/button'
import { ApiError, fetchPrChecks, fetchPrDetail } from '../api'
import { Avatar } from '../components/Avatar'
import { Panel } from '../components/Panel'
import { PrActionsPanel } from '../components/PrActionsPanel'
import { ItemControls, NoteLine } from '../components/today/rows'
import { prRef, ticketRef } from '../../shared/store'
import { extractImages, Gallery, Lightbox } from '../components/Gallery'
import { authorPerson, Reviews, TicketChip } from '../components/PrRow'
import { timeAgo } from '../format'

const REFRESH_MS = 30_000

const STATE_BADGES: Record<PrState, { label: string; className: string; icon: LucideIcon }> = {
  draft: { label: 'Draft', className: 'bg-muted text-muted-foreground', icon: CircleDashed },
  open: { label: 'Open', className: 'bg-info-soft text-info', icon: GitPullRequest },
  ready: { label: 'Ready to merge', className: 'bg-good-soft text-good', icon: CircleCheck },
  queued: { label: 'Queued', className: 'bg-warn-soft text-warn', icon: ListPlus },
  merged: { label: 'Merged', className: 'bg-good-soft text-good', icon: GitMerge },
  closed: { label: 'Closed', className: 'bg-bad-soft text-bad', icon: CircleX },
}

function StateBadge({ detail }: { detail: PrDetail }) {
  const badge = STATE_BADGES[detail.state]
  const Icon = badge.icon
  const position = detail.merge.queue?.position
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium ${badge.className}`}>
      <Icon className="size-3.5" />
      {badge.label}
      {detail.state === 'queued' && position != null && ` · #${position}`}
    </span>
  )
}

/**
 * GitHub's own rendering of the description, with its images moved to the gallery. Links leave
 * the app; an image reference in the text opens that image.
 */
function Description({ html, onOpenImage }: { html: string; onOpenImage: (index: number) => void }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    for (const link of ref.current?.querySelectorAll('a[href]') ?? []) {
      link.setAttribute('target', '_blank')
      link.setAttribute('rel', 'noreferrer')
    }
  }, [html])
  if (!html.trim()) return <p className="text-sm text-faint">No description.</p>
  return (
    // bodyHTML is rendered and sanitised by GitHub.
    <div
      ref={ref}
      className="markdown"
      onClick={(event) => {
        const imageRef = (event.target as HTMLElement).closest<HTMLElement>('[data-gallery-index]')
        if (imageRef) onOpenImage(Number(imageRef.dataset.galleryIndex))
      }}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  )
}

/* ---------- Merge readiness ---------- */

const BLOCKER_ICONS: Record<MergeBlocker['kind'], LucideIcon> = {
  draft: CircleDashed,
  conflicts: CircleX,
  behind: CircleMinus,
  'ci-failing': CircleX,
  'ci-pending': CircleDot,
  'changes-requested': CircleX,
  'code-owners': UserPlus,
  approvals: UserPlus,
  threads: MessageSquare,
}

function MergePanel({ detail }: { detail: PrDetail }) {
  const { merge, state, pr } = detail
  let headline: ReactNode
  if (state === 'merged')
    headline = <span className="text-good">Merged {pr.mergedAt ? timeAgo(pr.mergedAt) : ''}</span>
  else if (state === 'closed')
    headline = <span className="text-bad">Closed without merging {detail.closedAt ? timeAgo(detail.closedAt) : ''}</span>
  else if (merge.queue)
    headline = (
      <span className="text-warn">
        In the merge queue{merge.queue.position != null && `, position ${merge.queue.position}`} · added{' '}
        {timeAgo(merge.queue.enqueuedAt)}
      </span>
    )
  else if (merge.ready) headline = <span className="text-good">Ready to merge</span>
  else
    headline = (
      <span>
        Not ready to merge: {merge.blockers.length} thing{merge.blockers.length === 1 ? '' : 's'} in the way
      </span>
    )

  return (
    <Panel title="Merge status">
      <p className="text-sm font-medium">{headline}</p>
      {merge.blockers.length > 0 && (
        <ul className="mt-3 flex flex-col gap-2.5">
          {merge.blockers.map((blocker) => {
            const Icon = BLOCKER_ICONS[blocker.kind]
            const tone = blocker.kind === 'ci-pending' || blocker.kind === 'draft' ? 'text-muted-foreground' : 'text-bad'
            return (
              <li key={blocker.kind} className="flex gap-2 text-sm">
                <Icon className={`mt-0.5 size-4 shrink-0 ${tone}`} />
                <div className="min-w-0">
                  <p>{blocker.label}</p>
                  {blocker.items.length > 0 && (
                    <ul className="mt-0.5 text-xs text-muted-foreground">
                      {blocker.items.map((item) => (
                        <li key={item} className="truncate">
                          {item}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </li>
            )
          })}
        </ul>
      )}
      {merge.notes.length > 0 && (
        <ul className="mt-3 flex flex-col gap-1 border-t border-border pt-3">
          {merge.notes.map((note) => (
            <li key={note} className="flex gap-2 text-xs text-muted-foreground">
              <Info className="mt-0.5 size-3.5 shrink-0 text-faint" />
              {note}
            </li>
          ))}
        </ul>
      )}
    </Panel>
  )
}

/* ---------- CI ---------- */

const CHECK_ICONS: Record<CheckState, { icon: LucideIcon; className: string }> = {
  failed: { icon: CircleX, className: 'text-bad' },
  pending: { icon: CircleDot, className: 'text-warn' },
  passed: { icon: CircleCheck, className: 'text-good' },
  skipped: { icon: CircleMinus, className: 'text-faint' },
}

const CHECK_ORDER: CheckState[] = ['failed', 'pending', 'passed', 'skipped']

/** Whether the checks need anything from the author, for the panel header (visible even collapsed). */
function checksVerdict(checks: CheckItem[]): { label: string; className: string; title: string } | null {
  const requiredFailing = checks.filter((check) => check.required && check.state === 'failed').length
  const requiredRunning = checks.filter((check) => check.required && check.state === 'pending').length
  const advisoryFailing = checks.filter((check) => !check.required && check.state === 'failed').length
  if (requiredFailing)
    return {
      label: 'Blocking merge',
      className: 'bg-bad-soft text-bad',
      title: `${requiredFailing} required check${requiredFailing === 1 ? '' : 's'} failing: fix before merging`,
    }
  if (requiredRunning)
    return {
      label: 'Required running',
      className: 'bg-warn-soft text-warn',
      title: `${requiredRunning} required check${requiredRunning === 1 ? '' : 's'} still running`,
    }
  const advisoryRunning = checks.filter((check) => !check.required && check.state === 'pending').length
  if (advisoryFailing || advisoryRunning)
    return {
      label: 'Not blocking',
      className: 'bg-muted text-muted-foreground',
      title: [
        'Required checks pass',
        advisoryFailing && `${advisoryFailing} advisory check${advisoryFailing === 1 ? '' : 's'} failing`,
        advisoryRunning && `${advisoryRunning} advisory check${advisoryRunning === 1 ? '' : 's'} still running`,
      ]
        .filter(Boolean)
        .join('; '),
    }
  if (checks.length) return { label: 'All passing', className: 'bg-good-soft text-good', title: 'Every check passes' }
  return null
}

function CheckRow({ check }: { check: CheckItem }) {
  const { icon: Icon, className } = CHECK_ICONS[check.state]
  return (
    <li className="flex min-w-0 items-center gap-2 text-xs">
      <Icon className={`size-3.5 shrink-0 ${className}`} />
      {check.url ? (
        <a href={check.url} target="_blank" rel="noreferrer" className="min-w-0 truncate hover:underline" title={check.name}>
          {check.name}
        </a>
      ) : (
        <span className="min-w-0 truncate" title={check.name}>
          {check.name}
        </span>
      )}
      {check.expected && <span className="ml-auto shrink-0 text-[0.65rem] text-faint">waiting to report</span>}
      {check.state === 'failed' &&
        (check.required ? (
          <span className="ml-auto shrink-0 rounded bg-bad-soft px-1 text-[0.65rem] font-medium text-bad">blocks merge</span>
        ) : (
          <span className="ml-auto shrink-0 rounded bg-muted px-1 text-[0.65rem] text-faint">advisory</span>
        ))}
    </li>
  )
}

function byState(a: CheckItem, b: CheckItem) {
  return CHECK_ORDER.indexOf(a.state) - CHECK_ORDER.indexOf(b.state) || a.name.localeCompare(b.name)
}

/** Polling while anything runs is cheap: the checks endpoint asks GitHub for nothing else. */
const CHECKS_RUNNING_POLL_MS = 10_000
const CHECKS_IDLE_POLL_MS = 60_000
const MAX_CHECKS_SHOWN = 6

/**
 * What Merge status depends on: the head commit and the required checks. Advisory checks change
 * every few seconds during CI and only update this panel, so they don't trigger the (heavy)
 * full-page refresh.
 */
function mergeSignature(headOid: string, checks: CheckItem[]): string {
  return `${headOid}|${checks
    .filter((check) => check.required)
    .map((check) => `${check.name}:${check.state}`)
    .sort()
    .join(',')}`
}

/**
 * The checks, kept live: polled on their own (faster while any are running), with a button to
 * check now. When a required check or the head commit changes, `onChanged` refreshes the rest
 * of the page so Merge status agrees.
 */
function ChecksPanel({ detail, onChanged }: { detail: PrDetail; onChanged: () => void }) {
  const [showAll, setShowAll] = useState(false)
  const { pr } = detail
  const finished = detail.state === 'merged' || detail.state === 'closed'
  const live = useQuery({
    queryKey: ['pr-checks', pr.repo, pr.number],
    queryFn: () => fetchPrChecks(pr.repo, pr.number),
    initialData: { headOid: detail.headOid, checks: detail.checks, fetchedAt: detail.fetchedAt },
    initialDataUpdatedAt: Date.parse(detail.fetchedAt),
    refetchInterval: (query) =>
      query.state.data?.checks.some((check) => check.state === 'pending') ? CHECKS_RUNNING_POLL_MS : CHECKS_IDLE_POLL_MS,
    enabled: !finished,
  })
  // Whichever was read from GitHub last wins: this poll, or the page's own refresh.
  const latest = live.data.fetchedAt > detail.fetchedAt ? live.data : detail
  const checks = latest.checks
  const running = checks.some((check) => check.state === 'pending')

  const notifiedFor = useRef<string | null>(null)
  useEffect(() => {
    if (live.data.fetchedAt <= detail.fetchedAt) return
    const now = mergeSignature(live.data.headOid, live.data.checks)
    if (now === mergeSignature(detail.headOid, detail.checks) || now === notifiedFor.current) return
    notifiedFor.current = now
    onChanged()
  }, [live.data, detail, onChanged])

  const count = (state: CheckState) => checks.filter((check) => check.state === state).length
  const required = checks.filter((check) => check.required).sort(byState)
  const advisory = checks.filter((check) => !check.required).sort(byState)
  // Passed and skipped advisory checks are noise until asked for.
  const advisoryShown = showAll ? advisory : advisory.filter((check) => check.state === 'failed' || check.state === 'pending')
  const hidden = advisory.length - advisoryShown.length
  const verdict = checksVerdict(checks)
  // Long lists (dozens run in CI) are cut to the first few; failures sort first, so they stay visible.
  const [expanded, setExpanded] = useState(false)
  const mainList = required.length < checks.length ? advisoryShown : required
  const visible = expanded ? mainList : mainList.slice(0, MAX_CHECKS_SHOWN)
  const trimmed = mainList.length - visible.length

  return (
    <Panel
      title="Checks"
      actions={
        finished ? undefined : (
          <button
            type="button"
            onClick={() => live.refetch()}
            disabled={live.isFetching}
            aria-label="Check now"
            title="Check now"
            className="rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-60"
          >
            <RefreshCw className={`size-3.5 ${live.isFetching ? 'animate-spin' : ''}`} />
          </button>
        )
      }
      aside={
        <span className="flex flex-wrap items-center justify-end gap-x-2 gap-y-1">
          {verdict && (
            <span title={verdict.title} className={`rounded-md px-1.5 py-0.5 font-medium ${verdict.className}`}>
              {verdict.label}
            </span>
          )}
          <span className="text-good">{count('passed')} passed</span>
          {count('failed') > 0 && <span className="text-bad">{count('failed')} failed</span>}
          {count('pending') > 0 && <span className="text-warn">{count('pending')} running</span>}
        </span>
      }
    >
      {!finished && (
        <p className="mb-2.5 text-xs text-faint">
          Checked {timeAgo(latest.fetchedAt)} · {running ? 'every 10s while checks run' : 'every minute'}
          {live.error && <span className="text-bad"> · last check failed: {live.error.message}</span>}
        </p>
      )}
      {checks.length === 0 && <p className="text-sm text-faint">No checks on the latest commit.</p>}
      {required.length > 0 && required.length < checks.length && (
        <>
          <h3 className="mb-1.5 text-xs font-medium text-muted-foreground">Required to merge</h3>
          <ul className="mb-3 flex flex-col gap-1">
            {required.map((check) => (
              <CheckRow key={check.name} check={check} />
            ))}
          </ul>
          <h3 className="mb-1.5 text-xs font-medium text-muted-foreground">Advisory</h3>
        </>
      )}
      <ul className="flex flex-col gap-1">
        {visible.map((check) => (
          <CheckRow key={check.name} check={check} />
        ))}
      </ul>
      {(trimmed > 0 || expanded || hidden > 0 || showAll) && (
        <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs">
          {(trimmed > 0 || expanded) && mainList.length > MAX_CHECKS_SHOWN && (
            <button
              type="button"
              onClick={() => setExpanded((open) => !open)}
              aria-expanded={expanded}
              className="inline-flex items-center gap-1 text-info hover:underline"
            >
              <ChevronDown className={`size-3.5 transition-transform ${expanded ? 'rotate-180' : ''}`} />
              {expanded ? 'Show less' : `Show ${trimmed} more`}
            </button>
          )}
          {hidden > 0 && (
            <button type="button" onClick={() => setShowAll(true)} className="text-info hover:underline">
              Include {hidden} passed or skipped
            </button>
          )}
          {showAll && advisory.length > 0 && (
            <button type="button" onClick={() => setShowAll(false)} className="text-info hover:underline">
              Hide passed and skipped
            </button>
          )}
        </div>
      )}
    </Panel>
  )
}

/* ---------- Activity ---------- */

const ACTIVITY_ICONS: Record<ActivityKind, { icon: LucideIcon; className: string }> = {
  opened: { icon: GitPullRequest, className: 'text-info' },
  commits: { icon: GitCommitHorizontal, className: 'text-muted-foreground' },
  approved: { icon: Check, className: 'text-good' },
  'changes-requested': { icon: CircleAlert, className: 'text-bad' },
  reviewed: { icon: FileCode, className: 'text-muted-foreground' },
  comment: { icon: MessageSquare, className: 'text-muted-foreground' },
  'review-requested': { icon: UserPlus, className: 'text-muted-foreground' },
  event: { icon: CircleDot, className: 'text-muted-foreground' },
}

function ActivityRow({ item }: { item: ActivityItem }) {
  const [expanded, setExpanded] = useState(false)
  const { icon: Icon, className } = ACTIVITY_ICONS[item.kind]
  const isCommitList = item.kind === 'commits'
  return (
    <li className="relative flex gap-3 pb-4 last:pb-0">
      <span className="absolute top-6 bottom-0 left-[0.6875rem] w-px bg-border" aria-hidden />
      <span className="relative z-10 flex size-6 shrink-0 items-center justify-center rounded-full border border-border bg-card">
        <Icon className={`size-3.5 ${className}`} />
      </span>
      <div className="min-w-0 flex-1 pt-0.5">
        <p className="flex flex-wrap items-center gap-x-1.5 text-sm">
          {item.actor && <Avatar person={item.actor} className="size-4 ring-0" />}
          <span className="font-medium">{item.actor?.name ?? 'Someone'}</span>
          <span className="text-muted-foreground">{item.title}</span>
          {item.url ? (
            <a href={item.url} target="_blank" rel="noreferrer" className="text-xs text-faint hover:underline">
              {timeAgo(item.at)}
            </a>
          ) : (
            <span className="text-xs text-faint">{timeAgo(item.at)}</span>
          )}
        </p>
        {item.body &&
          (isCommitList ? (
            <ul className="mt-1 flex flex-col gap-0.5 text-xs text-muted-foreground">
              {item.body.split('\n').map((line, i) => (
                <li key={i} className="truncate font-mono">
                  {line}
                </li>
              ))}
            </ul>
          ) : (
            <button
              type="button"
              onClick={() => setExpanded((open) => !open)}
              className="mt-1 block w-full rounded-md bg-muted/60 px-3 py-2 text-left text-xs text-muted-foreground"
              title={expanded ? 'Show less' : 'Show more'}
            >
              {/* The clamp sits inside the padding, so a fourth line never peeks out. */}
              <span className={`block whitespace-pre-wrap ${expanded ? '' : 'line-clamp-3'}`}>{item.body}</span>
            </button>
          ))}
      </div>
    </li>
  )
}

function ThreadCard({ thread }: { thread: ReviewThread }) {
  return (
    <li className="rounded-md border border-border px-3 py-2">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
        <a href={thread.url} target="_blank" rel="noreferrer" className="truncate font-mono text-info hover:underline">
          {thread.path}
          {thread.line != null && `:${thread.line}`}
        </a>
        {thread.isOutdated && <span className="rounded bg-muted px-1 text-faint">outdated</span>}
        {thread.isBot && <span className="rounded bg-muted px-1 text-faint">bot</span>}
      </div>
      <p className="mt-1 line-clamp-3 text-xs whitespace-pre-wrap text-muted-foreground">{thread.body}</p>
      <p className="mt-1.5 flex items-center gap-1.5 text-xs text-faint">
        {thread.author && <Avatar person={thread.author} className="size-4 ring-0" />}
        {thread.author?.name ?? 'Someone'} · {timeAgo(thread.createdAt)}
        {thread.replies > 0 && ` · ${thread.replies} repl${thread.replies === 1 ? 'y' : 'ies'}`}
      </p>
    </li>
  )
}

function ChangeRequestCard({ request, threads }: { request: ChangeRequest; threads: ReviewThread[] }) {
  return (
    <li className="rounded-md border border-bad/30 bg-bad-soft/40 px-3 py-2">
      <p className="flex flex-wrap items-center gap-1.5 text-sm">
        <Avatar person={request.reviewer} ring="bad" className="size-5" />
        <span className="font-medium">{request.reviewer.name}</span>
        <span className="text-bad">requested changes</span>
        <a href={request.url} target="_blank" rel="noreferrer" className="text-xs text-faint hover:underline">
          {timeAgo(request.at)}
        </a>
      </p>
      {request.body && <p className="mt-1.5 text-xs whitespace-pre-wrap">{request.body}</p>}
      {threads.length > 0 && (
        <ul className="mt-2 flex flex-col gap-2">
          {threads.map((thread) => (
            <ThreadCard key={thread.id} thread={thread} />
          ))}
        </ul>
      )}
      {!request.body && threads.length === 0 && (
        <p className="mt-1 text-xs text-muted-foreground">No message or open threads; see the review on GitHub.</p>
      )}
    </li>
  )
}

function ActivityPanel({ detail }: { detail: PrDetail }) {
  const [showBots, setShowBots] = useState(false)
  const { activitySummary: summary, changeRequests, openThreads, activity } = detail
  const claimed = new Set(changeRequests.flatMap((request) => request.threadIds))
  const otherThreads = openThreads.filter((thread) => !claimed.has(thread.id))
  const shown = showBots ? activity : activity.filter((item) => !item.isBot)
  const botCount = activity.length - activity.filter((item) => !item.isBot).length

  const facts = [
    `${summary.commits} commit${summary.commits === 1 ? '' : 's'}`,
    `${summary.approvals} approval${summary.approvals === 1 ? '' : 's'}`,
    summary.changeRequests > 0 && `${summary.changeRequests} change request${summary.changeRequests === 1 ? '' : 's'}`,
    `${summary.comments} comment${summary.comments === 1 ? '' : 's'}`,
    openThreads.length > 0 && `${openThreads.length} open thread${openThreads.length === 1 ? '' : 's'}`,
  ].filter(Boolean)

  return (
    <Panel title="Activity" aside={`last activity ${timeAgo(summary.lastActivityAt)}`}>
      <p className="text-sm text-muted-foreground">{facts.join(' · ')}</p>

      {(changeRequests.length > 0 || otherThreads.length > 0) && (
        <div className="mt-4">
          <h3 className="mb-2 text-xs font-medium text-muted-foreground">Needs a response</h3>
          <ul className="flex flex-col gap-2">
            {changeRequests.map((request) => (
              <ChangeRequestCard
                key={request.reviewer.id}
                request={request}
                threads={openThreads.filter((thread) => request.threadIds.includes(thread.id))}
              />
            ))}
            {otherThreads.map((thread) => (
              <ThreadCard key={thread.id} thread={thread} />
            ))}
          </ul>
        </div>
      )}

      <div className="mt-4 flex items-center justify-between">
        <h3 className="text-xs font-medium text-muted-foreground">Timeline</h3>
        {botCount > 0 && (
          <button type="button" onClick={() => setShowBots((on) => !on)} className="text-xs text-info hover:underline">
            {showBots ? 'Hide' : 'Show'} {botCount} bot event{botCount === 1 ? '' : 's'}
          </button>
        )}
      </div>
      <ol className="mt-3">
        {shown.map((item) => (
          <ActivityRow key={item.id} item={item} />
        ))}
      </ol>
    </Panel>
  )
}

/* ---------- Page ---------- */

export function PrDetailPage() {
  const { owner, repo, number } = useParams({ from: '/prs/$owner/$repo/$number' })
  const { scope } = useSearch({ from: '/prs/$owner/$repo/$number' })
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const repoName = `${owner}/${repo}`
  const queryKey = ['pr', repoName, number]

  const query = useQuery({
    queryKey,
    queryFn: () => fetchPrDetail(repoName, Number(number)),
    refetchInterval: REFRESH_MS,
  })

  const refresh = useCallback(async () => {
    setRefreshing(true)
    try {
      await queryClient.fetchQuery({
        queryKey: ['pr', repoName, number],
        queryFn: () => fetchPrDetail(repoName, Number(number), true),
        staleTime: 0,
      })
    } finally {
      setRefreshing(false)
    }
  }, [queryClient, repoName, number])

  const detail = query.data
  const pr = detail?.pr
  // Notes and pins follow the ticket when there is one, so they match Today and Activity.
  const noteRef = pr ? (pr.tickets[0] ? ticketRef(pr.tickets[0].key) : prRef(pr.repo, pr.number)) : ''
  const description = useMemo(() => extractImages(detail?.bodyHtml ?? ''), [detail?.bodyHtml])
  const [openImage, setOpenImage] = useState<number | null>(null)

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center justify-between gap-3">
        <Link
          to="/prs"
          search={{ scope }}
          className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="size-4" />
          Pull requests
        </Link>
        <div className="flex items-center gap-3 text-xs text-muted-foreground">
          {detail &&
            (query.isFetching ? (
              <span className="flex items-center gap-1">
                <RefreshCw className="size-3 animate-spin" />
                Updating…
              </span>
            ) : (
              <span>Updated {timeAgo(detail.fetchedAt)}</span>
            ))}
          <Button variant="outline" size="sm" onClick={refresh} disabled={refreshing}>
            {refreshing ? 'Refreshing…' : 'Refresh'}
          </Button>
        </div>
      </div>

      {query.error && (
        <div className="rounded-lg border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad">
          {query.error instanceof ApiError && query.error.setup ? `Setup needed: ${query.error.message}` : query.error.message}
        </div>
      )}
      {query.isPending && <p className="text-sm text-muted-foreground">Loading pull request…</p>}

      {detail && pr && (
        <>
          <header className="flex flex-col gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <StateBadge detail={detail} />
              {pr.tickets.map((ticket) => (
                <TicketChip key={ticket.key} ticket={ticket} />
              ))}
            </div>
            <h1 className="flex items-start gap-2 text-xl font-semibold tracking-tight">
              <span className="min-w-0">
                {pr.title} <span className="font-normal text-faint">#{pr.number}</span>
              </span>
              <a
                href={pr.url}
                target="_blank"
                rel="noreferrer"
                title="Open on GitHub"
                aria-label="Open on GitHub"
                className="mt-1 shrink-0 rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              >
                <ExternalLink className="size-4" />
              </a>
              <span className="mt-0.5">
                <ItemControls refId={noteRef} title={pr.tickets[0] ? `${pr.tickets[0].key} ${pr.tickets[0].title}` : pr.title} url={pr.tickets[0]?.url ?? pr.url} prs={[{ repo: pr.repo, number: pr.number }]} />
              </span>
            </h1>
            <NoteLine refId={noteRef} />
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
              <span className="flex items-center gap-1.5">
                <Avatar person={authorPerson(pr)} className="size-4 ring-0" />
                {pr.author}
              </span>
              <span className="font-mono">
                {pr.headRef} → {pr.baseRef}
              </span>
              <span>
                <span className="text-good">+{pr.additions}</span> <span className="text-bad">−{pr.deletions}</span>
              </span>
              <span>opened {timeAgo(pr.createdAt)}</span>
              <span>{pr.repo}</span>
            </div>
          </header>

          <div className="grid grid-cols-1 items-start gap-5 lg:grid-cols-[minmax(0,1fr)_22rem]">
            <div className="order-2 flex min-w-0 flex-col gap-5 lg:order-1">
              <Panel title="Description">
                <Description html={description.html} onOpenImage={setOpenImage} />
              </Panel>
              {description.images.length > 0 && (
                <Panel
                  title="Screenshots"
                  aside={`${description.images.length} image${description.images.length === 1 ? '' : 's'}`}
                >
                  <Gallery images={description.images} onOpen={setOpenImage} />
                </Panel>
              )}
              <ActivityPanel detail={detail} />
            </div>
            <aside className="order-1 flex flex-col gap-5 lg:order-2">
              <PrActionsPanel detail={detail} />
              <MergePanel detail={detail} />
              <ChecksPanel detail={detail} onChanged={refresh} />
              {detail.state !== 'merged' && detail.state !== 'closed' && (
                <Panel title="Reviewers">
                  <Reviews pr={pr} />
                </Panel>
              )}
            </aside>
          </div>
          <Lightbox images={description.images} index={openImage} onIndexChange={setOpenImage} />
        </>
      )}
    </div>
  )
}
