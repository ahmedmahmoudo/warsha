import { execFile } from 'node:child_process'
import { basename, dirname, join, resolve } from 'node:path'
import { promisify } from 'node:util'
import type { PrActions } from '../../shared/prDetail'
import { env } from '../env'

/**
 * Hands a conflicted PR to Claude Code on this machine: finds the checkout that has the PR's
 * branch (your per-ticket worktrees), writes the prompt, and opens a new session in the Claude
 * desktop app there. Only works when the server runs locally; a deployed server just offers the
 * prompt to copy.
 */

const run = promisify(execFile)

/** Running a local program from a web request only makes sense on your own machine. */
export const canRunLocally = process.env.NODE_ENV !== 'production'

async function git(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await run('git', ['-C', cwd, ...args], { timeout: 10_000 })
  return stdout.trim()
}

function originMatches(url: string, repo: string): boolean {
  const slug = url.replace(/\.git$/, '').match(/github\.com[:/](.+\/.+)$/)?.[1]
  return slug?.toLowerCase() === repo.toLowerCase()
}

/**
 * The main clone of a repo: LOCAL_REPOS when set, otherwise a folder named after the repo next
 * to this project (~/everlab/ev-admin beside ~/everlab/workbench), if its origin is that repo.
 */
async function localClone(repo: string): Promise<string | null> {
  const candidate = env.localRepos.get(repo.toLowerCase()) ?? resolve(process.cwd(), '..', basename(repo))
  try {
    return originMatches(await git(candidate, 'remote', 'get-url', 'origin'), repo) ? candidate : null
  } catch {
    return null
  }
}

/** The worktree that has `branch` checked out, if any. */
async function worktreeFor(clone: string, branch: string): Promise<string | null> {
  const porcelain = await git(clone, 'worktree', 'list', '--porcelain')
  for (const block of porcelain.split('\n\n')) {
    const path = block.match(/^worktree (.+)$/m)?.[1]
    if (path && block.includes(`\nbranch refs/heads/${branch}`)) return path
  }
  return null
}

type ConflictPr = { repo: string; number: number; title: string; url: string; head: string; base: string }

/** Where a new worktree for the branch goes: beside the clone, named like the others ("ev-admin-mx-2481"). */
function newWorktreePath(clone: string, pr: ConflictPr): string {
  const ticket = pr.head.match(/(?:^|[/_-])([a-z]{2,6}-\d{1,6})(?=$|[/_-])/i)?.[1]?.toLowerCase()
  return join(dirname(clone), `${basename(clone)}-${ticket ?? `pr-${pr.number}`}`)
}

function conflictPrompt(pr: ConflictPr, checkout: { path: string; kind: 'worktree' | 'new-worktree' } | null, worktreePath: string | null): string {
  const first =
    checkout?.kind === 'worktree'
      ? `You're in the worktree for \`${pr.head}\`. If it has uncommitted changes, stop and tell me rather than stashing or discarding them.`
      : worktreePath
        ? `This is my main checkout; leave it alone. Make a worktree for the PR branch and do everything there: \`git fetch origin ${pr.head}\`, then \`git worktree add ${worktreePath} ${pr.head}\` (if that folder already exists, use it).`
        : `Check out the PR branch with \`gh pr checkout ${pr.number}\`, in a worktree if my current checkout has work in progress.`
  return [
    `PR ${pr.repo}#${pr.number} "${pr.title}" (${pr.url}) has merge conflicts with its base branch \`${pr.base}\`. Resolve them and update the PR.`,
    '',
    `1. ${first}`,
    `2. Run \`git fetch origin\`, then merge \`origin/${pr.base}\` into \`${pr.head}\`. Merge, don't rebase: the branch is pushed and under review.`,
    `3. Resolve each conflict keeping the intent of both sides. Read the PR description (\`gh pr view ${pr.number}\`) and the ${pr.base} commits that touched the same code before choosing. If a conflict needs a product decision, stop and ask me.`,
    '4. Run the typecheck and the tests for the packages you touched, and fix anything the merge broke.',
    `5. Commit the merge with the default merge message and push to \`origin ${pr.head}\`.`,
    '6. Tell me which files conflicted and how you resolved each one.',
  ].join('\n')
}

function shellQuote(text: string): string {
  return `'${text.replaceAll("'", `'\\''`)}'`
}

export async function conflictAction(pr: ConflictPr): Promise<NonNullable<PrActions['conflicts']>> {
  const clone = await localClone(pr.repo)
  const worktree = clone ? await worktreeFor(clone, pr.head).catch(() => null) : null
  const checkout = clone ? { path: worktree ?? clone, kind: worktree ? ('worktree' as const) : ('new-worktree' as const) } : null
  const prompt = conflictPrompt(pr, checkout, clone && !worktree ? newWorktreePath(clone, pr) : null)
  return {
    prompt,
    checkout,
    command: checkout ? `cd ${shellQuote(checkout.path)} && claude ${shellQuote(prompt)}` : null,
    canLaunch: canRunLocally && process.platform === 'darwin' && checkout !== null,
  }
}

/** Claude desktop's documented link for a new Code session: folder plus a prefilled prompt. */
const DESKTOP_PROMPT_LIMIT = 14_000

/**
 * Opens a new Claude Code session in the Claude desktop app, in the PR's checkout, with the prompt
 * filled in. The app asks you to confirm the folder and you press send, so nothing runs unseen.
 * https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link
 */
export async function launchConflictSession(pr: ConflictPr): Promise<{ path: string }> {
  const action = await conflictAction(pr)
  if (!action.canLaunch || !action.checkout) throw new Error('No local checkout of this repo to open Claude in')
  if (action.prompt.length > DESKTOP_PROMPT_LIMIT) throw new Error('The prompt is too long for a Claude desktop link; copy it instead')

  // encodeURIComponent, not URLSearchParams: spaces must be %20, as in the documented example, not "+".
  const link = `claude://code/new?folder=${encodeURIComponent(action.checkout.path)}&q=${encodeURIComponent(action.prompt)}`
  try {
    await run('open', [link])
  } catch (error) {
    throw new Error(`Couldn't open the Claude app (is it installed?): ${error instanceof Error ? error.message : String(error)}`)
  }
  console.log(`[claude] Opened a Claude Code session in ${action.checkout.path} for ${pr.repo}#${pr.number}`)
  return { path: action.checkout.path }
}
