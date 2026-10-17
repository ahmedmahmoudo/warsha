import { Link } from '@tanstack/react-router'
import type { MeetingsTodayResponse } from '../../../shared/calendar'
import { BothZones, JoinButton, MeetingChangeRow, MeetingTitle } from '../calendar/MeetingBits'
import { Panel } from '../Panel'

/** Rescheduled and deleted meetings, whatever day they're on, until you dismiss them. */
export function MeetingChangesSection({ data }: { data: MeetingsTodayResponse }) {
  if (data.changes.length === 0) return null
  return (
    <Panel title="Meeting changes" aside={`${data.changes.length} changed`}>
      <ul className="flex flex-col divide-y divide-border">
        {data.changes.map((meeting) => (
          <MeetingChangeRow key={meeting.id} meeting={meeting} homeZone={data.timeZone} />
        ))}
      </ul>
    </Panel>
  )
}

export function MeetingsTodaySection({ data, error }: { data: MeetingsTodayResponse | undefined; error: Error | null }) {
  if (data && data.connection !== 'connected')
    return (
      <Panel title="Meetings today">
        <p className="text-sm text-muted-foreground">
          <Link to="/settings" search={{}} className="underline">
            Connect Google Calendar
          </Link>{' '}
          to see your meetings here.
        </p>
      </Panel>
    )
  const now = new Date().toISOString()
  return (
    <Panel title="Meetings today" aside={data && `${data.today.length || 'None'}`}>
      {error && <p className="text-sm text-bad">{error.message}</p>}
      {data?.error && <p className="mb-2 text-xs text-warn">Google sync failed: {data.error}</p>}
      {!data && !error && <p className="text-sm text-muted-foreground">Checking your calendar…</p>}
      {data && data.today.length === 0 && <p className="text-sm text-muted-foreground">No meetings today.</p>}
      {data && data.today.length > 0 && (
        <ul className="flex flex-col gap-2.5">
          {data.today.map((meeting) => {
            const over = !meeting.allDay && meeting.end <= now
            const live = !meeting.allDay && meeting.start <= now && now < meeting.end
            return (
              <li key={meeting.id} className={`flex min-w-0 items-start gap-2 text-sm ${over ? 'opacity-55' : ''}`}>
                <span className={`mt-1 h-8 w-0.5 shrink-0 rounded-full ${live ? 'bg-good' : 'bg-primary/40'}`} />
                <div className="flex min-w-0 flex-1 flex-col">
                  <div className="flex min-w-0 items-center gap-1.5">
                    <MeetingTitle meeting={meeting} className="font-medium" />
                    {live && <span className="shrink-0 rounded bg-good-soft px-1 text-[0.65rem] font-medium text-good">Now</span>}
                    {meeting.change?.kind === 'rescheduled' && (
                      <span className="shrink-0 rounded bg-warn-soft px-1 text-[0.65rem] font-medium text-warn">Moved</span>
                    )}
                    {meeting.declined && <span className="shrink-0 text-[0.65rem] text-faint">Declined</span>}
                  </div>
                  <span className="text-xs text-muted-foreground">
                    <BothZones meeting={meeting} homeZone={data.timeZone} />
                  </span>
                </div>
                {!over && <JoinButton meeting={meeting} />}
              </li>
            )
          })}
        </ul>
      )}
    </Panel>
  )
}
