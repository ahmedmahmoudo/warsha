import {
  ArrowRight,
  Check,
  CircleAlert,
  GitCommitHorizontal,
  GitMerge,
  GitPullRequest,
  MessageSquare,
  type LucideIcon,
} from 'lucide-react'
import type { ActivityDay, DayEntry, DayEntryKind } from '../../../shared/activity'

export const ENTRY_ICONS: Record<DayEntryKind, { icon: LucideIcon; className: string; label: string }> = {
  pushed: { icon: GitCommitHorizontal, className: 'text-muted-foreground', label: 'pushed' },
  opened: { icon: GitPullRequest, className: 'text-info', label: 'opened a PR' },
  merged: { icon: GitMerge, className: 'text-good', label: 'merged' },
  closed: { icon: CircleAlert, className: 'text-bad', label: 'closed a PR' },
  reopened: { icon: GitPullRequest, className: 'text-info', label: 'reopened a PR' },
  replied: { icon: MessageSquare, className: 'text-muted-foreground', label: 'replied to review comments' },
  commented: { icon: MessageSquare, className: 'text-muted-foreground', label: 'commented' },
  approved: { icon: Check, className: 'text-good', label: 'approved' },
  'changes-requested': { icon: CircleAlert, className: 'text-bad', label: 'requested changes' },
  reviewed: { icon: MessageSquare, className: 'text-muted-foreground', label: 'reviewed' },
  ticket: { icon: ArrowRight, className: 'text-faint', label: 'moved the ticket' },
}

/** One thing that happened, with its icon and a link when there is one. */
export function Entry({ entry }: { entry: DayEntry }) {
  const { icon: Icon, className } = ENTRY_ICONS[entry.kind]
  const content = (
    <>
      <Icon className={`size-3.5 shrink-0 ${className}`} />
      {entry.text}
    </>
  )
  return entry.url ? (
    <a href={entry.url} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 hover:text-foreground hover:underline">
      {content}
    </a>
  ) : (
    <span className="inline-flex items-center gap-1">{content}</span>
  )
}

/** The order the at-a-glance icons appear in: outcomes first. */
const GLANCE_ORDER: DayEntryKind[] = ['merged', 'opened', 'approved', 'changes-requested', 'reviewed', 'pushed', 'replied', 'ticket']

/** Which kinds of thing happened, as a row of small icons, for compact views. */
export function KindIcons({ kinds }: { kinds: Iterable<DayEntryKind> }) {
  const present = new Set(kinds)
  return (
    <span className="flex items-center gap-1">
      {GLANCE_ORDER.filter((kind) => present.has(kind)).map((kind) => {
        const { icon: Icon, className, label } = ENTRY_ICONS[kind]
        return <Icon key={kind} className={`size-3 ${className}`} aria-label={label} />
      })}
    </span>
  )
}

/** Counts for a day's corner: what shipped, what opened, what was reviewed. */
export function dayCounts(day: ActivityDay) {
  const entries = day.groups.flatMap((group) => group.entries)
  return {
    merged: entries.filter((entry) => entry.kind === 'merged').length,
    opened: entries.filter((entry) => entry.kind === 'opened').length,
    reviews: day.reviews.length,
  }
}
