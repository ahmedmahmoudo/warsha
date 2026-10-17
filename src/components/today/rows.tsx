import { Link } from '@tanstack/react-router'
import { ArrowUpRight } from 'lucide-react'
import type { ReactNode } from 'react'
import type { Pr, Ticket } from '../../../shared/prs'
import { TicketChip, TONE_CLASSES } from '../PrRow'
export { ItemControls, NoteLine } from '../StoreButtons'

/** Route params for a PR's details page. */
export function prParamsOf(pr: { repo: string; number: number }) {
  const [owner = '', repo = ''] = pr.repo.split('/')
  return { owner, repo, number: String(pr.number) }
}

/** A link that stays in the app for app paths and opens a tab for anything else. */
export function ActionLink({ href, external, children, className }: { href: string; external: boolean; children: ReactNode; className?: string }) {
  if (external)
    return (
      <a href={href} target="_blank" rel="noreferrer" className={className}>
        {children}
        <ArrowUpRight className="size-3" />
      </a>
    )
  const match = href.match(/^\/prs\/([^/]+)\/([^/]+)\/(\d+)$/)
  return match ? (
    <Link
      to="/prs/$owner/$repo/$number"
      params={{ owner: match[1]!, repo: match[2]!, number: match[3]! }}
      search={{ scope: 'mine' }}
      className={className}
    >
      {children}
    </Link>
  ) : (
    <a href={href} className={className}>
      {children}
    </a>
  )
}

/** A ticket's chip, or a "PR" label when there's no ticket. */
export function TicketOrPr({ ticket, pr }: { ticket: Ticket | null; pr: Pick<Pr, 'number'> | null }) {
  if (ticket)
    return (
      <span className="shrink-0">
        <TicketChip ticket={ticket} />
      </span>
    )
  return <span className="shrink-0 rounded-md border border-border px-1.5 py-0.5 font-mono text-xs text-muted-foreground">#{pr?.number}</span>
}

/** A PR in a short list: number and title linking to its details, status on the right. */
export function PrLine({ pr, children }: { pr: Pr; children?: ReactNode }) {
  return (
    <li className="flex min-w-0 items-center gap-2 text-sm">
      <Link
        to="/prs/$owner/$repo/$number"
        params={prParamsOf(pr)}
        search={{ scope: 'mine' }}
        className="min-w-0 truncate hover:underline"
        title={pr.title}
      >
        <span className="text-faint">#{pr.number}</span> {pr.title}
      </Link>
      <span className="ml-auto flex shrink-0 items-center gap-2">
        {children}
        <span className={`rounded px-1.5 py-0.5 text-[0.65rem] font-medium ${TONE_CLASSES[pr.status.tone]}`}>{pr.status.label}</span>
      </span>
    </li>
  )
}
