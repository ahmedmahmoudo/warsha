import './env'
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import { Hono } from 'hono'
import { API_PORT } from '../shared/ports'
import { prsRoute } from './prs/route'

const app = new Hono()

app.route('/api/prs', prsRoute)
app.onError((error, c) => {
  console.error(error)
  return c.json({ error: error.message }, 500)
})

if (process.env.NODE_ENV === 'production') {
  app.use('/*', serveStatic({ root: './dist' }))
  app.get('*', serveStatic({ path: './dist/index.html' }))
}

serve({ fetch: app.fetch, port: API_PORT }, ({ port }) => console.log(`API on http://localhost:${port}`))
