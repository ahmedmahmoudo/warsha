import './env'
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import { Hono } from 'hono'
import { activityRoute } from './activity/route'
import { calendarRoute } from './calendar/route'
import { env } from './env'
import { syncMeetings } from './calendar/sync'
import { googleRoute } from './google/route'
import { imagesRoute } from './images/route'
import { prsRoute } from './prs/route'
import { storeRoute } from './store/route'
import { todayRoute } from './today/route'

const app = new Hono()

/**
 * Every write needs a header a page on another site can't send without a CORS preflight, which
 * this server never approves, so only Warsha's own pages can change things.
 */
app.use('/api/*', async (c, next) => {
  if (c.req.method !== 'GET' && c.req.method !== 'HEAD' && c.req.header('x-warsha-action') !== '1')
    return c.json({ error: 'Missing x-warsha-action header' }, 403)
  await next()
})

app.route('/api/prs', prsRoute)
app.route('/api/store', storeRoute)
app.route('/api/today', todayRoute)
app.route('/api/activity', activityRoute)
app.route('/api/github-image', imagesRoute)
app.route('/api/google', googleRoute)
app.route('/api/calendar', calendarRoute)
app.onError((error, c) => {
  console.error(error)
  return c.json({ error: error.message }, 500)
})

if (process.env.NODE_ENV === 'production') {
  app.use('/*', serveStatic({ root: './dist' }))
  app.get('*', serveStatic({ path: './dist/index.html' }))
}

// Locally the API can open Terminal and act with your token, so it only listens on this machine.
const hostname = env.local ? '127.0.0.1' : undefined
serve({ fetch: app.fetch, port: env.port, hostname }, ({ port }) => {
  console.log(`API on http://localhost:${port}`)
  // Catch up on what changed in your calendar while Warsha was closed.
  void syncMeetings()
})
