import { Link } from '@tanstack/react-router'
import { ExternalLink } from 'lucide-react'
import type { ReactNode } from 'react'
import type { FailedCheck, Mismatch, Person, Pr, PrScope, Ticket } from '../../shared/prs'
import { timeAgo } from '../format'
import { Avatar, AvatarStack, PeopleHoverCard, type AvatarRing } from './Avatar'
import { ItemControls, NoteLine } from './StoreButtons'
import { useParking } from '../store'
import { prRef, ticketRef } from '../../shared/store'

export const TONE_CLASSES: Record<Pr['status']['tone'], string> = {
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

export function TicketChip({ ticket }: { ticket: Ticket }) {
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

function names(people: Person[], joiner = ', '): string {
  return people.map((person) => person.name).join(joiner)
}

const CODERABBIT_LABELS: Record<NonNullable<Pr['coderabbit']['review']>, string> = {
  APPROVED: 'approved',
  CHANGES_REQUESTED: 'wants changes',
  COMMENTED: 'commented',
}

/** One line of the Reviews column: avatars, then what they mean. */
function ReviewLine({ people, ring, children, className, title }: {
  people: Person[]
  ring?: AvatarRing
  children: ReactNode
  className?: string
  title?: string
}) {
  return (
    <div className="flex min-w-0 items-center gap-2">
      <AvatarStack people={people} ring={ring} />
      <span className={`truncate ${className ?? ''}`} title={title}>
        {children}
      </span>
    </div>
  )
}

export function Reviews({ pr }: { pr: Pr }) {
  const { coderabbit, reviewGate: gate } = pr
  const blocking = gate ? gate.codeOwners.length + (gate.approvalsNeeded > 0 ? 1 : 0) : 0
  return (
    <div className="flex min-w-0 flex-col gap-1.5 text-xs">
      <span className="text-faint">{blocking > 0 ? 'Needs approval from' : 'Reviews'}</span>

      {gate?.codeOwners.map((group) => (
        <ReviewLine key={group.map((person) => person.id).join(' ')} people={group} title={`Code owner: ${names(group, ' or ')}`}>
          {names(group, ' or ')}
        </ReviewLine>
      ))}
      {gate && gate.approvalsNeeded > 0 && (
        <div className="flex items-center gap-2 text-muted-foreground">
          <span className="size-5 shrink-0 rounded-full border border-dashed border-faint" />
          {gate.approvalsNeeded} {gate.codeOwners.length ? 'more ' : ''}approval{gate.approvalsNeeded === 1 ? '' : 's'}
        </div>
      )}
      {gate && !gate.complete && <span className="text-faint">Code owners may be incomplete</span>}

      {pr.changesRequestedBy.length > 0 && (
        <ReviewLine people={pr.changesRequestedBy} ring="bad" className="text-bad" title={names(pr.changesRequestedBy)}>
          Changes requested
        </ReviewLine>
      )}
      {pr.approvals.length > 0 && (
        <ReviewLine people={pr.approvals} ring="good" className="text-good" title={names(pr.approvals)}>
          Approved
        </ReviewLine>
      )}
      {gate && gate.optional.length > 0 && (
        <PeopleHoverCard people={gate.optional} title="Requested, but not required to merge">
          <button type="button" className="w-fit text-left text-faint underline decoration-dotted underline-offset-2 hover:text-foreground">
            +{gate.optional.length} optional reviewer{gate.optional.length === 1 ? '' : 's'}
          </button>
        </PeopleHoverCard>
      )}

      <span className={coderabbit.review === 'CHANGES_REQUESTED' ? 'text-warn' : 'text-faint'}>
        CodeRabbit {coderabbit.review ? CODERABBIT_LABELS[coderabbit.review] : 'not reviewed'}
        {coderabbit.unresolvedThreads > 0 && `, ${coderabbit.unresolvedThreads} open`}
      </span>
    </div>
  )
}

export function authorPerson(pr: Pr): Person {
  return { kind: 'user', id: pr.author, name: pr.author, avatarUrl: pr.authorAvatarUrl, url: `https://github.com/${pr.author}` }
}

/** Route params for a PR's details page. */
export function prParams(pr: Pr): { owner: string; repo: string; number: string } {
  const [owner = '', repo = ''] = pr.repo.split('/')
  return { owner, repo, number: String(pr.number) }
}

export function PrRow({
  pr,
  viewer,
  stackParent,
  scope,
}: {
  pr: Pr
  viewer: string
  stackParent: Pr | undefined
  scope: PrScope
}) {
  const isOwn = pr.author === viewer
  const parked = useParking().forPr(pr)
  const itemRef = pr.tickets[0] ? ticketRef(pr.tickets[0].key) : prRef(pr.repo, pr.number)
  return (
    <li className="grid grid-cols-1 gap-3 border-b border-border px-4 py-3 last:border-b-0 md:grid-cols-[minmax(0,1fr)_13rem_14rem]">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <span className={`rounded-md px-1.5 py-0.5 text-xs font-medium ${TONE_CLASSES[pr.status.tone]}`}>
            {pr.status.label}
          </span>
          {parked && (
            <span className="rounded-md bg-info-soft px-1.5 py-0.5 text-xs text-info" title={parked.reason ?? undefined}>
              Parked{parked.until ? ` until ${parked.until.slice(5).replace('-', '/')}` : ''}
            </span>
          )}
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
        <div className="mt-1.5 flex min-w-0 items-center gap-1">
          <Link
            to="/prs/$owner/$repo/$number"
            params={prParams(pr)}
            search={{ scope }}
            className="min-w-0 truncate font-medium hover:underline"
          >
            {pr.title}
          </Link>
          <ItemControls
            refId={itemRef}
            title={pr.tickets[0] ? `${pr.tickets[0].key} ${pr.tickets[0].title}` : pr.title}
            url={pr.tickets[0]?.url ?? pr.url}
            prs={[{ repo: pr.repo, number: pr.number }]}
          />
        </div>
        <NoteLine refId={itemRef} />
        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
          <a
            href={pr.url}
            target="_blank"
            rel="noreferrer"
            title="Open on GitHub"
            className="inline-flex items-center gap-1 font-mono hover:text-foreground"
          >
            #{pr.number}
            <ExternalLink className="size-3" />
          </a>
          {!isOwn && (
            <span className="flex items-center gap-1.5">
              <Avatar person={authorPerson(pr)} className="size-4 ring-0" />
              {pr.author}
            </span>
          )}
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
