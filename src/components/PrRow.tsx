import type { FailedCheck, Mismatch, Pr, Ticket } from '../../shared/prs'
import { timeAgo } from '../format'

const TONE_CLASSES: Record<Pr['status']['tone'], string> = {
  good: 'bg-good-soft text-good',
  bad: 'bg-bad-soft text-bad',
  warn: 'bg-warn-soft text-warn',
  neutral: 'bg-muted text-muted-foreground',
}

const MISMATCH_LABELS: Record<Mismatch, string> = {
  'no-ticket': 'No Linear ticket',
  'ticket-closed-pr-open': 'Ticket closed, PR still open',
  'ticket-not-started': 'Ticket not started',
  'pr-merged-ticket-open': 'Merged, ticket still open',
}

function TicketChip({ ticket }: { ticket: Ticket }) {
  return (
    <a
      href={ticket.url}
      target="_blank"
      rel="noreferrer"
      title={`${ticket.title}${ticket.assignee ? ` · ${ticket.assignee}` : ''}${ticket.project ? ` · ${ticket.project}` : ''}`}
      className="inline-flex items-center gap-1.5 rounded-md border border-border px-1.5 py-0.5 text-xs hover:bg-accent"
    >
      <span className="size-2 rounded-full" style={{ background: ticket.stateColor }} />
      <span className="font-mono">{ticket.key}</span>
      <span className="text-muted-foreground">{ticket.state}</span>
    </a>
  )
}

const MAX_LISTED = 3

function FailedCheckLink({ check, className }: { check: FailedCheck; className: string }) {
  return (
    <a href={check.url ?? undefined} target="_blank" rel="noreferrer" className={`truncate hover:underline ${className}`}>
      {check.name}
    </a>
  )
}

function Checks({ checks }: { checks: Pr['checks'] }) {
  // A failing required aggregate ("Required CI") says nothing on its own, so name what broke it.
  const showAdvisoryNames = checks.state === 'failing' && checks.advisoryFailing.length > 0
  return (
    <div className="flex min-w-0 flex-col gap-0.5 text-xs">
      <span className="text-faint">Checks</span>
      {checks.state === 'failing' &&
        checks.failing.map((check) => <FailedCheckLink key={check.name} check={check} className="text-bad" />)}
      {checks.state === 'pending' && <span className="text-muted-foreground">{checks.pending.length} required running</span>}
      {checks.state === 'passing' && <span className="text-good">Required pass</span>}
      {checks.state === 'none' && <span className="text-faint">None</span>}
      {showAdvisoryNames &&
        checks.advisoryFailing
          .slice(0, MAX_LISTED)
          .map((check) => <FailedCheckLink key={check.name} check={check} className="text-muted-foreground" />)}
      {checks.advisoryFailing.length > (showAdvisoryNames ? MAX_LISTED : 0) && (
        <span className="text-faint" title={checks.advisoryFailing.map((c) => c.name).join('\n')}>
          {showAdvisoryNames
            ? `+${checks.advisoryFailing.length - MAX_LISTED} more failing`
            : `${checks.advisoryFailing.length} advisory failing`}
        </span>
      )}
    </div>
  )
}

function names(list: string[]): string {
  return list.length > MAX_LISTED ? `${list.slice(0, MAX_LISTED).join(', ')} +${list.length - MAX_LISTED}` : list.join(', ')
}

const CODERABBIT_LABELS: Record<NonNullable<Pr['coderabbit']['review']>, string> = {
  APPROVED: 'approved',
  CHANGES_REQUESTED: 'wants changes',
  COMMENTED: 'commented',
}

function Reviews({ pr }: { pr: Pr }) {
  const { coderabbit } = pr
  return (
    <div className="flex min-w-0 flex-col gap-0.5 text-xs">
      <span className="text-faint">Reviews</span>
      {pr.approvals.length > 0 && <span className="text-good">Approved by {names(pr.approvals)}</span>}
      {pr.changesRequestedBy.length > 0 && <span className="text-bad">Changes from {names(pr.changesRequestedBy)}</span>}
      {pr.pendingReviewers.length > 0 && (
        <span className="text-muted-foreground" title={pr.pendingReviewers.join('\n')}>
          Waiting on {names(pr.pendingReviewers)}
        </span>
      )}
      <span className={coderabbit.review === 'CHANGES_REQUESTED' ? 'text-warn' : 'text-faint'}>
        CodeRabbit {coderabbit.review ? CODERABBIT_LABELS[coderabbit.review] : 'not reviewed'}
        {coderabbit.unresolvedThreads > 0 && `, ${coderabbit.unresolvedThreads} open`}
      </span>
    </div>
  )
}

export function PrRow({ pr, viewer, stackParent }: { pr: Pr; viewer: string; stackParent: Pr | undefined }) {
  const isOwn = pr.author === viewer
  return (
    <li className="grid grid-cols-1 gap-3 border-b border-border px-4 py-3 last:border-b-0 md:grid-cols-[minmax(0,1fr)_13rem_11rem]">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <span className={`rounded-md px-1.5 py-0.5 text-xs font-medium ${TONE_CLASSES[pr.status.tone]}`}>
            {pr.status.label}
          </span>
          {pr.tickets.map((ticket) => (
            <TicketChip key={ticket.key} ticket={ticket} />
          ))}
          {pr.tickets.length === 0 &&
            pr.ticketKeys.map((key) => (
              <span key={key} className="rounded-md border border-border px-1.5 py-0.5 font-mono text-xs text-muted-foreground">
                {key}
              </span>
            ))}
          {pr.mismatches.map((mismatch) => (
            <span key={mismatch} className="rounded-md bg-warn-soft px-1.5 py-0.5 text-xs text-warn">
              {MISMATCH_LABELS[mismatch]}
            </span>
          ))}
        </div>
        <a href={pr.url} target="_blank" rel="noreferrer" className="mt-1.5 block truncate font-medium hover:underline">
          {pr.title}
        </a>
        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
          <span className="font-mono">#{pr.number}</span>
          {!isOwn && <span>by {pr.author}</span>}
          <span>
            → <span className="font-mono">{pr.baseRef}</span>
          </span>
          {stackParent && (
            <a href={stackParent.url} target="_blank" rel="noreferrer" className="text-info hover:underline">
              stacked on #{stackParent.number}
            </a>
          )}
          <span>
            <span className="text-good">+{pr.additions}</span> <span className="text-bad">−{pr.deletions}</span>
          </span>
          <span>{pr.mergedAt ? `merged ${timeAgo(pr.mergedAt)}` : `updated ${timeAgo(pr.updatedAt)}`}</span>
        </div>
      </div>
      <Checks checks={pr.checks} />
      <Reviews pr={pr} />
    </li>
  )
}
