import { useMutation, useQueryClient } from '@tanstack/react-query'
import { CalendarX2, History, Video, X } from 'lucide-react'
import type { Meeting } from '../../../shared/calendar'
import { buttonVariants } from '@/components/ui/button'
import { dismissMeetingChange } from '../../api'
import { timeAgo } from '../../format'
import { city, localZone, timeRange } from './time'

/**
 * A meeting's time in the home zone (TIMEZONE, Sydney) and in your browser's zone. When the two
 * read the same, it says so instead of repeating itself.
 */
export function BothZones({ meeting, homeZone, withDay = false }: { meeting: Pick<Meeting, 'start' | 'end' | 'allDay'>; homeZone: string; withDay?: boolean }) {
  const home = timeRange(meeting, homeZone, withDay)
  if (meeting.allDay) return <span>{home}</span>
  const local = timeRange(meeting, localZone, withDay)
  if (local === home)
    return (
      <span>
        {home} <span className="text-faint">{city(homeZone)}{localZone === homeZone ? '' : ' · same for you'}</span>
      </span>
    )
  return (
    <span>
      {home} <span className="text-faint">{city(homeZone)}</span>
      <span className="text-faint"> · </span>
      {local} <span className="text-faint">your time ({city(localZone)})</span>
    </span>
  )
}

export function JoinButton({ meeting }: { meeting: Meeting }) {
  if (!meeting.joinUrl || meeting.change?.kind === 'deleted') return null
  return (
    <a href={meeting.joinUrl} target="_blank" rel="noreferrer" className={buttonVariants({ size: 'xs', className: 'shrink-0' })}>
      <Video />
      Join
    </a>
  )
}

export function MeetingTitle({ meeting, className = '' }: { meeting: Meeting; className?: string }) {
  const deleted = meeting.change?.kind === 'deleted'
  const classes = `min-w-0 truncate ${deleted ? 'line-through text-muted-foreground' : ''} ${meeting.declined ? 'text-muted-foreground' : ''} ${className}`
  return meeting.htmlUrl && !deleted ? (
    <a href={meeting.htmlUrl} target="_blank" rel="noreferrer" title={meeting.title} className={`${classes} hover:underline`}>
      {meeting.title}
    </a>
  ) : (
    <span title={meeting.title} className={classes}>
      {meeting.title}
    </span>
  )
}

export function useDismissChange() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: dismissMeetingChange,
    onSuccess: () => Promise.all([queryClient.invalidateQueries({ queryKey: ['meetings-today'] }), queryClient.invalidateQueries({ queryKey: ['calendar'] })]),
  })
}

/** A rescheduled or deleted meeting: what it is now, what it was, and a way to dismiss the notice. */
export function MeetingChangeRow({ meeting, homeZone }: { meeting: Meeting; homeZone: string }) {
  const dismiss = useDismissChange()
  const change = meeting.change
  if (!change) return null
  const deleted = change.kind === 'deleted'
  return (
    <li className="flex min-w-0 gap-3 py-2 text-sm first:pt-0 last:pb-0">
      {deleted ? <CalendarX2 className="mt-0.5 size-4 shrink-0 text-bad" /> : <History className="mt-0.5 size-4 shrink-0 text-warn" />}
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <div className="flex min-w-0 items-center gap-2">
          <MeetingTitle meeting={meeting} className="font-medium" />
          <span className={`shrink-0 rounded px-1.5 py-0.5 text-[0.65rem] font-medium ${deleted ? 'bg-bad-soft text-bad' : 'bg-warn-soft text-warn'}`}>
            {deleted ? 'Deleted' : 'Rescheduled'}
          </span>
        </div>
        {deleted ? (
          <p className="text-xs text-muted-foreground">
            Was <BothZones meeting={meeting} homeZone={homeZone} withDay /> · removed {timeAgo(change.at)}
          </p>
        ) : (
          <>
            <p className="text-xs">
              <span className="text-muted-foreground">Now </span>
              <BothZones meeting={meeting} homeZone={homeZone} withDay />
            </p>
            <p className="text-xs text-muted-foreground">
              Was <span className="line-through">{timeRange({ start: change.previousStart, end: change.previousEnd, allDay: meeting.allDay }, homeZone, true)}</span>
              {' · '}moved {timeAgo(change.at)}
            </p>
          </>
        )}
      </div>
      <div className="flex shrink-0 items-start gap-1">
        <JoinButton meeting={meeting} />
        <button
          type="button"
          onClick={() => dismiss.mutate(meeting.id)}
          disabled={dismiss.isPending}
          aria-label="Dismiss"
          title={deleted ? 'Dismiss and forget this meeting' : 'Dismiss: the new time is noted'}
          className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-60"
        >
          <X className="size-3.5" />
        </button>
      </div>
    </li>
  )
}
