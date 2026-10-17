import { Hono } from 'hono'
import type { ActivityResponse } from '../../shared/activity'
import { env } from '../env'
import { IntegrationNotConfigured } from '../integrations/errors'
import { getViewerLogin } from '../integrations/github'
import { cacheOptions } from '../lib/cacheParams'
import { createSwrCache } from '../lib/swrCache'
import { buildActivity } from './build'
import { isDate, isTimeZone, localDate, rangeOf, type ActivityView } from './week'

/** The current range moves; past ones barely do (late reviews, ticket moves). */
const CURRENT_WEEK_STALE_MS = 60_000
const PAST_WEEK_STALE_MS = 15 * 60_000

let viewerLogin: string | null = null
const VIEWS: readonly ActivityView[] = ['day', 'week', 'month']

/** Key is "zone|view|start"; ranges holding today go stale quickly, older ones rarely change. */
async function loadRange(key: string): Promise<ActivityResponse> {
  const [timeZone, view, start] = key.split('|') as [string, ActivityView, string]
  viewerLogin ??= await getViewerLogin()
  return buildActivity(viewerLogin, rangeOf(view, start, timeZone))
}
const currentRanges = createSwrCache<string, ActivityResponse>({ load: loadRange, staleAfterMs: CURRENT_WEEK_STALE_MS })
const pastRanges = createSwrCache<string, ActivityResponse>({ load: loadRange, staleAfterMs: PAST_WEEK_STALE_MS })

export const activityRoute = new Hono().get('/', async (c) => {
  const timeZone = c.req.query('tz') ?? env.timeZone
  if (!isTimeZone(timeZone)) return c.json({ error: `Unknown time zone "${timeZone}"` }, 400)
  const view = (c.req.query('view') ?? 'week') as ActivityView
  if (!VIEWS.includes(view)) return c.json({ error: 'view must be day, week or month' }, 400)
  const date = c.req.query('date') ?? c.req.query('week') ?? localDate(new Date(), timeZone)
  if (!isDate(date)) return c.json({ error: 'date must be YYYY-MM-DD' }, 400)

  const range = rangeOf(view, date, timeZone)
  if (range.from.getTime() > Date.now()) return c.json({ error: "That hasn't happened yet" }, 400)

  try {
    const cache = range.isCurrent ? currentRanges : pastRanges
    return c.json(await cache.get(`${timeZone}|${view}|${range.start}`, cacheOptions((name) => c.req.query(name))))
  } catch (error) {
    if (error instanceof IntegrationNotConfigured) return c.json({ error: error.message, setup: true }, 503)
    throw error
  }
})
