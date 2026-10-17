import { HoverCard } from 'radix-ui'
import { useState, type ReactNode } from 'react'
import type { Person } from '../../shared/prs'
import { cn } from '@/lib/utils'

const RING_CLASSES = {
  none: 'ring-card',
  good: 'ring-good',
  bad: 'ring-bad',
} as const

export type AvatarRing = keyof typeof RING_CLASSES

function initials(name: string): string {
  const words = name.split(/[\s_-]+/).filter(Boolean)
  return (words.length > 1 ? words[0]![0]! + words[1]![0]! : name.slice(0, 2)).toUpperCase()
}

/** Teams are square and people round, so a team request reads differently from a person's. */
export function Avatar({ person, ring = 'none', className }: { person: Person; ring?: AvatarRing; className?: string }) {
  const [failed, setFailed] = useState(false)
  const shape = person.kind === 'team' ? 'rounded-md' : 'rounded-full'
  return (
    <a
      href={person.url}
      target="_blank"
      rel="noreferrer"
      title={person.kind === 'team' ? `${person.name} (team)` : person.name}
      className={cn('inline-flex size-5 shrink-0 ring-2', shape, RING_CLASSES[ring], className)}
    >
      {person.avatarUrl && !failed ? (
        <img
          src={person.avatarUrl}
          alt=""
          loading="lazy"
          onError={() => setFailed(true)}
          className={cn('size-full bg-muted object-cover', shape)}
        />
      ) : (
        <span
          className={cn(
            'flex size-full items-center justify-center bg-muted text-[0.55rem] font-semibold text-muted-foreground',
            shape,
          )}
        >
          {initials(person.name)}
        </span>
      )}
    </a>
  )
}

const MAX_STACKED = 4

/** Overlapping avatars; anyone past the limit is counted in a "+N" chip that names them on hover. */
export function AvatarStack({ people, ring }: { people: Person[]; ring?: AvatarRing }) {
  const hidden = people.slice(MAX_STACKED)
  return (
    <span className="flex shrink-0 items-center -space-x-1.5">
      {people.slice(0, MAX_STACKED).map((person) => (
        <Avatar key={person.id} person={person} ring={ring} />
      ))}
      {hidden.length > 0 && (
        <PeopleHoverCard people={hidden}>
          <button
            type="button"
            className="relative flex size-5 items-center justify-center rounded-full bg-muted text-[0.6rem] text-muted-foreground ring-2 ring-card"
          >
            +{hidden.length}
          </button>
        </PeopleHoverCard>
      )}
    </span>
  )
}

/**
 * Names the people behind a "+N" on hover or keyboard focus, with their avatars. `children` is
 * the trigger and should be focusable (a button) so it works without a mouse.
 */
export function PeopleHoverCard({ people, title, children }: { people: Person[]; title?: string; children: ReactNode }) {
  return (
    <HoverCard.Root openDelay={150} closeDelay={100}>
      <HoverCard.Trigger asChild>{children}</HoverCard.Trigger>
      <HoverCard.Portal>
        <HoverCard.Content
          side="bottom"
          align="start"
          sideOffset={6}
          collisionPadding={8}
          className="z-50 w-60 rounded-lg border border-border bg-popover p-2.5 text-xs text-popover-foreground shadow-md"
        >
          {title && <p className="mb-2 text-faint">{title}</p>}
          <ul className="flex flex-col gap-1.5">
            {people.map((person) => (
              <li key={person.id} className="flex min-w-0 items-center gap-2">
                <Avatar person={person} className="size-5 ring-0" />
                <a href={person.url} target="_blank" rel="noreferrer" className="truncate hover:underline">
                  {person.name}
                </a>
                {person.kind === 'team' && <span className="ml-auto shrink-0 text-faint">team</span>}
              </li>
            ))}
          </ul>
        </HoverCard.Content>
      </HoverCard.Portal>
    </HoverCard.Root>
  )
}

