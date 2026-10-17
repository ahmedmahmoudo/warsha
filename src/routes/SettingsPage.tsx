import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useSearch } from '@tanstack/react-router'
import { CalendarDays, Monitor, Moon, Sun } from 'lucide-react'
import { Button, buttonVariants } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { useTheme } from '@/theme/ThemeProvider'
import type { ThemePreference } from '@/theme/theme'
import { disconnectGoogle, fetchGoogleStatus } from '../api'
import type { CalendarEvent } from '../../shared/google'

const THEME_OPTIONS: { value: ThemePreference; label: string; icon: typeof Sun }[] = [
  { value: 'light', label: 'Light', icon: Sun },
  { value: 'dark', label: 'Dark', icon: Moon },
  { value: 'system', label: 'System', icon: Monitor },
]

function isThemePreference(value: string): value is ThemePreference {
  return THEME_OPTIONS.some((option) => option.value === value)
}

export function SettingsPage() {
  const { preference, resolved, setPreference } = useTheme()

  return (
    <div className="flex max-w-2xl flex-col gap-4">
      <h1 className="text-lg font-semibold">Settings</h1>
      <Card>
        <CardHeader>
          <CardTitle>Appearance</CardTitle>
          <CardDescription>
            System follows your device and switches the moment macOS does.
            {preference === 'system' && ` Currently ${resolved}.`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ToggleGroup
            type="single"
            variant="outline"
            spacing={0}
            value={preference}
            onValueChange={(value) => {
              // Radix sends "" when the active item is clicked again; keep the current choice.
              if (isThemePreference(value)) setPreference(value)
            }}
            aria-label="Theme"
          >
            {THEME_OPTIONS.map(({ value, label, icon: Icon }) => (
              <ToggleGroupItem key={value} value={value} className="px-3">
                <Icon />
                {label}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </CardContent>
      </Card>
      <GoogleCard />
    </div>
  )
}

const eventTime = new Intl.DateTimeFormat('en-AU', { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })
const eventDay = new Intl.DateTimeFormat('en-AU', { weekday: 'short', day: 'numeric', month: 'short' })

function whenLabel(event: CalendarEvent): string {
  // All-day dates are calendar days, not instants: read them at local midnight.
  return event.allDay ? `${eventDay.format(new Date(`${event.start}T00:00`))} · all day` : eventTime.format(new Date(event.start))
}

function GoogleCard() {
  const queryClient = useQueryClient()
  const { google: result } = useSearch({ from: '/settings' })
  const status = useQuery({ queryKey: ['google-status'], queryFn: fetchGoogleStatus })
  const disconnect = useMutation({
    mutationFn: disconnectGoogle,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['google-status'] }),
  })
  const data = status.data

  return (
    <Card>
      <CardHeader>
        <CardTitle>Google Calendar</CardTitle>
        <CardDescription>
          Read-only access to your calendar, for upcoming meetings and what changed in them.
          {data?.state === 'connected' && data.email && ` Connected as ${data.email}.`}
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-3 text-sm">
        {result && result !== 'connected' && <p className="text-destructive">{result}</p>}
        {status.isPending && <p className="text-muted-foreground">Checking…</p>}
        {status.isError && <p className="text-destructive">{status.error.message}</p>}
        {data?.state === 'unconfigured' && (
          <p className="text-muted-foreground">
            Add <code>GOOGLE_CLIENT_ID</code> and <code>GOOGLE_CLIENT_SECRET</code> to <code>.env.local</code> and restart the server.
          </p>
        )}
        {data?.state === 'disconnected' && (
          <a href="/api/google/connect" className={buttonVariants({ className: 'self-start' })}>
            <CalendarDays />
            Connect Google account
          </a>
        )}
        {data?.state === 'connected' && (
          <>
            {data.error ? (
              <p className="text-destructive">{data.error}</p>
            ) : data.events.length === 0 ? (
              <p className="text-muted-foreground">Connected. No upcoming meetings.</p>
            ) : (
              <ul className="flex flex-col gap-1.5">
                {data.events.map((event) => (
                  <li key={event.id} className="flex gap-3">
                    <span className="w-40 shrink-0 text-muted-foreground tabular-nums">{whenLabel(event)}</span>
                    {event.url ? (
                      <a href={event.url} target="_blank" rel="noreferrer" className="truncate hover:underline">
                        {event.title}
                      </a>
                    ) : (
                      <span className="truncate">{event.title}</span>
                    )}
                  </li>
                ))}
              </ul>
            )}
            <Button variant="outline" size="sm" className="self-start" disabled={disconnect.isPending} onClick={() => disconnect.mutate()}>
              Disconnect
            </Button>
          </>
        )}
      </CardContent>
    </Card>
  )
}
