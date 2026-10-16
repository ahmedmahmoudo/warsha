import { Hono } from 'hono'
import type { PrScope, PrsResponse } from '../../shared/prs'
import { env } from '../env'
import { IntegrationNotConfigured } from '../integrations/errors'
import { getViewerLogin, searchPrs, type GithubPr } from '../integrations/github'
import { getTicketsByKey } from '../integrations/linear'
import { createSwrCache } from '../lib/swrCache'
import { derivePr, extractTicketKeys, linkStacks } from './derive'

const STALE_AFTER_MS = 30_000
const MERGED_LOOKBACK_DAYS = 7
const REVIEWED_LOOKBACK_DAYS = 14
const SCOPES: readonly PrScope[] = ['mine', 'reviewing', 'team']

let viewerLogin: string | null = null

function isScope(value: string | undefined): value is PrScope {
  return SCOPES.some((scope) => scope === value)
}

function daysAgo(days: number): string {
  return new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10)
}

function searchQueries(scope: PrScope, login: string): { open: string[]; merged: string[] } {
  const repos = env.githubRepos.map((repo) => `repo:${repo}`).join(' ')
  const mergedSince = `merged:>=${daysAgo(MERGED_LOOKBACK_DAYS)}`
  switch (scope) {
    case 'mine':
      return {
        open: [`is:pr is:open archived:false author:${login}`],
        merged: [`is:pr is:merged author:${login} ${mergedSince}`],
      }
    case 'reviewing':
      // Only requests made to you personally (not via a CODEOWNERS team); a request disappears
      // once you review, so recently reviewed PRs stay visible too.
      return {
        open: [
          `is:pr is:open archived:false user-review-requested:${login}`,
          `is:pr is:open archived:false reviewed-by:${login} -author:${login} updated:>=${daysAgo(REVIEWED_LOOKBACK_DAYS)}`,
        ],
        merged: [`is:pr is:merged reviewed-by:${login} -author:${login} ${mergedSince}`],
      }
    case 'team': {
      if (env.githubTeam.length === 0) throw new IntegrationNotConfigured('GITHUB_TEAM is not set in .env.local')
      const authors = env.githubTeam.map((member) => `author:${member}`).join(' ')
      return {
        open: [`is:pr is:open archived:false ${authors} ${repos}`],
        merged: [`is:pr is:merged ${authors} ${repos} ${mergedSince}`],
      }
    }
  }
}

async function searchAll(queries: string[]): Promise<{ prs: GithubPr[]; truncated: boolean }> {
  const results = await Promise.all(queries.map(searchPrs))
  const byUrl = new Map(results.flatMap((r) => r.prs).map((pr) => [pr.url, pr]))
  return { prs: [...byUrl.values()], truncated: results.some((r) => r.truncated) }
}

async function buildResponse(scope: PrScope): Promise<PrsResponse> {
  viewerLogin ??= await getViewerLogin()
  const queries = searchQueries(scope, viewerLogin)
  const [open, merged] = await Promise.all([searchAll(queries.open), searchAll(queries.merged)])

  const warnings: string[] = []
  if (open.truncated || merged.truncated) warnings.push('Some results were cut off at the page limit.')

  const keys = [...new Set([...open.prs, ...merged.prs].flatMap(extractTicketKeys))]
  let tickets = null
  try {
    tickets = await getTicketsByKey(keys)
  } catch (error) {
    warnings.push(error instanceof IntegrationNotConfigured ? `Linear: ${error.message}` : `Linear lookup failed: ${String(error)}`)
  }

  const byUpdated = (a: { updatedAt: string }, b: { updatedAt: string }) => b.updatedAt.localeCompare(a.updatedAt)
  return {
    scope,
    viewer: viewerLogin,
    open: linkStacks(open.prs.map((pr) => derivePr(pr, tickets))).sort(byUpdated),
    recentlyMerged: merged.prs
      .map((pr) => derivePr(pr, tickets))
      .sort((a, b) => (b.mergedAt ?? '').localeCompare(a.mergedAt ?? '')),
    fetchedAt: new Date().toISOString(),
    warnings,
  }
}

const cache = createSwrCache({ load: buildResponse, staleAfterMs: STALE_AFTER_MS })
cache.warm('mine')

export const prsRoute = new Hono().get('/', async (c) => {
  const scope = c.req.query('scope') ?? 'mine'
  if (!isScope(scope)) return c.json({ error: `Unknown scope "${scope}"` }, 400)

  try {
    return c.json(await cache.get(scope, { force: c.req.query('fresh') === '1' }))
  } catch (error) {
    if (error instanceof IntegrationNotConfigured) return c.json({ error: error.message, setup: true }, 503)
    throw error
  }
})
