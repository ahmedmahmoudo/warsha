import type { Ticket } from '../../shared/prs'
import { env } from '../env'
import { IntegrationNotConfigured } from './errors'

const LINEAR_GRAPHQL = 'https://api.linear.app/graphql'

type RawIssue = {
  identifier: string
  title: string
  url: string
  state: { name: string; type: string; color: string }
  assignee: { displayName: string } | null
  project: { name: string } | null
}

/**
 * Looks tickets up by key ("MX-2473") in one request, one alias per key. A key that
 * looks like a ticket but isn't one (a PR title mentioning "UTF-8") comes back as a
 * per-alias error, so partial data is expected and kept.
 */
export async function getTicketsByKey(keys: string[]): Promise<Map<string, Ticket>> {
  if (!env.linearApiKey) throw new IntegrationNotConfigured('LINEAR_API_KEY is not set in .env.local')
  const tickets = new Map<string, Ticket>()
  if (keys.length === 0) return tickets

  const variableDefs = keys.map((_, i) => `$k${i}: String!`).join(', ')
  const selections = keys
    .map(
      (_, i) =>
        `t${i}: issue(id: $k${i}) { identifier title url state { name type color } assignee { displayName } project { name } }`,
    )
    .join('\n')
  const variables = Object.fromEntries(keys.map((key, i) => [`k${i}`, key]))

  const response = await fetch(LINEAR_GRAPHQL, {
    method: 'POST',
    headers: { authorization: env.linearApiKey, 'content-type': 'application/json' },
    body: JSON.stringify({ query: `query Tickets(${variableDefs}) {\n${selections}\n}`, variables }),
  })
  if (!response.ok && response.status !== 400) throw new Error(`Linear ${response.status}: ${await response.text()}`)

  const json = (await response.json()) as { data?: Record<string, RawIssue | null> | null }
  for (const issue of Object.values(json.data ?? {})) {
    if (!issue) continue
    tickets.set(issue.identifier, {
      key: issue.identifier,
      title: issue.title,
      url: issue.url,
      state: issue.state.name,
      stateType: issue.state.type,
      stateColor: issue.state.color,
      assignee: issue.assignee?.displayName ?? null,
      project: issue.project?.name ?? null,
    })
  }
  return tickets
}
