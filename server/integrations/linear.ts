import type { Ticket } from '../../shared/prs'
import type { OpenTicket } from '../../shared/today'
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

export type LinearHistoryEntry = {
  createdAt: string
  actor: { name: string } | null
  fromState: { name: string; type: string } | null
  toState: { name: string; type: string } | null
}

export type LinearIssueActivity = RawIssue & {
  createdAt: string
  creator: { isMe: boolean } | null
  history: { nodes: LinearHistoryEntry[] }
}

const ISSUE_ACTIVITY_FIELDS = `
  identifier title url createdAt
  creator { isMe }
  state { name type color } assignee { displayName } project { name }
  history(first: 50) { nodes { createdAt actor { name } fromState { name type } toState { name type } } }`

const ISSUE_ACTIVITY_PAGES = 5

async function linearQuery<T>(query: string, variables: Record<string, unknown>): Promise<T> {
  if (!env.linearApiKey) throw new IntegrationNotConfigured('LINEAR_API_KEY is not set in .env.local')
  const response = await fetch(LINEAR_GRAPHQL, {
    method: 'POST',
    headers: { authorization: env.linearApiKey, 'content-type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  })
  const json = (await response.json()) as { data?: T | null; errors?: { message: string }[] }
  if (!response.ok || json.errors?.length || !json.data)
    throw new Error(`Linear ${response.status}: ${json.errors?.map((e) => e.message).join('; ') ?? response.statusText}`)
  return json.data
}

type IssuePage = { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: LinearIssueActivity[] }

/**
 * Issues assigned to you that changed since `from`, and issues you created in the range, with
 * their state history. Paged, since a month back easily passes a hundred.
 */
export async function getMyIssueActivity(from: string, to: string): Promise<{ issues: LinearIssueActivity[]; truncated: boolean }> {
  const byKey = new Map<string, LinearIssueActivity>()
  let truncated = false
  for (const [filter, label] of [
    // Created after the range ends means nothing in it can be about the range.
    ['{ assignee: { isMe: { eq: true } }, updatedAt: { gte: $from }, createdAt: { lt: $to } }', 'assigned'],
    ['{ creator: { isMe: { eq: true } }, createdAt: { gte: $from, lt: $to } }', 'created'],
  ] as const) {
    let after: string | null = null
    for (let page = 0; page < ISSUE_ACTIVITY_PAGES; page++) {
      const data: { issues: IssuePage } = await linearQuery<{ issues: IssuePage }>(
        `query MyIssueActivity($from: DateTimeOrDuration!, $to: DateTimeOrDuration!, $after: String) {
          issues(first: 100, after: $after, filter: ${filter}) {
            pageInfo { hasNextPage endCursor }
            nodes { ${ISSUE_ACTIVITY_FIELDS} }
          }
        }`,
        { from, to, after },
      )
      for (const issue of data.issues.nodes) byKey.set(issue.identifier, issue)
      if (!data.issues.pageInfo.hasNextPage) break
      if (page === ISSUE_ACTIVITY_PAGES - 1) {
        truncated = true
        console.warn(`[linear] Stopped after ${ISSUE_ACTIVITY_PAGES * 100} ${label} issues`)
      }
      after = data.issues.pageInfo.endCursor
    }
  }
  return { issues: [...byKey.values()], truncated }
}

export function toTicket(issue: RawIssue): Ticket {
  return {
    key: issue.identifier,
    title: issue.title,
    url: issue.url,
    state: issue.state.name,
    stateType: issue.state.type,
    stateColor: issue.state.color,
    assignee: issue.assignee?.displayName ?? null,
    project: issue.project?.name ?? null,
  }
}

type RawStateHistory = {
  identifier: string
  createdAt: string
  startedAt: string | null
  state: { name: string }
  history: { nodes: { createdAt: string; toState: { name: string } | null }[] }
}

/**
 * When each ticket entered the status it's in now: the latest move into that status, else when
 * work started, else when it was created. Keyed by ticket key.
 */
export async function getTicketStateSince(keys: string[]): Promise<Map<string, string>> {
  const since = new Map<string, string>()
  if (keys.length === 0) return since
  const variableDefs = keys.map((_, i) => `$k${i}: String!`).join(', ')
  const selections = keys
    .map(
      (_, i) =>
        `t${i}: issue(id: $k${i}) { identifier createdAt startedAt state { name } history(first: 50) { nodes { createdAt toState { name } } } }`,
    )
    .join('\n')
  // Unknown keys come back as per-alias errors; linearQuery would throw on those, so read raw.
  if (!env.linearApiKey) throw new IntegrationNotConfigured('LINEAR_API_KEY is not set in .env.local')
  const response = await fetch(LINEAR_GRAPHQL, {
    method: 'POST',
    headers: { authorization: env.linearApiKey, 'content-type': 'application/json' },
    body: JSON.stringify({
      query: `query StateSince(${variableDefs}) {\n${selections}\n}`,
      variables: Object.fromEntries(keys.map((key, i) => [`k${i}`, key])),
    }),
  })
  if (!response.ok && response.status !== 400) throw new Error(`Linear ${response.status}: ${await response.text()}`)
  const json = (await response.json()) as { data?: Record<string, RawStateHistory | null> | null }
  for (const issue of Object.values(json.data ?? {})) {
    if (!issue) continue
    const entered = issue.history.nodes
      .filter((entry) => entry.toState?.name === issue.state.name)
      .reduce<string | null>((latest, entry) => (!latest || entry.createdAt > latest ? entry.createdAt : latest), null)
    since.set(issue.identifier, entered ?? issue.startedAt ?? issue.createdAt)
  }
  return since
}

type RawOpenTicket = RawIssue & {
  priority: number
  priorityLabel: string
  createdAt: string
  labels: { nodes: { name: string }[] }
  project: { name: string; url: string; targetDate: string | null; status: { type: string } | null } | null
  cycle: { number: number; startsAt: string; endsAt: string } | null
  history: { nodes: { createdAt: string; toAssignee: { isMe: boolean } | null }[] }
}

const OPEN_TICKET_PAGES = 3

/** Everything assigned to you that isn't finished, with what decides its priority. */
export async function getMyOpenTickets(): Promise<OpenTicket[]> {
  const tickets: OpenTicket[] = []
  let after: string | null = null
  for (let page = 0; page < OPEN_TICKET_PAGES; page++) {
    const data: { issues: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: RawOpenTicket[] } } =
      await linearQuery(
        `query MyOpenTickets($after: String) {
          issues(first: 100, after: $after, filter: {
            assignee: { isMe: { eq: true } }
            state: { type: { nin: ["completed", "canceled"] } }
          }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              identifier title url priority priorityLabel createdAt
              state { name type color } assignee { displayName }
              project { name url targetDate status { type } }
              cycle { number startsAt endsAt }
              labels(first: 10) { nodes { name } }
              history(first: 30) { nodes { createdAt toAssignee { isMe } } }
            }
          }
        }`,
        { after },
      )
    for (const raw of data.issues.nodes) {
      const assignedAt = raw.history.nodes
        .filter((entry) => entry.toAssignee?.isMe)
        .reduce<string | null>((latest, entry) => (!latest || entry.createdAt > latest ? entry.createdAt : latest), null)
      tickets.push({
        ...toTicket(raw),
        priority: raw.priority,
        priorityLabel: raw.priorityLabel,
        labels: raw.labels.nodes.map((label) => label.name),
        createdAt: raw.createdAt,
        assignedAt,
        projectInfo: raw.project
          ? { name: raw.project.name, url: raw.project.url, targetDate: raw.project.targetDate, statusType: raw.project.status?.type ?? null }
          : null,
        cycle: raw.cycle,
      })
    }
    if (!data.issues.pageInfo.hasNextPage) break
    after = data.issues.pageInfo.endCursor
  }
  return tickets
}

type RawNotification = {
  id: string
  type: string
  createdAt: string
  readAt: string | null
  archivedAt: string | null
  actor: { name: string; avatarUrl: string | null } | null
  issue?: { identifier: string; title: string; url: string; state: { name: string; type: string; color: string } } | null
  comment?: { body: string; url: string } | null
  project?: { name: string; url: string } | null
  projectUpdate?: { body: string; url: string } | null
}

/** Notification kinds that are reminders rather than news. */
const IGNORED_NOTIFICATIONS = new Set(['projectUpdatePrompt', 'projectDescriptionContentChange'])
const NOTIFICATION_PAGE = 100

/** Your Linear inbox, newest first: assignments, comments, mentions, status and priority changes. */
export async function getMyNotifications(): Promise<RawNotification[]> {
  const data = await linearQuery<{ notifications: { nodes: RawNotification[] } }>(
    `query MyNotifications($first: Int!) {
      notifications(first: $first) { nodes {
        id type createdAt readAt archivedAt
        actor { name avatarUrl }
        ... on IssueNotification {
          issue { identifier title url state { name type color } }
          comment { body url }
        }
        ... on ProjectNotification {
          project { name url }
          projectUpdate { body url }
          comment { body url }
        }
      } }
    }`,
    { first: NOTIFICATION_PAGE },
  )
  return data.notifications.nodes.filter((n) => !n.archivedAt && !IGNORED_NOTIFICATIONS.has(n.type))
}

export type { RawNotification }

/** Posts a comment on a Linear ticket, as you. Returns the comment's link. */
export async function commentOnIssue(key: string, body: string): Promise<string> {
  const { issue } = await linearQuery<{ issue: { id: string } | null }>(`query IssueId($key: String!) { issue(id: $key) { id } }`, { key })
  if (!issue) throw new Error(`${key} wasn't found in Linear`)
  const { commentCreate } = await linearQuery<{ commentCreate: { success: boolean; comment: { url: string } | null } }>(
    `mutation Comment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) { success comment { url } }
    }`,
    { issueId: issue.id, body },
  )
  if (!commentCreate.success || !commentCreate.comment) throw new Error(`Linear didn't accept the comment on ${key}`)
  return commentCreate.comment.url
}

