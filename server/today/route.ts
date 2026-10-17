import { Hono } from 'hono'
import type { TodayResponse } from '../../shared/today'
import { env } from '../env'
import { IntegrationNotConfigured } from '../integrations/errors'
import { cacheOptions } from '../lib/cacheParams'
import { createSwrCache } from '../lib/swrCache'
import { settings } from '../store/repo'
import { buildToday } from './build'

const STALE_AFTER_MS = 30_000
const LAST_SEEN = 'today.lastSeenAt'

const cache = createSwrCache({ load: buildToday, staleAfterMs: STALE_AFTER_MS })

export const todayRoute = new Hono()
  .get('/', async (c) => {
    try {
      const today = await cache.get(env.timeZone, cacheOptions((name) => c.req.query(name)))
      // Read fresh each time: marking as seen shouldn't wait for GitHub and Linear.
      return c.json<TodayResponse>({ ...today, lastSeenAt: settings.get(LAST_SEEN) })
    } catch (error) {
      if (error instanceof IntegrationNotConfigured) return c.json({ error: error.message, setup: true }, 503)
      throw error
    }
  })
  .post('/seen', (c) => {
    const at = new Date().toISOString()
    settings.set(LAST_SEEN, at)
    return c.json({ lastSeenAt: at })
  })
