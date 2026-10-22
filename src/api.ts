import type { ActivityResponse, ActivityView } from '../shared/activity'
import type { CalendarRangeResponse, MeetingsTodayResponse } from '../shared/calendar'
import type { GoogleStatus } from '../shared/google'
import type { PrChecksResponse, PrDetail } from '../shared/prDetail'
import type { PrScope, PrsResponse } from '../shared/prs'
import type { TodayResponse } from '../shared/today'

/**
 * How old an answer pages accept, in seconds. The server keeps copies to stay quick; asking for
 * a recent one means opening a page (or coming back to the window) shows what you just changed.
 */
const MAX_AGE_SECONDS = 15

/** `fresh` rebuilds now (the Refresh buttons); otherwise take anything recent. */
const freshness = (fresh: boolean) => (fresh ? 'fresh=1' : `maxAge=${MAX_AGE_SECONDS}`)

export class ApiError extends Error {
  constructor(
    message: string,
    readonly setup: boolean,
  ) {
    super(message)
  }
}

export async function fetchPrs(scope: PrScope, fresh = false): Promise<PrsResponse> {
  const response = await fetch(`/api/prs?scope=${scope}&${freshness(fresh)}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string; setup?: boolean }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, body.setup ?? false)
  }
  return response.json() as Promise<PrsResponse>
}

export async function fetchPrDetail(repo: string, number: number, fresh = false): Promise<PrDetail> {
  const response = await fetch(`/api/prs/${repo}/${number}?${freshness(fresh)}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string; setup?: boolean }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, body.setup ?? false)
  }
  return response.json() as Promise<PrDetail>
}

/** Runs one of a PR's actions; the header proves the request came from this app. */
export async function runPrAction(
  repo: string,
  number: number,
  action: 'update-branch' | 'resolve-conflicts',
  body: Record<string, string> = {},
): Promise<{ ok: true; path?: string; settled?: boolean }> {
  const response = await fetch(`/api/prs/${repo}/${number}/${action}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-warsha-action': '1' },
    body: JSON.stringify(body),
  })
  const result = (await response.json().catch(() => ({}))) as { error?: string; ok?: true; path?: string; settled?: boolean }
  if (!response.ok) throw new ApiError(result.error ?? `Request failed (${response.status})`, false)
  return { ok: true, path: result.path, settled: result.settled }
}

export async function fetchPrChecks(repo: string, number: number): Promise<PrChecksResponse> {
  const response = await fetch(`/api/prs/${repo}/${number}/checks`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, false)
  }
  return response.json() as Promise<PrChecksResponse>
}

export async function fetchActivity(
  { view, date, timeZone }: { view: ActivityView; date: string; timeZone: string },
  fresh = false,
): Promise<ActivityResponse> {
  const params = new URLSearchParams({ view, date, tz: timeZone })
  const response = await fetch(`/api/activity?${params}&${freshness(fresh)}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string; setup?: boolean }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, body.setup ?? false)
  }
  return response.json() as Promise<ActivityResponse>
}

export async function fetchToday(fresh = false): Promise<TodayResponse> {
  const response = await fetch(`/api/today?${freshness(fresh)}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string; setup?: boolean }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, body.setup ?? false)
  }
  return response.json() as Promise<TodayResponse>
}

export async function markTodaySeen(): Promise<{ lastSeenAt: string }> {
  const response = await fetch('/api/today/seen', { method: 'POST', headers: { 'x-warsha-action': '1' } })
  if (!response.ok) throw new ApiError(`Couldn't mark as seen (${response.status})`, false)
  return response.json() as Promise<{ lastSeenAt: string }>
}

export async function fetchGoogleStatus(): Promise<GoogleStatus> {
  const response = await fetch('/api/google/status')
  if (!response.ok) throw new ApiError(`Couldn't check Google (${response.status})`, false)
  return response.json() as Promise<GoogleStatus>
}

export async function disconnectGoogle(): Promise<void> {
  const response = await fetch('/api/google/disconnect', { method: 'POST', headers: { 'x-warsha-action': '1' } })
  if (!response.ok) throw new ApiError(`Couldn't disconnect Google (${response.status})`, false)
}

export async function fetchMeetingsToday(fresh = false): Promise<MeetingsTodayResponse> {
  const response = await fetch(`/api/calendar/today${fresh ? '?fresh=1' : ''}`)
  if (!response.ok) throw new ApiError(`Couldn't load meetings (${response.status})`, false)
  return response.json() as Promise<MeetingsTodayResponse>
}

/** Meetings overlapping [start, end), both UTC ISO instants. */
export async function fetchCalendarRange(start: string, end: string, fresh = false): Promise<CalendarRangeResponse> {
  const params = new URLSearchParams({ start, end })
  if (fresh) params.set('fresh', '1')
  const response = await fetch(`/api/calendar/range?${params}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string }
    throw new ApiError(body.error ?? `Couldn't load the calendar (${response.status})`, false)
  }
  return response.json() as Promise<CalendarRangeResponse>
}

export async function dismissMeetingChange(id: string): Promise<void> {
  const response = await fetch(`/api/calendar/changes/${encodeURIComponent(id)}/dismiss`, { method: 'POST', headers: { 'x-warsha-action': '1' } })
  if (!response.ok) throw new ApiError(`Couldn't dismiss (${response.status})`, false)
}
