import { createHash, randomBytes } from 'node:crypto'
import type { CalendarEvent } from '../../shared/google'
import { env } from '../env'
import { meetings, settings } from '../store/repo'
import { IntegrationNotConfigured } from './errors'

/**
 * Google Calendar through OAuth with a Desktop client: Google accepts any localhost port as the
 * redirect, so nothing is registered per port. The refresh token lives in Workbench's own
 * (gitignored) database; access tokens are kept in memory only.
 */

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
const TOKEN_URL = 'https://oauth2.googleapis.com/token'
const REVOKE_URL = 'https://oauth2.googleapis.com/revoke'
const CALENDAR_API = 'https://www.googleapis.com/calendar/v3'
const SCOPES = ['openid', 'email', 'https://www.googleapis.com/auth/calendar.readonly']

const REFRESH_TOKEN = 'google.refreshToken'
const EMAIL = 'google.email'

/** A sign-in started here and not finished yet, keyed by its `state`. */
const pending = new Map<string, { verifier: string; redirectUri: string; expiresAt: number }>()
const PENDING_MS = 10 * 60_000

let accessToken: { value: string; expiresAt: number } | null = null

export class GoogleAuthError extends Error {}

function client(): { id: string; secret: string } {
  if (!env.googleClientId || !env.googleClientSecret)
    throw new IntegrationNotConfigured('GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are not set in .env.local')
  return { id: env.googleClientId, secret: env.googleClientSecret }
}

export const googleConfigured = () => Boolean(env.googleClientId && env.googleClientSecret)
export const googleAccount = () => (settings.get(REFRESH_TOKEN) ? { email: settings.get(EMAIL) } : null)

/** Where to send the browser to sign in; it comes back to `redirectUri` with a code (PKCE-protected). */
export function authorizationUrl(redirectUri: string): string {
  const { id } = client()
  const now = Date.now()
  for (const [key, value] of pending) if (value.expiresAt < now) pending.delete(key)

  const state = randomBytes(16).toString('base64url')
  const verifier = randomBytes(32).toString('base64url')
  pending.set(state, { verifier, redirectUri, expiresAt: now + PENDING_MS })

  const params = new URLSearchParams({
    client_id: id,
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: SCOPES.join(' '),
    state,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'),
    code_challenge_method: 'S256',
    // Offline + consent so Google always hands back a refresh token, even when reconnecting.
    access_type: 'offline',
    prompt: 'consent',
    include_granted_scopes: 'true',
  })
  return `${AUTH_URL}?${params}`
}

/** Finishes a sign-in: trades the code for tokens and keeps the refresh token. */
export async function completeSignIn(code: string, state: string): Promise<void> {
  const started = pending.get(state)
  pending.delete(state)
  if (!started || started.expiresAt < Date.now()) throw new GoogleAuthError('This sign-in expired or was not started here. Try connecting again.')

  const { id, secret } = client()
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    body: new URLSearchParams({
      client_id: id,
      client_secret: secret,
      code,
      code_verifier: started.verifier,
      grant_type: 'authorization_code',
      redirect_uri: started.redirectUri,
    }),
  })
  const tokens = (await response.json()) as {
    access_token?: string
    expires_in?: number
    refresh_token?: string
    id_token?: string
    scope?: string
    error_description?: string
  }
  if (!response.ok || !tokens.access_token) throw new GoogleAuthError(`Google refused the sign-in: ${tokens.error_description ?? response.status}`)
  if (!tokens.refresh_token) throw new GoogleAuthError('Google sent no refresh token. Remove Workbench from your Google account access and connect again.')
  if (!tokens.scope?.includes('calendar.readonly')) throw new GoogleAuthError('Calendar access was not granted. Connect again and tick the calendar permission.')

  settings.set(REFRESH_TOKEN, tokens.refresh_token)
  const email = tokens.id_token ? emailFromIdToken(tokens.id_token) : null
  if (email) settings.set(EMAIL, email)
  else settings.remove(EMAIL)
  accessToken = { value: tokens.access_token, expiresAt: Date.now() + (tokens.expires_in ?? 0) * 1000 }
}

/** The ID token came straight from Google's token endpoint over TLS, so its claims are read without verifying the signature. */
function emailFromIdToken(idToken: string): string | null {
  try {
    const claims = JSON.parse(Buffer.from(idToken.split('.')[1] ?? '', 'base64url').toString()) as { email?: string }
    return claims.email ?? null
  } catch {
    return null
  }
}

/** Forgets the account here and revokes Workbench's access at Google. */
export async function disconnect(): Promise<void> {
  const token = settings.get(REFRESH_TOKEN)
  settings.remove(REFRESH_TOKEN)
  settings.remove(EMAIL)
  // Another account's meetings would all look deleted; start over on the next connect.
  meetings.clear()
  accessToken = null
  if (token) await fetch(REVOKE_URL, { method: 'POST', body: new URLSearchParams({ token }) }).catch(() => undefined)
}

async function validAccessToken(): Promise<string> {
  if (accessToken && accessToken.expiresAt - 60_000 > Date.now()) return accessToken.value
  const refreshToken = settings.get(REFRESH_TOKEN)
  if (!refreshToken) throw new IntegrationNotConfigured('Google is not connected. Connect it from Settings.')

  const { id, secret } = client()
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    body: new URLSearchParams({ client_id: id, client_secret: secret, refresh_token: refreshToken, grant_type: 'refresh_token' }),
  })
  const tokens = (await response.json()) as { access_token?: string; expires_in?: number; error?: string }
  if (tokens.error === 'invalid_grant') {
    // Revoked, expired or the password changed: the stored token is useless now.
    settings.remove(REFRESH_TOKEN)
    settings.remove(EMAIL)
    throw new IntegrationNotConfigured('Google access was revoked or expired. Connect it again from Settings.')
  }
  if (!response.ok || !tokens.access_token) throw new Error(`Google token refresh failed (${response.status})`)
  accessToken = { value: tokens.access_token, expiresAt: Date.now() + (tokens.expires_in ?? 0) * 1000 }
  return accessToken.value
}

type RawEvent = {
  id: string
  status?: 'confirmed' | 'tentative' | 'cancelled'
  summary?: string
  htmlLink?: string
  location?: string
  description?: string
  hangoutLink?: string
  conferenceData?: { entryPoints?: { entryPointType?: string; uri?: string }[] }
  attendees?: { self?: boolean; responseStatus?: string }[]
  start?: { dateTime?: string; date?: string }
  end?: { dateTime?: string; date?: string }
}

/** A Google event as Workbench keeps it: timed events in UTC ISO, all-day ones as YYYY-MM-DD (end exclusive). */
export type GoogleEvent = {
  id: string
  cancelled: boolean
  title: string
  start: string
  end: string
  allDay: boolean
  joinUrl: string | null
  htmlUrl: string | null
  location: string | null
  /** Your answer to the invite; null when you organised it or aren't listed. */
  response: string | null
}

const MEETING_LINK = /https:\/\/[^\s"'<>]*(?:zoom\.us\/j|meet\.google\.com|teams\.microsoft\.com\/l\/meetup-join|teams\.live\.com)[^\s"'<>]*/i

/** The video link: the conference attached to the event, else a Zoom/Meet/Teams link in the location or description. */
function joinUrlOf(event: RawEvent): string | null {
  const video = event.conferenceData?.entryPoints?.find((entry) => entry.entryPointType === 'video')?.uri
  return video ?? event.hangoutLink ?? `${event.location ?? ''} ${event.description ?? ''}`.match(MEETING_LINK)?.[0] ?? null
}

const instant = (time: { dateTime?: string; date?: string } | undefined) =>
  time?.dateTime ? new Date(time.dateTime).toISOString() : (time?.date ?? '')

function toGoogleEvent(event: RawEvent): GoogleEvent {
  return {
    id: event.id,
    cancelled: event.status === 'cancelled',
    title: event.summary ?? '(No title)',
    start: instant(event.start),
    end: instant(event.end),
    allDay: Boolean(event.start?.date && !event.start.dateTime),
    joinUrl: joinUrlOf(event),
    htmlUrl: event.htmlLink ?? null,
    location: event.location ?? null,
    response: event.attendees?.find((attendee) => attendee.self)?.responseStatus ?? null,
  }
}

async function calendarGet(path: string): Promise<Response> {
  return fetch(`${CALENDAR_API}/calendars/primary/${path}`, { headers: { authorization: `Bearer ${await validAccessToken()}` } })
}

async function failure(response: Response): Promise<Error> {
  const body = (await response.json().catch(() => ({}))) as { error?: { message?: string } }
  return new Error(`Google Calendar ${response.status}: ${body.error?.message ?? response.statusText}`)
}

/**
 * Every event between two instants on your primary calendar, recurring ones expanded.
 * `showDeleted` also returns cancelled ones, which is how a deletion is told apart from a move.
 */
export async function listEvents({ timeMin, timeMax, showDeleted = false }: { timeMin: string; timeMax: string; showDeleted?: boolean }): Promise<GoogleEvent[]> {
  const events: GoogleEvent[] = []
  let pageToken: string | undefined
  do {
    const params = new URLSearchParams({ timeMin, timeMax, singleEvents: 'true', orderBy: 'startTime', maxResults: '2500', showDeleted: String(showDeleted) })
    if (pageToken) params.set('pageToken', pageToken)
    const response = await calendarGet(`events?${params}`)
    if (!response.ok) throw await failure(response)
    const page = (await response.json()) as { items?: RawEvent[]; nextPageToken?: string }
    events.push(...(page.items ?? []).map(toGoogleEvent))
    pageToken = page.nextPageToken
  } while (pageToken)
  return events
}

/** One event by ID; null when Google no longer has it. */
export async function getEvent(id: string): Promise<GoogleEvent | null> {
  const response = await calendarGet(`events/${encodeURIComponent(id)}`)
  if (response.status === 404 || response.status === 410) return null
  if (!response.ok) throw await failure(response)
  return toGoogleEvent((await response.json()) as RawEvent)
}

/** The next few meetings on your primary calendar, recurring ones expanded. */
export async function upcomingEvents(limit: number): Promise<CalendarEvent[]> {
  const params = new URLSearchParams({
    timeMin: new Date().toISOString(),
    maxResults: String(limit),
    singleEvents: 'true',
    orderBy: 'startTime',
  })
  const response = await calendarGet(`events?${params}`)
  if (!response.ok) throw await failure(response)
  const { items = [] } = (await response.json()) as { items?: RawEvent[] }
  return items.map(toGoogleEvent).map(({ id, title, start, end, allDay, htmlUrl }) => ({ id, title, start, end, allDay, url: htmlUrl }))
}
