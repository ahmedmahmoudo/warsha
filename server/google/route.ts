import { Hono } from 'hono'
import type { GoogleStatus } from '../../shared/google'
import { API_PORT, WEB_PORT } from '../../shared/ports'
import { syncMeetings } from '../calendar/sync'
import { IntegrationNotConfigured } from '../integrations/errors'
import {
  authorizationUrl,
  completeSignIn,
  disconnect,
  googleAccount,
  googleConfigured,
  GoogleAuthError,
  upcomingEvents,
} from '../integrations/google'

const UPCOMING = 5

/**
 * Where Google sends the browser back: the page you're using, not this server, since in development
 * Vite serves the pages and proxies /api here. A Desktop client allows any localhost port.
 */
const REDIRECT_URI = `http://localhost:${process.env.NODE_ENV === 'production' ? API_PORT : WEB_PORT}/api/google/callback`

/** Back to Settings, with how the sign-in went in the query string. */
const backToSettings = (result: string) => `/settings?${new URLSearchParams({ google: result })}`

export const googleRoute = new Hono()
  .get('/status', async (c) => {
    if (!googleConfigured()) return c.json<GoogleStatus>({ state: 'unconfigured' })
    const account = googleAccount()
    if (!account) return c.json<GoogleStatus>({ state: 'disconnected' })
    try {
      return c.json<GoogleStatus>({ state: 'connected', email: account.email, events: await upcomingEvents(UPCOMING), error: null })
    } catch (error) {
      if (error instanceof IntegrationNotConfigured && !googleAccount()) return c.json<GoogleStatus>({ state: 'disconnected' })
      return c.json<GoogleStatus>({ state: 'connected', email: account.email, events: [], error: (error as Error).message })
    }
  })
  // A plain link from Settings, so the browser itself goes to Google and back.
  .get('/connect', (c) => {
    try {
      return c.redirect(authorizationUrl(REDIRECT_URI))
    } catch (error) {
      if (error instanceof IntegrationNotConfigured) return c.redirect(backToSettings(error.message))
      throw error
    }
  })
  .get('/callback', async (c) => {
    const { code, state, error } = c.req.query()
    if (error) return c.redirect(backToSettings(error === 'access_denied' ? 'You cancelled the Google sign-in.' : `Google returned: ${error}`))
    if (!code || !state) return c.redirect(backToSettings('Google sent back an incomplete sign-in.'))
    try {
      await completeSignIn(code, state)
      // The first sync saves what's on your calendar now: the baseline later changes are measured from.
      void syncMeetings({ force: true })
      return c.redirect(backToSettings('connected'))
    } catch (failure) {
      if (failure instanceof GoogleAuthError || failure instanceof IntegrationNotConfigured) return c.redirect(backToSettings(failure.message))
      throw failure
    }
  })
  .post('/disconnect', async (c) => {
    await disconnect()
    return c.json({ ok: true })
  })
