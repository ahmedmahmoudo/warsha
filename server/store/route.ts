import { Hono } from 'hono'
import { parkComment, type ParkResponse, type PostResult, type PostTarget, type StoreResponse } from '../../shared/store'
import { commentOnPr } from '../integrations/github'
import { commentOnIssue } from '../integrations/linear'
import { notes, parked, pins, todos } from './repo'

const REF = /^(ticket:[A-Z][A-Z0-9]{1,9}-\d{1,7}|pr:[\w.-]+\/[\w.-]+#\d{1,7})$/
const DATE = /^\d{4}-\d{2}-\d{2}$/
const MAX_TEXT = 4000

function cleanText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() && value.length <= MAX_TEXT ? value : null
}

function cleanRef(value: unknown): string | null | undefined {
  if (value === null || value === undefined || value === '') return null
  return typeof value === 'string' && REF.test(value) ? value : undefined
}

function cleanDate(value: unknown): string | null | undefined {
  if (value === null || value === '') return null
  if (value === undefined) return undefined
  return typeof value === 'string' && DATE.test(value) ? value : undefined
}

const TICKET_KEY = /^[A-Z][A-Z0-9]{1,9}-\d{1,7}$/
const REPO = /^[\w.-]+\/[\w.-]+$/
const MAX_TARGETS = 5

/** Where to post a park reason; null when the list is malformed. */
function cleanTargets(value: unknown): PostTarget[] | null {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.length > MAX_TARGETS) return null
  const targets: PostTarget[] = []
  for (const target of value as Record<string, unknown>[]) {
    if (target?.kind === 'linear' && typeof target.key === 'string' && TICKET_KEY.test(target.key))
      targets.push({ kind: 'linear', key: target.key })
    else if (target?.kind === 'github' && typeof target.repo === 'string' && REPO.test(target.repo) && Number.isInteger(target.number))
      targets.push({ kind: 'github', repo: target.repo, number: target.number as number })
    else return null
  }
  return targets
}

type Body = Record<string, unknown>
const body = async (c: { req: { json: <T>() => Promise<T> } }): Promise<Body> => c.req.json<Body>().catch(() => ({}))

/** Pins, notes, todos and parked items: small, so the page loads them all at once. */
export const storeRoute = new Hono()
  .get('/', (c) => c.json<StoreResponse>({ pins: pins.list(), notes: notes.list(), todos: todos.list(), parked: parked.list() }))
  .post('/parked', async (c) => {
    const { ref, title, url, reason, until, postTo } = await body(c)
    const cleanedRef = cleanRef(ref)
    const cleanedTitle = cleanText(title)
    const cleanedUntil = until === undefined ? null : cleanDate(until)
    const cleanedReason = cleanText(reason)
    const targets = cleanTargets(postTo)
    if (targets === null) return c.json({ error: 'postTo must list Linear tickets or GitHub PRs' }, 400)
    if (!cleanedRef || !cleanedTitle || cleanedUntil === undefined) return c.json({ error: 'ref and title are required' }, 400)
    if (targets.length && !cleanedReason) return c.json({ error: 'Add a reason to post it' }, 400)

    const item = parked.add({
      ref: cleanedRef,
      title: cleanedTitle,
      url: typeof url === 'string' ? url : null,
      reason: cleanedReason,
      until: cleanedUntil,
    })
    // Parking is saved either way; each post reports how it went.
    const comment = cleanedReason ? parkComment(cleanedReason, cleanedUntil) : ''
    const posted = await Promise.all(
      targets.map(async (target): Promise<PostResult> => {
        const label = target.kind === 'linear' ? `Linear ${target.key}` : `PR #${target.number}`
        try {
          const link = target.kind === 'linear' ? await commentOnIssue(target.key, comment) : await commentOnPr(target.repo, target.number, comment)
          console.log(`[store] Posted the park reason to ${label}`)
          return { label, url: link, error: null }
        } catch (error) {
          console.error(`[store] Couldn't post to ${label}`, error)
          return { label, url: null, error: error instanceof Error ? error.message : String(error) }
        }
      }),
    )
    return c.json<ParkResponse>({ parked: item, posted })
  })
  .delete('/parked', (c) => {
    const ref = cleanRef(c.req.query('ref'))
    if (!ref) return c.json({ error: 'ref is required' }, 400)
    return c.json({ removed: parked.remove(ref) })
  })
  .post('/pins', async (c) => {
    const { ref, title, url } = await body(c)
    const cleanedRef = cleanRef(ref)
    const cleanedTitle = cleanText(title)
    if (!cleanedRef || !cleanedTitle) return c.json({ error: 'ref and title are required' }, 400)
    return c.json(pins.add({ ref: cleanedRef, title: cleanedTitle, url: typeof url === 'string' ? url : null }))
  })
  .delete('/pins', (c) => {
    const ref = cleanRef(c.req.query('ref'))
    if (!ref) return c.json({ error: 'ref is required' }, 400)
    return c.json({ removed: pins.remove(ref) })
  })
  .put('/notes', async (c) => {
    const { ref, body: text } = await body(c)
    const cleanedRef = cleanRef(ref)
    if (!cleanedRef || typeof text !== 'string' || text.length > MAX_TEXT) return c.json({ error: 'ref and body are required' }, 400)
    return c.json({ note: notes.set(cleanedRef, text) })
  })
  .post('/todos', async (c) => {
    const { text, ref, dueDate } = await body(c)
    const cleanedText = cleanText(text)
    const cleanedRef = cleanRef(ref)
    // Leaving the date out means no date; only a malformed one is an error.
    const cleanedDate = dueDate === undefined ? null : cleanDate(dueDate)
    if (!cleanedText || cleanedRef === undefined || cleanedDate === undefined) return c.json({ error: 'A todo needs text' }, 400)
    return c.json(todos.add({ text: cleanedText, ref: cleanedRef, dueDate: cleanedDate }))
  })
  .patch('/todos/:id', async (c) => {
    const id = Number(c.req.param('id'))
    const { text, done, dueDate } = await body(c)
    const cleanedDate = cleanDate(dueDate)
    if (!Number.isInteger(id) || (text !== undefined && !cleanText(text)) || (dueDate !== undefined && cleanedDate === undefined))
      return c.json({ error: 'Bad todo change' }, 400)
    const todo = todos.update(id, {
      text: typeof text === 'string' ? text : undefined,
      done: typeof done === 'boolean' ? done : undefined,
      dueDate: cleanedDate,
    })
    return todo ? c.json(todo) : c.json({ error: 'No such todo' }, 404)
  })
  .delete('/todos/:id', (c) => {
    const id = Number(c.req.param('id'))
    if (!Number.isInteger(id)) return c.json({ error: 'Bad id' }, 400)
    return c.json({ removed: todos.remove(id) })
  })
