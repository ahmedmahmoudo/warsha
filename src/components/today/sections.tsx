import {
  ArrowRight,
  AtSign,
  Bell,
  CalendarClock,
  Check,
  CircleAlert,
  Clock,
  Flame,
  FolderKanban,
  Link2,
  MessageSquare,
  Plus,
  Trash2,
  UserPlus,
} from 'lucide-react'
import { useState } from 'react'
import type { InboxItem, InboxKind, NeedsYouItem, NeedsYouKind, NudgeTarget, TodayResponse, UpNextItem } from '../../../shared/today'
import { ticketRef } from '../../../shared/store'
import { Button } from '@/components/ui/button'
import { useAddTodo, useDeleteTodo, useParking, useStore, useUnpark, useUnpin, useUpdateTodo } from '../../store'
import { timeAgo } from '../../format'
import { Avatar, PeopleHoverCard } from '../Avatar'
import { Panel } from '../Panel'
import { TicketChip } from '../PrRow'
import { ActionLink, ItemControls, NoteLine, PrLine, TicketOrPr } from './rows'

/* ---------- Needs you now ---------- */

/** Needs-you items grouped by what you'd do about them, most urgent first. */
const ACTION_GROUPS: { id: string; title: string; kinds: NeedsYouKind[]; bar: string }[] = [
  { id: 'resolve', title: 'Resolve conflicts', kinds: ['conflicts'], bar: 'bg-bad' },
  { id: 'ci', title: 'Fix CI', kinds: ['ci-failing'], bar: 'bg-bad' },
  { id: 'reply', title: 'Reply', kinds: ['changes-requested', 'threads'], bar: 'bg-warn' },
  { id: 'nudge', title: 'Nudge', kinds: ['stuck-review', 'slow-review'], bar: 'bg-warn' },
  { id: 'update', title: 'Update branch', kinds: ['behind'], bar: 'bg-warn' },
  { id: 'merge', title: 'Merge', kinds: ['ready'], bar: 'bg-good' },
  { id: 'housekeeping', title: 'Housekeeping', kinds: ['merged-not-done'], bar: 'bg-faint' },
]
const FILTER_STORAGE_KEY = 'workbench-needs-you-filter'

function readFilter(): string {
  try {
    const stored = localStorage.getItem(FILTER_STORAGE_KEY)
    return stored && (stored === 'all' || ACTION_GROUPS.some((group) => group.id === stored)) ? stored : 'all'
  } catch {
    return 'all'
  }
}

function writeFilter(filter: string) {
  try {
    localStorage.setItem(FILTER_STORAGE_KEY, filter)
  } catch {
    // Storage blocked: the filter still applies until the page reloads.
  }
}

const ACTION_CLASSES: Record<NeedsYouItem['tone'], string> = {
  bad: 'bg-bad text-white hover:bg-bad/90',
  warn: 'border border-warn/50 text-warn hover:bg-warn-soft',
  good: 'bg-good text-white hover:bg-good/90',
  neutral: 'border border-border text-muted-foreground hover:bg-accent',
}

const MEMBERS_SHOWN = 6

/** Whose approval a slow review waits on: each team with its members, ready to ping. */
function NudgeList({ groups }: { groups: NudgeTarget[][] }) {
  return (
    <div className="mt-2 flex flex-col gap-2 rounded-md bg-muted/50 px-2.5 py-2">
      <p className="text-[0.65rem] font-medium tracking-wide text-faint uppercase">Waiting on</p>
      {groups.map((group) => (
        <div key={group.map((target) => target.owner.id).join('|')} className="flex flex-col gap-1.5">
          {group.map((target, index) => (
            <div key={target.owner.id} className="min-w-0">
              <p className="flex items-center gap-1.5 text-xs">
                {index > 0 && <span className="text-faint">or</span>}
                <Avatar person={target.owner} className="size-4 ring-0" />
                <a href={target.owner.url} target="_blank" rel="noreferrer" className="font-medium hover:underline">
                  {target.owner.name}
                </a>
                {target.owner.kind === 'team' && <span className="text-faint">{target.members.length} people</span>}
              </p>
              {target.members.length > 0 && (
                <div className="mt-1 flex flex-wrap items-center gap-x-2.5 gap-y-1 pl-5.5">
                  {target.members.slice(0, MEMBERS_SHOWN).map((member) => (
                    <a
                      key={member.id}
                      href={member.url}
                      target="_blank"
                      rel="noreferrer"
                      title={member.id}
                      className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground hover:underline"
                    >
                      <Avatar person={member} className="size-4 ring-0" />
                      {member.name}
                    </a>
                  ))}
                  {target.members.length > MEMBERS_SHOWN && (
                    <PeopleHoverCard people={target.members.slice(MEMBERS_SHOWN)} title={`More of ${target.owner.name}`}>
                      <button type="button" className="text-xs text-info hover:underline">
                        +{target.members.length - MEMBERS_SHOWN} more
                      </button>
                    </PeopleHoverCard>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}

/** Copies a PR's link, for pasting into a nudge. */
function CopyLinkButton({ url }: { url: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(url)
          setCopied(true)
          setTimeout(() => setCopied(false), 2000)
        } catch {
          // Clipboard blocked: the button just doesn't confirm.
        }
      }}
      title="Copy the PR link"
      className="inline-flex items-center gap-1 rounded-md border border-border px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
    >
      {copied ? <Check className="size-3" /> : <Link2 className="size-3" />}
      {copied ? 'Copied' : 'Copy link'}
    </button>
  )
}

function NeedsYouRow({ item }: { item: NeedsYouItem }) {
  const title = item.ticket?.title ?? item.pr?.title ?? ''
  return (
    <li className="flex min-w-0 gap-3 py-2.5">
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-center gap-2">
          <TicketOrPr ticket={item.ticket} pr={item.pr} />
          <span className="truncate text-sm font-medium" title={title}>
            {title}
          </span>
        </div>
        <p className="mt-1 text-xs text-muted-foreground">
          <span className="font-medium text-foreground">{item.title}</span>
          {item.pr && <span className="text-faint"> · #{item.pr.number}</span>}
          {item.detail && <span> · {item.detail}</span>}
        </p>
        <NoteLine refId={item.ref} />
        {item.nudge && item.nudge.length > 0 && <NudgeList groups={item.nudge} />}
      </div>
      <div className="flex shrink-0 items-start gap-1">
        {item.nudge && item.pr && <CopyLinkButton url={item.pr.url} />}
        <ActionLink
          href={item.action.href}
          external={item.action.external}
          className={`inline-flex items-center gap-1 rounded-md px-2.5 py-1 text-xs font-medium ${ACTION_CLASSES[item.tone]}`}
        >
          {item.action.label}
        </ActionLink>
        <ItemControls
          refId={item.ref}
          title={title}
          url={item.ticket?.url ?? item.pr?.url ?? null}
          prs={item.pr ? [{ repo: item.pr.repo, number: item.pr.number }] : []}
        />
      </div>
    </li>
  )
}

export function NeedsYouSection({ data }: { data: TodayResponse }) {
  const [filter, setFilter] = useState(readFilter)
  const [showHousekeeping, setShowHousekeeping] = useState(false)
  const groups = ACTION_GROUPS.map((group) => ({ ...group, items: data.needsYou.filter((item) => group.kinds.includes(item.kind)) })).filter(
    (group) => group.items.length > 0,
  )
  // A remembered filter whose group has emptied falls back to everything.
  const active = groups.some((group) => group.id === filter) ? filter : 'all'
  const urgent = data.needsYou.filter((item) => item.kind !== 'merged-not-done').length
  const choose = (next: string) => {
    writeFilter(next)
    setFilter(next)
  }

  return (
    <Panel title="Needs you now" aside={urgent ? `${urgent} to act on` : 'All clear'}>
      {data.needsYou.length === 0 && <p className="text-sm text-faint">Nothing is waiting on you. Nice.</p>}
      {groups.length > 0 && (
        <div role="radiogroup" aria-label="Show" className="mb-3 flex flex-wrap gap-1.5">
          {[{ id: 'all', title: 'All', bar: '', count: data.needsYou.length }, ...groups.map((group) => ({ ...group, count: group.items.length }))].map(
            (chip) => (
              <button
                key={chip.id}
                type="button"
                role="radio"
                aria-checked={active === chip.id}
                onClick={() => choose(chip.id)}
                className={`flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs ${
                  active === chip.id ? 'border-foreground/40 bg-muted font-medium' : 'border-border text-muted-foreground hover:bg-accent'
                }`}
              >
                {chip.bar && <span className={`size-1.5 rounded-full ${chip.bar}`} />}
                {chip.title}
                <span className="text-faint">{chip.count}</span>
              </button>
            ),
          )}
        </div>
      )}
      <div className="flex flex-col gap-4">
        {groups
          .filter((group) => active === 'all' || group.id === active)
          .map((group) => {
            // Housekeeping waits behind a click in the overview; picked on its own, it shows.
            const hidden = group.id === 'housekeeping' && active === 'all' && !showHousekeeping
            return (
              <section key={group.id}>
                {active === 'all' && (
                  <h3 className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
                    <span className={`h-3 w-1 rounded-full ${group.bar}`} />
                    {group.title} <span className="text-faint">{group.items.length}</span>
                    {group.id === 'housekeeping' && (
                      <button type="button" onClick={() => setShowHousekeeping((open) => !open)} className="ml-1 text-info hover:underline">
                        {hidden ? 'Show' : 'Hide'}
                      </button>
                    )}
                  </h3>
                )}
                {!hidden && (
                  <ul className="divide-y divide-border">
                    {group.items.map((item) => (
                      <NeedsYouRow key={item.id} item={item} />
                    ))}
                  </ul>
                )}
              </section>
            )
          })}
      </div>
    </Panel>
  )
}

/* ---------- Up next ---------- */

const UP_NEXT_SHOWN = 6

function PriorityIcon({ priority }: { priority: number }) {
  if (priority === 1) return <Flame className="size-3.5 shrink-0 text-bad" aria-label="Urgent" />
  if (priority === 2) return <CircleAlert className="size-3.5 shrink-0 text-warn" aria-label="High priority" />
  return <span className="size-3.5 shrink-0" />
}

function UpNextRow({ item, isNew }: { item: UpNextItem; isNew: boolean }) {
  const { ticket } = item
  const ref = ticketRef(ticket.key)
  return (
    <li className="flex min-w-0 items-start gap-2.5 py-2.5">
      <PriorityIcon priority={ticket.priority} />
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-center gap-2">
          <span className="shrink-0">
            <TicketChip ticket={ticket} />
          </span>
          <a href={ticket.url} target="_blank" rel="noreferrer" className="truncate text-sm hover:underline" title={ticket.title}>
            {ticket.title}
          </a>
          {isNew && <span className="shrink-0 rounded bg-info-soft px-1 text-[0.65rem] font-medium text-info">New</span>}
        </div>
        {item.reasons.length > 0 && (
          <div className="mt-1 flex flex-wrap gap-1">
            {item.reasons.map((reason) => (
              <span
                key={reason}
                className={`rounded px-1.5 py-0.5 text-[0.65rem] ${
                  /overdue|Release Blocker|Urgent/.test(reason) ? 'bg-bad-soft text-bad' : 'bg-muted text-muted-foreground'
                }`}
              >
                {reason}
              </span>
            ))}
          </div>
        )}
        <NoteLine refId={ref} />
      </div>
      <ItemControls refId={ref} title={`${ticket.key} ${ticket.title}`} url={ticket.url} />
    </li>
  )
}

export function UpNextSection({ data, since }: { data: TodayResponse; since: string }) {
  const [showAll, setShowAll] = useState(false)
  const shown = showAll ? data.upNext : data.upNext.slice(0, UP_NEXT_SHOWN)
  return (
    <Panel title="Up next" aside="ranked by priority, deadlines and blockers">
      {data.upNext.length === 0 && <p className="text-sm text-faint">No unstarted tickets assigned to you.</p>}
      <ul className="divide-y divide-border">
        {shown.map((item) => (
          <UpNextRow key={item.ticket.key} item={item} isNew={(item.ticket.assignedAt ?? '') > since} />
        ))}
      </ul>
      {data.upNext.length > UP_NEXT_SHOWN && (
        <button type="button" onClick={() => setShowAll((open) => !open)} className="mt-2 text-xs text-info hover:underline">
          {showAll ? 'Show fewer' : `Show all ${data.upNext.length}`}
        </button>
      )}
    </Panel>
  )
}

/* ---------- New for you ---------- */

const INBOX_ICONS: Record<InboxKind, { icon: typeof Bell; className: string }> = {
  assigned: { icon: UserPlus, className: 'text-info' },
  comment: { icon: MessageSquare, className: 'text-muted-foreground' },
  mention: { icon: AtSign, className: 'text-warn' },
  status: { icon: ArrowRight, className: 'text-muted-foreground' },
  priority: { icon: Flame, className: 'text-bad' },
  project: { icon: FolderKanban, className: 'text-muted-foreground' },
  other: { icon: Bell, className: 'text-faint' },
}

function InboxRow({ item }: { item: InboxItem }) {
  const { icon: Icon, className } = INBOX_ICONS[item.kind]
  const subject = item.ticket ? item.ticket.key : item.project?.name
  const title = item.ticket?.title ?? null
  return (
    <li className="flex min-w-0 gap-2.5">
      <span className="relative mt-0.5 shrink-0">
        <Icon className={`size-4 ${className}`} />
        {item.unread && <span className="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-info" title="Unread in Linear" />}
      </span>
      <div className="min-w-0 flex-1 text-sm">
        <p className="min-w-0 leading-snug">
          <span className="font-medium">{item.actor?.name ?? 'Linear'}</span> <span className="text-muted-foreground">{item.verb}</span>{' '}
          {item.url ? (
            <a href={item.url} target="_blank" rel="noreferrer" className="font-medium hover:underline">
              {subject}
            </a>
          ) : (
            <span className="font-medium">{subject}</span>
          )}
        </p>
        {title && (
          <p className="truncate text-xs text-muted-foreground" title={title}>
            {title}
          </p>
        )}
        {item.snippet && <p className="mt-0.5 line-clamp-2 text-xs text-faint">“{item.snippet}”</p>}
      </div>
      <span className="shrink-0 text-xs text-faint">{timeAgo(item.at)}</span>
    </li>
  )
}

/**
 * What happened since you last looked: your Linear inbox (assignments, comments, mentions, status
 * and priority changes) and reviews asked of you on GitHub. Assignments the inbox lacks (archived
 * there) still show, from the tickets themselves.
 */
export function NewForYouSection({ data, since, onSeen, marking }: { data: TodayResponse; since: string; onSeen: () => void; marking: boolean }) {
  const [showEarlier, setShowEarlier] = useState(false)
  const inboxAssigned = new Set(data.inbox.filter((item) => item.kind === 'assigned').map((item) => item.ticket?.key))
  const fromTickets: InboxItem[] = data.tickets
    .filter((ticket) => (ticket.assignedAt ?? '') > since && !inboxAssigned.has(ticket.key))
    .map((ticket) => ({
      id: `assigned:${ticket.key}`,
      kind: 'assigned',
      at: ticket.assignedAt!,
      unread: false,
      actor: null,
      verb: 'assigned you',
      ticket: { key: ticket.key, title: ticket.title, url: ticket.url, state: ticket.state, stateColor: ticket.stateColor },
      project: null,
      snippet: null,
      url: ticket.url,
    }))
  const feed = [...data.inbox, ...fromTickets].sort((a, b) => b.at.localeCompare(a.at))
  const fresh = feed.filter((item) => item.at > since)
  const earlier = feed.filter((item) => item.at <= since)
  const nothing = fresh.length === 0 && data.reviewRequests.length === 0

  return (
    <Panel
      title="New for you"
      aside={fresh.length ? `${fresh.length} since ${data.lastSeenAt ? timeAgo(data.lastSeenAt) : '3 days'}` : undefined}
      actions={
        !nothing ? (
          <button type="button" onClick={onSeen} disabled={marking} className="rounded-md px-2 py-1 text-xs text-info hover:bg-accent disabled:opacity-60">
            {marking ? 'Marking…' : 'Mark seen'}
          </button>
        ) : undefined
      }
    >
      {nothing && <p className="text-sm text-faint">Nothing new since you last looked.</p>}
      {fresh.length > 0 && (
        <section className="mb-3">
          <h3 className="mb-2 text-xs font-medium text-muted-foreground">In Linear</h3>
          <ul className="flex flex-col gap-3">
            {fresh.map((item) => (
              <InboxRow key={item.id} item={item} />
            ))}
          </ul>
        </section>
      )}
      {data.reviewRequests.length > 0 && (
        <section className="mb-3">
          <h3 className="mb-1 text-xs font-medium text-muted-foreground">Asked to review</h3>
          <ul className="flex flex-col gap-1.5">
            {data.reviewRequests.map((pr) => (
              <PrLine key={pr.url} pr={pr}>
                {pr.authorAvatarUrl && (
                  <Avatar
                    person={{ kind: 'user', id: pr.author, name: pr.author, avatarUrl: pr.authorAvatarUrl, url: `https://github.com/${pr.author}` }}
                    className="size-4 ring-0"
                  />
                )}
              </PrLine>
            ))}
          </ul>
        </section>
      )}
      {earlier.length > 0 && (
        <>
          <button type="button" onClick={() => setShowEarlier((open) => !open)} className="text-xs text-info hover:underline">
            {showEarlier ? 'Hide earlier' : `Earlier (${earlier.length})`}
          </button>
          {showEarlier && (
            <ul className="mt-3 flex flex-col gap-3 opacity-80">
              {earlier.map((item) => (
                <InboxRow key={item.id} item={item} />
              ))}
            </ul>
          )}
        </>
      )}
    </Panel>
  )
}

/* ---------- Focus (pins) ---------- */

export function FocusSection({ data }: { data: TodayResponse | undefined }) {
  const { data: store } = useStore()
  const unpin = useUnpin()
  const pins = store?.pins ?? []
  const open = new Map((data?.tickets ?? []).map((ticket) => [ticketRef(ticket.key), ticket]))
  if (pins.length === 0)
    return (
      <div className="rounded-lg border border-dashed border-border px-4 py-3 text-sm text-faint">
        Pin what you want to focus on today with the pin icon on any item.
      </div>
    )
  return (
    <Panel title="Focus" aside={`${pins.length} pinned`}>
      <ul className="flex flex-col gap-2">
        {pins.map((pin) => {
          const ticket = open.get(pin.ref)
          const finished = pin.ref.startsWith('ticket:') && data && !ticket
          return (
            <li key={pin.ref} className="flex min-w-0 items-center gap-2 text-sm">
              {ticket ? (
                <span className="shrink-0">
                  <TicketChip ticket={ticket} />
                </span>
              ) : (
                <span className="shrink-0 font-mono text-xs text-muted-foreground">{pin.ref.replace(/^\w+:/, '')}</span>
              )}
              <span className={`min-w-0 truncate ${finished ? 'text-faint line-through' : ''}`}>
                {pin.url ? (
                  <a href={pin.url} target="_blank" rel="noreferrer" className="hover:underline">
                    {ticket?.title ?? pin.title}
                  </a>
                ) : (
                  (ticket?.title ?? pin.title)
                )}
              </span>
              {finished && <span className="shrink-0 text-xs text-good">done</span>}
              <span className="ml-auto flex shrink-0 items-center">
                <ItemControls refId={pin.ref} title={pin.title} url={pin.url} />
                {finished && (
                  <button type="button" onClick={() => unpin.mutate(pin.ref)} className="ml-1 text-xs text-info hover:underline">
                    Clear
                  </button>
                )}
              </span>
            </li>
          )
        })}
      </ul>
    </Panel>
  )
}

/* ---------- Todos ---------- */

export function TodosSection({ today }: { today: string }) {
  const { data: store } = useStore()
  const add = useAddTodo()
  const update = useUpdateTodo()
  const remove = useDeleteTodo()
  const [text, setText] = useState('')
  const [dueDate, setDueDate] = useState('')
  const todos = store?.todos ?? []
  const open = todos.filter((todo) => !todo.doneAt)
  const done = todos.filter((todo) => todo.doneAt)

  function submit() {
    if (!text.trim()) return
    // "MX-2481 check the copy" links the todo to that ticket.
    const key = text.match(/\b[A-Z][A-Z0-9]{1,9}-\d{1,7}\b/)?.[0]
    add.mutate(
      { text, ref: key ? ticketRef(key) : null, dueDate: dueDate || null },
      {
        onSuccess: () => {
          setText('')
          setDueDate('')
        },
      },
    )
  }

  return (
    <Panel title="Todos" aside={`${open.length} open`}>
      <form
        className="mb-3 flex gap-1.5"
        onSubmit={(event) => {
          event.preventDefault()
          submit()
        }}
      >
        <input
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="Add a todo… (mention a ticket key to link it)"
          maxLength={4000}
          className="min-w-0 flex-1 rounded-md border border-input bg-background px-2 py-1 text-sm outline-none focus:border-ring"
        />
        <input
          type="date"
          value={dueDate}
          onChange={(event) => setDueDate(event.target.value)}
          aria-label="Due date"
          className="w-[7.5rem] rounded-md border border-input bg-background px-1.5 py-1 text-xs text-muted-foreground outline-none focus:border-ring"
        />
        <Button type="submit" size="sm" variant="outline" disabled={!text.trim() || add.isPending} aria-label="Add todo">
          <Plus />
        </Button>
      </form>
      {add.error && <p className="mb-2 text-xs text-bad">{add.error.message}</p>}
      {open.length === 0 && <p className="text-sm text-faint">Nothing on your list.</p>}
      <ul className="flex flex-col gap-1">
        {[...open, ...done].map((todo) => {
          const overdue = !todo.doneAt && todo.dueDate !== null && todo.dueDate < today
          return (
            <li key={todo.id} className="group flex min-w-0 items-start gap-2 text-sm">
              <button
                type="button"
                onClick={() => update.mutate({ id: todo.id, done: !todo.doneAt })}
                aria-label={todo.doneAt ? 'Mark not done' : 'Mark done'}
                className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded border ${
                  todo.doneAt ? 'border-good bg-good text-white' : 'border-border hover:border-foreground'
                }`}
              >
                {todo.doneAt && <Check className="size-3" />}
              </button>
              <span className={`min-w-0 flex-1 break-words ${todo.doneAt ? 'text-faint line-through' : ''}`}>{todo.text}</span>
              {todo.dueDate && (
                <span className={`shrink-0 text-xs ${overdue ? 'text-bad' : 'text-faint'}`}>
                  {todo.dueDate === today ? 'today' : new Date(`${todo.dueDate}T12:00:00Z`).toLocaleDateString('en-AU', { day: 'numeric', month: 'short', timeZone: 'UTC' })}
                </span>
              )}
              <button
                type="button"
                onClick={() => remove.mutate(todo.id)}
                aria-label="Delete todo"
                className="shrink-0 text-faint opacity-0 group-hover:opacity-100 hover:text-bad focus:opacity-100"
              >
                <Trash2 className="size-3.5" />
              </button>
            </li>
          )
        })}
      </ul>
    </Panel>
  )
}

/* ---------- Deadlines ---------- */

export function DeadlinesSection({ data }: { data: TodayResponse }) {
  return (
    <Panel title="Deadlines">
      {data.deadlines.length === 0 && <p className="text-sm text-faint">No cycle or project deadlines coming up.</p>}
      <ul className="flex flex-col gap-2">
        {data.deadlines.map((deadline) => {
          const overdue = deadline.daysLeft < 0
          const soon = !overdue && deadline.daysLeft <= 3
          return (
            <li key={`${deadline.kind}:${deadline.name}`} className="flex min-w-0 items-start gap-2 text-sm">
              <CalendarClock className={`mt-0.5 size-4 shrink-0 ${overdue ? 'text-bad' : soon ? 'text-warn' : 'text-faint'}`} />
              <div className="min-w-0 flex-1">
                <p className="truncate" title={deadline.name}>
                  {deadline.url ? (
                    <a href={deadline.url} target="_blank" rel="noreferrer" className="hover:underline">
                      {deadline.name}
                    </a>
                  ) : (
                    deadline.name
                  )}
                </p>
                <p className="text-xs text-muted-foreground">
                  {deadline.ticketCount} of your ticket{deadline.ticketCount === 1 ? '' : 's'}
                </p>
              </div>
              <span className={`shrink-0 text-xs font-medium ${overdue ? 'text-bad' : soon ? 'text-warn' : 'text-muted-foreground'}`}>
                {overdue ? `${-deadline.daysLeft}d overdue` : deadline.daysLeft === 0 ? 'today' : `in ${deadline.daysLeft}d`}
              </span>
            </li>
          )
        })}
      </ul>
    </Panel>
  )
}

/* ---------- Waiting on others ---------- */

export function WaitingSection({ data }: { data: TodayResponse }) {
  return (
    <Panel title="Waiting on others" aside={`${data.waiting.length} PRs`}>
      {data.waiting.length === 0 && <p className="text-sm text-faint">Nothing of yours is waiting on others.</p>}
      <ul className="flex flex-col gap-1.5">
        {data.waiting.map((pr) => (
          <PrLine key={pr.url} pr={pr}>
            <Clock className="size-3.5 text-faint" />
          </PrLine>
        ))}
      </ul>
    </Panel>
  )
}

/* ---------- Parked ---------- */

/** What you've set aside, collapsed by default; each can be unparked or comes back on its date. */
export function ParkedSection() {
  const { all } = useParking()
  const unpark = useUnpark()
  const [open, setOpen] = useState(false)
  if (all.length === 0) return null
  return (
    <Panel
      title="Parked"
      aside={`${all.length} set aside`}
      actions={
        <button type="button" onClick={() => setOpen((shown) => !shown)} className="rounded-md px-2 py-1 text-xs text-info hover:bg-accent">
          {open ? 'Hide' : 'Show'}
        </button>
      }
    >
      {!open ? (
        <p className="text-xs text-faint">Kept out of Needs you, Up next and the stuck flags.</p>
      ) : (
        <ul className="flex flex-col gap-2.5">
          {all.map((item) => (
            <li key={item.ref} className="flex min-w-0 items-start gap-2 text-sm">
              <div className="min-w-0 flex-1">
                <p className="truncate" title={item.title}>
                  <span className="mr-1.5 font-mono text-xs text-muted-foreground">{item.ref.replace(/^\w+:/, '')}</span>
                  {item.url ? (
                    <a href={item.url} target="_blank" rel="noreferrer" className="hover:underline">
                      {item.title.replace(/^[A-Z][A-Z0-9]+-\d+\s+/, '')}
                    </a>
                  ) : (
                    item.title
                  )}
                </p>
                <p className="text-xs text-faint">
                  {[item.reason, item.until ? `back ${new Date(`${item.until}T12:00:00Z`).toLocaleDateString('en-AU', { day: 'numeric', month: 'short', timeZone: 'UTC' })}` : null, `parked ${timeAgo(item.parkedAt)}`]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </div>
              <button
                type="button"
                onClick={() => unpark.mutate(item.ref)}
                disabled={unpark.isPending}
                className="shrink-0 text-xs text-info hover:underline disabled:opacity-60"
              >
                Unpark
              </button>
            </li>
          ))}
        </ul>
      )}
    </Panel>
  )
}

