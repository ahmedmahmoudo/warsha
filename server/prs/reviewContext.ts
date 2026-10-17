import type { Person } from '../../shared/prs'
import { getCodeownersText, getOrgTeams, getRemainingFiles, type GithubPr } from '../integrations/github'
import { createSwrCache } from '../lib/swrCache'
import { parseCodeowners, type Codeowners } from './codeowners'
import type { ReviewContext } from './derive'

/** CODEOWNERS and team lists change rarely; re-read them in the background every so often. */
const CODEOWNERS_STALE_AFTER_MS = 10 * 60_000

const codeownersCache = createSwrCache<string, Codeowners | null>({
  load: async (key) => {
    const [repo, branch] = key.split('\0') as [string, string]
    const text = await getCodeownersText(repo, branch)
    return text === null ? null : parseCodeowners(text)
  },
  staleAfterMs: CODEOWNERS_STALE_AFTER_MS,
})

/**
 * Teams only make code owners look nicer, so failing to list them (no read:org) leaves slugs.
 * The failure is cached like a result so it's logged once per refresh, not once per PR.
 */
const teamsCache = createSwrCache<string, Map<string, Person>>({
  load: async (org) => {
    let teams
    try {
      teams = await getOrgTeams(org)
    } catch (error) {
      console.error(`[prs] Couldn't list ${org} teams; code-owner teams will show by slug`, error)
      return new Map()
    }
    return new Map(
      teams.map((team): [string, Person] => [
        `${org}/${team.slug}`.toLowerCase(),
        {
          kind: 'team',
          id: `${org}/${team.slug}`,
          name: team.name,
          avatarUrl: team.avatarUrl,
          url: `https://github.com/orgs/${org}/teams/${team.slug}`,
        },
      ]),
    )
  },
  staleAfterMs: CODEOWNERS_STALE_AFTER_MS,
})

/**
 * CODEOWNERS for each base branch and every changed file, so the PR's review gate can name
 * the owners still to approve. A failure here only makes that gate incomplete.
 */
export async function reviewContexts(prs: GithubPr[]): Promise<Map<string, ReviewContext>> {
  const contexts = new Map<string, ReviewContext>()
  await Promise.all(
    prs.map(async (pr) => {
      let codeowners: Codeowners | null = null
      try {
        codeowners = await codeownersCache.get(`${pr.repository.nameWithOwner}\0${pr.baseRefName}`)
      } catch (error) {
        console.error(`[prs] Couldn't read CODEOWNERS for ${pr.repository.nameWithOwner}@${pr.baseRefName}`, error)
      }

      const files = pr.files.nodes.map((file) => file.path)
      let filesComplete = true
      if (pr.files.pageInfo.hasNextPage && pr.files.pageInfo.endCursor) {
        try {
          files.push(...(await getRemainingFiles(pr.id, pr.files.pageInfo.endCursor)))
        } catch (error) {
          filesComplete = false
          console.error(`[prs] Couldn't list every file in ${pr.url}`, error)
        }
      }
      const teams = await teamsCache.get(pr.repository.nameWithOwner.split('/')[0]!)
      contexts.set(pr.url, { codeowners, files, filesComplete, teams })
    }),
  )
  return contexts
}
