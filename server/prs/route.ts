import { Hono } from 'hono'
import type { PrActions, PrChecksResponse, PrDetail } from '../../shared/prDetail'
import type { PrScope, PrsResponse } from '../../shared/prs'
import { env } from '../env'
import { IntegrationNotConfigured } from '../integrations/errors'
import {
  checkGithubToken,
  getBranchComparison,
  getPrChecks,
  getPrDetail,
  getPrHeadOid,
  getViewerLogin,
  searchPrs,
  updatePullRequestBranch,
  type GithubPr,
  type GithubPrDetail,
} from '../integrations/github'
import { getTicketsByKey } from '../integrations/linear'
import { cacheOptions } from '../lib/cacheParams'
import { createSwrCache } from '../lib/swrCache'
import { derivePr, extractTicketKeys, linkStacks, listChecks } from './derive'
import { allowImagesFrom } from '../images/route'
import { canRunLocally, conflictAction, launchConflictSession } from '../local/claude'
import { buildDetail } from './detail'
import { reviewContexts } from './reviewContext'

const STALE_AFTER_MS = 30_000
const MERGED_LOOKBACK_DAYS = 7
const REVIEWED_LOOKBACK_DAYS = 14
const SCOPES: readonly PrScope[] = ['mine', 'reviewing', 'team']

let viewerLogin: string | null = null
/** Runs once per process: GITHUB_TOKEN is only read at startup. */
const tokenProblems = checkGithubToken().catch((error: unknown) => [`GitHub token check failed: ${String(error)}`])

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
  const startedAt = Date.now()
  viewerLogin ??= await getViewerLogin()
  const queries = searchQueries(scope, viewerLogin)
  const [open, merged] = await Promise.all([searchAll(queries.open), searchAll(queries.merged)])
  const reviews = await reviewContexts(open.prs)

  const warnings: string[] = [...(await tokenProblems)]
  if (open.truncated || merged.truncated) warnings.push('Some results were cut off at the page limit.')

  const keys = [...new Set([...open.prs, ...merged.prs].flatMap(extractTicketKeys))]
  let tickets = null
  try {
    tickets = await getTicketsByKey(keys)
  } catch (error) {
    if (error instanceof IntegrationNotConfigured) warnings.push(`Linear: ${error.message}`)
    else {
      console.error('[linear] Ticket lookup failed', error)
      warnings.push(`Linear lookup failed: ${String(error)}`)
    }
  }

  console.log(
    `[prs] ${scope}: ${open.prs.length} open, ${merged.prs.length} merged, ${tickets?.size ?? 0} tickets in ${Date.now() - startedAt}ms`,
  )

  const byUpdated = (a: { updatedAt: string }, b: { updatedAt: string }) => b.updatedAt.localeCompare(a.updatedAt)
  return {
    scope,
    viewer: viewerLogin,
    open: linkStacks(open.prs.map((pr) => derivePr(pr, tickets, reviews.get(pr.url)))).sort(byUpdated),
    recentlyMerged: merged.prs
      .map((pr) => derivePr(pr, tickets))
      .sort((a, b) => (b.mergedAt ?? '').localeCompare(a.mergedAt ?? '')),
    fetchedAt: new Date().toISOString(),
    warnings,
  }
}

const cache = createSwrCache({ load: buildResponse, staleAfterMs: STALE_AFTER_MS })
cache.warm('mine')

/** A scope's PRs from the list's cache; Activity and Today reuse the derived statuses. */
export function getPrs(scope: PrScope, maxAgeMs?: number): Promise<PrsResponse> {
  return cache.get(scope, { maxAgeMs })
}

export async function getMyOpenPrs() {
  return (await getPrs('mine')).open
}

const DETAIL_STALE_AFTER_MS = 15_000
const UPDATE_SETTLE_MS = 15_000
const UPDATE_POLL_MS = 1_000
const PR_NUMBER = /^\d{1,7}$/
const NAME = /^[\w.-]+$/

class PrNotFound extends Error {}

/** What can be done about the branch: hand conflicts to Claude, or bring it up to date. */
async function prActions(raw: GithubPrDetail, repo: string): Promise<PrActions> {
  if (raw.state !== 'OPEN') return { conflicts: null, updateBranch: null }
  const conflicted = raw.mergeable === 'CONFLICTING' || raw.mergeStateStatus === 'DIRTY'
  const conflictPr = { repo, number: raw.number, title: raw.title, url: raw.url, head: raw.headRefName, base: raw.baseRefName }

  const [conflicts, comparison] = await Promise.all([
    conflicted
      ? conflictAction(conflictPr).catch((error: unknown) => {
          console.error('[claude] Could not prepare the conflict action', error)
          return null
        })
      : null,
    getBranchComparison(repo, raw.baseRefName, raw.headRefName).catch((error: unknown) => {
      console.error(`[prs] Couldn't compare ${raw.headRefName} with ${raw.baseRefName}`, error)
      return null
    }),
  ])

  const behindBy = comparison?.behindBy ?? 0
  return {
    conflicts,
    updateBranch:
      behindBy > 0
        ? {
            behindBy,
            base: raw.baseRefName,
            canUpdate: raw.viewerCanUpdateBranch && !conflicted,
            reason: conflicted
              ? 'Resolve the conflicts first; GitHub can only update a branch that merges cleanly'
              : raw.viewerCanUpdateBranch
                ? null
                : "GitHub won't update this branch with your token (no permission, or it's from a fork)",
            headOid: raw.headRefOid,
          }
        : null,
  }
}

/** Key is "owner/repo#number". */
const detailCache = createSwrCache<string, PrDetail>({
  load: async (key) => {
    const [repo, number] = key.split('#') as [string, string]
    viewerLogin ??= await getViewerLogin()
    const raw = await getPrDetail(repo, Number(number))
    if (!raw) throw new PrNotFound(`${key} wasn't found, or the GitHub token can't see it`)
    allowImagesFrom(repo)

    let tickets = null
    try {
      tickets = await getTicketsByKey(extractTicketKeys(raw))
    } catch (error) {
      if (!(error instanceof IntegrationNotConfigured)) console.error('[linear] Ticket lookup failed', error)
    }
    const [reviews, actions] = await Promise.all([
      raw.state === 'OPEN' ? reviewContexts([raw]) : new Map(),
      prActions(raw, repo),
    ])
    return buildDetail(raw, derivePr(raw, tickets, reviews.get(raw.url)), actions)
  },
  staleAfterMs: DETAIL_STALE_AFTER_MS,
})

/**
 * Actions change things, so they need a header a page on another site can't send without
 * asking first (CORS preflight, which this server never approves).
 */
const ACTION_HEADER = 'x-warsha-action'

function prKey(params: { owner: string; repo: string; number: string }): string | null {
  const { owner, repo, number } = params
  return NAME.test(owner) && NAME.test(repo) && PR_NUMBER.test(number) ? `${owner}/${repo}#${number}` : null
}

export const prsRoute = new Hono()
  .use('/:owner/:repo/:number/*', async (c, next) => {
    if (c.req.method === 'POST' && c.req.header(ACTION_HEADER) !== '1') return c.json({ error: 'Missing action header' }, 403)
    await next()
  })
  .post('/:owner/:repo/:number/update-branch', async (c) => {
    const key = prKey(c.req.param())
    if (!key) return c.json({ error: 'Not a pull request' }, 400)
    const { expectedHeadOid } = await c.req.json<{ expectedHeadOid?: string }>().catch(() => ({ expectedHeadOid: undefined }))
    if (!expectedHeadOid || !/^[0-9a-f]{40}$/.test(expectedHeadOid)) return c.json({ error: 'expectedHeadOid is required' }, 400)

    const [repo, number] = key.split('#') as [string, string]
    const raw = await getPrDetail(repo, Number(number))
    if (!raw) return c.json({ error: `${key} wasn't found` }, 404)
    if (raw.headRefOid !== expectedHeadOid)
      return c.json({ error: 'The branch has new commits since this page loaded; refresh and try again' }, 409)

    await updatePullRequestBranch(raw.id, expectedHeadOid)
    console.log(`[prs] Updated ${key} with ${raw.baseRefName}`)

    // GitHub moves the branch a moment after accepting the update. Answer once it has, with the
    // cache refreshed, so the page's next fetch shows the new state rather than the old one.
    let settled = false
    for (const deadline = Date.now() + UPDATE_SETTLE_MS; Date.now() < deadline; ) {
      await new Promise((done) => setTimeout(done, UPDATE_POLL_MS))
      const head = await getPrHeadOid(repo, Number(number)).catch(() => null)
      if (head && head !== expectedHeadOid) {
        settled = true
        break
      }
    }
    if (!settled) console.warn(`[prs] ${key}: GitHub hadn't moved the branch after ${UPDATE_SETTLE_MS / 1000}s`)
    await detailCache.get(key, { force: true }).catch((error: unknown) => console.error('Refresh after update failed', error))
    return c.json({ ok: true, settled })
  })
  .post('/:owner/:repo/:number/resolve-conflicts', async (c) => {
    const key = prKey(c.req.param())
    if (!key) return c.json({ error: 'Not a pull request' }, 400)
    if (!canRunLocally) return c.json({ error: 'Opening Claude only works when Warsha runs on your machine' }, 403)

    const detail = await detailCache.get(key)
    if (!detail.actions.conflicts) return c.json({ error: 'This PR has no merge conflicts' }, 409)
    const { pr } = detail
    const { path } = await launchConflictSession({
      repo: pr.repo,
      number: pr.number,
      title: pr.title,
      url: pr.url,
      head: pr.headRef,
      base: pr.baseRef,
    })
    return c.json({ ok: true, path })
  })
  .get('/:owner/:repo/:number/checks', async (c) => {
    const key = prKey(c.req.param())
    if (!key) return c.json({ error: 'Not a pull request' }, 400)
    const [repo, number] = key.split('#') as [string, string]
    // Straight from GitHub every time: this is what the page polls while CI runs.
    const raw = await getPrChecks(repo, Number(number))
    if (!raw) return c.json({ error: `${key} wasn't found` }, 404)
    const response: PrChecksResponse = { headOid: raw.headRefOid, checks: listChecks(raw), fetchedAt: new Date().toISOString() }
    return c.json(response)
  })
  .get('/:owner/:repo/:number', async (c) => {
    const { owner, repo, number } = c.req.param()
    if (!NAME.test(owner) || !NAME.test(repo) || !PR_NUMBER.test(number)) return c.json({ error: 'Not a pull request' }, 400)

    try {
      return c.json(await detailCache.get(`${owner}/${repo}#${number}`, cacheOptions((name) => c.req.query(name))))
    } catch (error) {
      if (error instanceof IntegrationNotConfigured) return c.json({ error: error.message, setup: true }, 503)
      if (error instanceof PrNotFound || (error instanceof Error && error.message.includes('NOT_FOUND')))
        return c.json({ error: `${owner}/${repo}#${number} wasn't found, or the GitHub token can't see it` }, 404)
      throw error
    }
  })
  .get('/', async (c) => {
  const scope = c.req.query('scope') ?? 'mine'
  if (!isScope(scope)) return c.json({ error: `Unknown scope "${scope}"` }, 400)

  try {
    return c.json(await cache.get(scope, cacheOptions((name) => c.req.query(name))))
  } catch (error) {
    if (error instanceof IntegrationNotConfigured) return c.json({ error: error.message, setup: true }, 503)
    throw error
  }
})
