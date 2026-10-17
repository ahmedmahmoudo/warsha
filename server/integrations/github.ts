import { env } from '../env'
import { IntegrationNotConfigured } from './errors'

const GITHUB_GRAPHQL = 'https://api.github.com/graphql'
const SEARCH_PAGE_SIZE = 100
const MAX_SEARCH_PAGES = 3
const DETAIL_CHUNK = 8
/** GitHub's secondary rate limit drops heavy queries fired all at once. */
const DETAIL_CONCURRENCY = 4

type GraphqlError = { message: string; type?: string; path?: (string | number)[] }

type GraphqlResult<T> = { data: T | null; errors: GraphqlError[]; headers: Headers }

/** Turns an HTTP failure into something that says what to fix, not just the status code. */
function describeHttpFailure(status: number, body: string, headers: Headers): string {
  if (status === 401) return 'GitHub rejected GITHUB_TOKEN (401): it is wrong, revoked or expired'
  if (headers.get('x-ratelimit-remaining') === '0') {
    const reset = Number(headers.get('x-ratelimit-reset')) * 1000
    return `GitHub rate limit used up; it resets at ${new Date(reset).toLocaleTimeString()}`
  }
  if (status === 403 && /SAML|SSO/i.test(body)) return 'GitHub token needs SSO authorization for the organization (403)'
  return `GitHub ${status}: ${body.slice(0, 300)}`
}

function formatGraphqlError(error: GraphqlError): string {
  const where = error.path?.length ? ` at ${error.path.join('.')}` : ''
  return `${error.type ?? 'ERROR'}${where}: ${error.message}`
}

/** Returns partial data alongside per-field errors; the token check needs both. */
async function githubGraphqlRaw<T>(query: string, variables: Record<string, unknown>): Promise<GraphqlResult<T>> {
  if (!env.githubToken) throw new IntegrationNotConfigured('GITHUB_TOKEN is not set in .env.local')

  const response = await fetch(GITHUB_GRAPHQL, {
    method: 'POST',
    headers: {
      authorization: `bearer ${env.githubToken}`,
      'content-type': 'application/json',
      // mergeStateStatus is still gated behind this preview on some GitHub API versions.
      accept: 'application/vnd.github.merge-info-preview+json',
    },
    body: JSON.stringify({ query, variables }),
  })
  const text = await response.text()
  if (!response.ok) {
    const message = describeHttpFailure(response.status, text, response.headers)
    console.error(`[github] ${message}`)
    throw new Error(message)
  }

  const json = JSON.parse(text) as { data?: T | null; errors?: GraphqlError[] }
  return { data: json.data ?? null, errors: json.errors ?? [], headers: response.headers }
}

async function githubGraphql<T>(query: string, variables: Record<string, unknown>): Promise<T> {
  const { data, errors } = await githubGraphqlRaw<T>(query, variables)
  if (errors.length) {
    for (const error of errors) console.error(`[github] ${formatGraphqlError(error)}`)
    throw new Error(`GitHub: ${errors.map(formatGraphqlError).join('; ')}`)
  }
  if (!data) throw new Error('GitHub returned no data')
  return data
}

export type RawCheckContext = { isRequired: boolean } & (
  | { __typename: 'CheckRun'; name: string; status: string; conclusion: string | null; detailsUrl: string | null }
  | { __typename: 'StatusContext'; context: string; state: string; targetUrl: string | null }
)

export type GithubPr = {
  id: string
  number: number
  title: string
  url: string
  body: string
  isDraft: boolean
  createdAt: string
  updatedAt: string
  mergedAt: string | null
  headRefName: string
  baseRefName: string
  additions: number
  deletions: number
  mergeStateStatus: string
  reviewDecision: string | null
  author: RawActor | null
  repository: { nameWithOwner: string }
  /** Null once the base branch is deleted. */
  baseRef: {
    rules: { nodes: RawRule[] }
    branchProtectionRule: {
      requiredApprovingReviewCount: number | null
      requiresCodeOwnerReviews: boolean
      requiresConversationResolution: boolean
      requiresStrictStatusChecks: boolean
      requiredStatusCheckContexts: string[]
    } | null
  } | null
  files: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: { path: string }[] }
  commits: { nodes: { commit: { statusCheckRollup: { state: string; contexts: { nodes: RawCheckContext[] } } | null } }[] }
  reviewThreads: { nodes: { isResolved: boolean; comments: { nodes: { author: { login: string } | null }[] } }[] }
  latestOpinionatedReviews: {
    nodes: { state: string; author: RawActor | null; onBehalfOf: { nodes: { slug: string }[] } }[]
  }
  reviewRequests: { nodes: { asCodeOwner: boolean; requestedReviewer: RawReviewer | null }[] }
}

export type RawActor = { login: string; avatarUrl: string }

export type RawReviewer =
  | ({ __typename: 'User' | 'Bot' } & RawActor)
  | { __typename: 'Team'; slug: string; name: string; avatarUrl: string | null; organization: { login: string } }
  | { __typename: 'Mannequin' }

export type RawRule = {
  type: string
  repositoryRuleset: { id: string } | null
  parameters: {
    requiredApprovingReviewCount?: number
    requireCodeOwnerReview?: boolean
    requiredReviewThreadResolution?: boolean
    strictRequiredStatusChecksPolicy?: boolean
    requiredStatusChecks?: { context: string }[]
  } | null
}

/**
 * `isRequired` takes the PR number as an argument, so each PR gets its own selection with
 * the number inlined rather than sharing a fragment.
 */
function prSelection(alias: string, idVariable: string, number: number): string {
  return `${alias}: node(id: ${idVariable}) { ... on PullRequest { ${prFields(number)} } }`
}

/** The base branch's rules and the head commit's checks: everything a check list is read from. */
function checkFields(number: number): string {
  return /* GraphQL */ `
      mergedAt
      baseRef {
        rules(first: 30) { nodes { type repositoryRuleset { id } parameters {
          ... on PullRequestParameters { requiredApprovingReviewCount requireCodeOwnerReview requiredReviewThreadResolution }
          ... on RequiredStatusChecksParameters { strictRequiredStatusChecksPolicy requiredStatusChecks { context } }
        } } }
        branchProtectionRule {
          requiredApprovingReviewCount requiresCodeOwnerReviews requiresConversationResolution requiresStrictStatusChecks
          requiredStatusCheckContexts
        }
      }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber: ${number}) }
          ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: ${number}) }
        } } } } }
      }`
}

/** The fields every PR needs, list or details page. */
function prFields(number: number): string {
  if (!Number.isInteger(number)) throw new Error(`Unexpected PR number ${number}`)
  return /* GraphQL */ `
      id number title url body isDraft createdAt updatedAt mergedAt
      headRefName baseRefName additions deletions mergeStateStatus reviewDecision
      author { login avatarUrl(size: 48) }
      repository { nameWithOwner }
      ${checkFields(number)}
      files(first: 100) { pageInfo { hasNextPage endCursor } nodes { path } }
      reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { author { login } } } } }
      latestOpinionatedReviews(first: 20) { nodes {
        state author { login avatarUrl(size: 48) } onBehalfOf(first: 10) { nodes { slug } }
      } }
      reviewRequests(first: 20) { nodes { asCodeOwner requestedReviewer {
        __typename
        ... on User { login avatarUrl(size: 48) }
        ... on Bot { login avatarUrl(size: 48) }
        ... on Team { slug name avatarUrl(size: 48) organization { login } }
      } } }`
}

type PrRef = { id: string; number: number }

type SearchResult = {
  search: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: (PrRef | { id?: undefined })[] }
}

const SEARCH_PR_REFS = /* GraphQL */ `
  query SearchPrRefs($query: String!, $first: Int!, $after: String) {
    search(type: ISSUE, query: $query, first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { ... on PullRequest { id number } }
    }
  }
`

function isPrRef(node: PrRef | { id?: undefined }): node is PrRef {
  return node.id !== undefined
}

/**
 * Search is slow on GitHub's side and gets slower with every nested field, so it only
 * returns ids; the details come from batched `node` lookups that run in parallel.
 */
export async function searchPrs(query: string): Promise<{ prs: GithubPr[]; truncated: boolean }> {
  const refs: PrRef[] = []
  let after: string | null = null
  let truncated = true
  for (let page = 0; page < MAX_SEARCH_PAGES; page++) {
    const { search }: SearchResult = await githubGraphql<SearchResult>(SEARCH_PR_REFS, {
      query,
      first: SEARCH_PAGE_SIZE,
      after,
    })
    refs.push(...search.nodes.filter(isPrRef))
    if (!search.pageInfo.hasNextPage) {
      truncated = false
      break
    }
    after = search.pageInfo.endCursor
  }
  return { prs: await getPrDetails(refs), truncated }
}

async function getPrDetails(refs: PrRef[]): Promise<GithubPr[]> {
  const chunks: PrRef[][] = []
  for (let start = 0; start < refs.length; start += DETAIL_CHUNK) chunks.push(refs.slice(start, start + DETAIL_CHUNK))

  const prs: GithubPr[] = []
  let next = 0
  async function worker() {
    while (next < chunks.length) {
      const chunk = chunks[next++]!
      const variableDefs = chunk.map((_, i) => `$id${i}: ID!`).join(', ')
      const selections = chunk.map((ref, i) => prSelection(`p${i}`, `$id${i}`, ref.number)).join('\n')
      const variables = Object.fromEntries(chunk.map((ref, i) => [`id${i}`, ref.id]))
      const result = await githubGraphql<Record<string, GithubPr | null>>(
        `query PrDetails(${variableDefs}) {${selections}\n}`,
        variables,
      )
      prs.push(...Object.values(result).filter((pr): pr is GithubPr => pr !== null))
    }
  }
  await Promise.all(Array.from({ length: DETAIL_CONCURRENCY }, worker))
  return prs
}

export async function getViewerLogin(): Promise<string> {
  const data = await githubGraphql<{ viewer: { login: string } }>('query { viewer { login } }', {})
  return data.viewer.login
}

/** An actor on the details page, where bots are told apart from people. */
export type RawDetailActor = { __typename: string; login: string; avatarUrl: string }

export type RawThread = {
  id: string
  isResolved: boolean
  isOutdated: boolean
  path: string
  line: number | null
  comments: {
    totalCount: number
    nodes: { bodyText: string; url: string; createdAt: string; author: RawDetailActor | null }[]
  }
}

export type RawReview = {
  id: string
  state: string
  bodyText: string
  url: string
  submittedAt: string | null
  author: RawDetailActor | null
}

/** One of the timeline item types asked for below; only the fields of its type are set. */
export type RawTimelineItem = {
  __typename: string
  id: string
  createdAt?: string
  url?: string
  actor?: RawDetailActor | null
  author?: RawDetailActor | null
  bodyText?: string
  state?: string
  reason?: string | null
  dismissalMessage?: string | null
  previousRefName?: string
  currentRefName?: string
  requestedReviewer?: { login?: string; name?: string } | null
  commit?: { committedDate: string; messageHeadline: string; author: { user: { login: string; avatarUrl: string } | null; name: string | null } | null }
}

export type GithubPrDetail = GithubPr & {
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  closedAt: string | null
  headRefOid: string
  mergeable: 'MERGEABLE' | 'CONFLICTING' | 'UNKNOWN'
  viewerCanUpdateBranch: boolean
  bodyHTML: string
  mergeQueueEntry: { state: string; position: number | null; enqueuedAt: string } | null
  threads: { nodes: RawThread[] }
  reviews: { nodes: RawReview[] }
  timelineItems: { nodes: RawTimelineItem[] }
}

const DETAIL_ACTOR = '{ __typename login avatarUrl(size: 48) }'

const DETAIL_FIELDS = /* GraphQL */ `
  state closedAt bodyHTML headRefOid mergeable viewerCanUpdateBranch
  mergeQueueEntry { state position enqueuedAt }
  threads: reviewThreads(first: 100) { nodes {
    id isResolved isOutdated path line
    comments(first: 1) { totalCount nodes { bodyText url createdAt author ${DETAIL_ACTOR} } }
  } }
  reviews: latestOpinionatedReviews(first: 20) { nodes { id state bodyText url submittedAt author ${DETAIL_ACTOR} } }
  timelineItems(last: 100, itemTypes: [
    PULL_REQUEST_COMMIT, PULL_REQUEST_REVIEW, ISSUE_COMMENT, REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT,
    CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT,
    REMOVED_FROM_MERGE_QUEUE_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_DISMISSED_EVENT, BASE_REF_CHANGED_EVENT
  ]) { nodes {
    __typename
    ... on PullRequestCommit { id url commit {
      committedDate messageHeadline author { name user { login avatarUrl(size: 48) } }
    } }
    ... on PullRequestReview { id createdAt url state bodyText author ${DETAIL_ACTOR} }
    ... on IssueComment { id createdAt url bodyText author ${DETAIL_ACTOR} }
    ... on ReviewRequestedEvent { id createdAt actor ${DETAIL_ACTOR} requestedReviewer {
      ... on User { login } ... on Bot { login } ... on Team { name }
    } }
    ... on ReadyForReviewEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on ConvertToDraftEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on MergedEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on ClosedEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on ReopenedEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on AddedToMergeQueueEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on RemovedFromMergeQueueEvent { id createdAt reason actor ${DETAIL_ACTOR} }
    ... on HeadRefForcePushedEvent { id createdAt actor ${DETAIL_ACTOR} }
    ... on ReviewDismissedEvent { id createdAt dismissalMessage actor ${DETAIL_ACTOR} }
    ... on BaseRefChangedEvent { id createdAt previousRefName currentRefName actor ${DETAIL_ACTOR} }
  } }`

/** One PR with everything the details page shows; null when it doesn't exist or isn't visible. */
export async function getPrDetail(repo: string, number: number): Promise<GithubPrDetail | null> {
  const [owner, name] = repo.split('/')
  const data = await githubGraphql<{ repository: { pullRequest: GithubPrDetail | null } | null }>(
    `query PrDetail($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
      pullRequest(number: ${number}) { ${prFields(number)} ${DETAIL_FIELDS} }
    } }`,
    { owner, name },
  )
  return data.repository?.pullRequest ?? null
}

/**
 * How far the PR branch has drifted from its base: `behindBy` counts base commits the branch
 * doesn't have yet. GitHub only reports BEHIND when the base requires an up-to-date branch,
 * so the comparison is asked for directly.
 */
export async function getBranchComparison(
  repo: string,
  base: string,
  head: string,
): Promise<{ aheadBy: number; behindBy: number } | null> {
  const [owner, name] = repo.split('/')
  const data = await githubGraphql<{
    repository: { ref: { compare: { aheadBy: number; behindBy: number } | null } | null } | null
  }>(
    `query Compare($owner: String!, $name: String!, $base: String!, $head: String!) {
      repository(owner: $owner, name: $name) { ref(qualifiedName: $base) { compare(headRef: $head) { aheadBy behindBy } } }
    }`,
    { owner, name, base: `refs/heads/${base}`, head },
  )
  return data.repository?.ref?.compare ?? null
}

/**
 * GitHub's "Update branch": merges the base into the PR branch on GitHub. `expectedHeadOid`
 * makes it fail rather than merge into commits the page hasn't shown.
 */
export async function updatePullRequestBranch(pullRequestId: string, expectedHeadOid: string): Promise<void> {
  await githubGraphql(
    `mutation UpdateBranch($id: ID!, $oid: GitObjectID!) {
      updatePullRequestBranch(input: { pullRequestId: $id, expectedHeadOid: $oid, updateMethod: MERGE }) {
        pullRequest { id }
      }
    }`,
    { id: pullRequestId, oid: expectedHeadOid },
  )
}

export type GithubPrChecks = Pick<GithubPr, 'mergedAt' | 'baseRef' | 'commits'> & { headRefOid: string }

/** Only what the check list needs, so the details page can poll it while CI runs. */
export async function getPrChecks(repo: string, number: number): Promise<GithubPrChecks | null> {
  const [owner, name] = repo.split('/')
  const data = await githubGraphql<{ repository: { pullRequest: GithubPrChecks | null } | null }>(
    `query PrChecks($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
      pullRequest(number: ${number}) { headRefOid ${checkFields(number)} }
    } }`,
    { owner, name },
  )
  return data.repository?.pullRequest ?? null
}

/** Just the PR's head commit, cheap enough to poll. */
export async function getPrHeadOid(repo: string, number: number): Promise<string | null> {
  const [owner, name] = repo.split('/')
  const data = await githubGraphql<{ repository: { pullRequest: { headRefOid: string } | null } | null }>(
    `query Head($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid } }
    }`,
    { owner, name, number },
  )
  return data.repository?.pullRequest?.headRefOid ?? null
}

/** GitHub caps a PR's file list at 3,000. */
const MAX_FILE_PAGES = 30

/** The rest of a PR's changed files, after the first page that came with its details. */
export async function getRemainingFiles(prId: string, after: string): Promise<string[]> {
  type FilesPage = { node: { files: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: { path: string }[] } } }
  const paths: string[] = []
  let cursor: string | null = after
  for (let page = 0; cursor && page < MAX_FILE_PAGES; page++) {
    const { node }: FilesPage = await githubGraphql<FilesPage>(
      `query PrFiles($id: ID!, $after: String) { node(id: $id) { ... on PullRequest {
        files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { path } }
      } } }`,
      { id: prId, after: cursor },
    )
    paths.push(...node.files.nodes.map((file) => file.path))
    cursor = node.files.pageInfo.hasNextPage ? node.files.pageInfo.endCursor : null
  }
  return paths
}

export type RawTeam = { slug: string; name: string; avatarUrl: string | null }

const MAX_TEAM_PAGES = 5

/** Every team in the org, for naming code owners that weren't requested. Needs read:org. */
export async function getOrgTeams(org: string): Promise<RawTeam[]> {
  type TeamsPage = {
    organization: { teams: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: RawTeam[] } } | null
  }
  const teams: RawTeam[] = []
  let after: string | null = null
  for (let page = 0; page < MAX_TEAM_PAGES; page++) {
    const { organization }: TeamsPage = await githubGraphql<TeamsPage>(
      `query OrgTeams($org: String!, $after: String) { organization(login: $org) {
        teams(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { slug name avatarUrl(size: 48) } }
      } }`,
      { org, after },
    )
    if (!organization) break
    teams.push(...organization.teams.nodes)
    if (!organization.teams.pageInfo.hasNextPage) break
    after = organization.teams.pageInfo.endCursor
  }
  return teams
}

/** GitHub uses the first of these that exists on the base branch. */
const CODEOWNERS_PATHS = ['.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS']

export async function getCodeownersText(repo: string, branch: string): Promise<string | null> {
  const [owner, name] = repo.split('/')
  const selections = CODEOWNERS_PATHS.map(
    (path, i) => `f${i}: object(expression: ${JSON.stringify(`${branch}:${path}`)}) { ... on Blob { text } }`,
  ).join('\n')
  const data = await githubGraphql<{ repository: Record<string, { text: string | null } | null> | null }>(
    `query Codeowners($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {\n${selections}\n} }`,
    { owner, name },
  )
  return CODEOWNERS_PATHS.map((_, i) => data.repository?.[`f${i}`]?.text).find((text) => text != null) ?? null
}

const TOKEN_KINDS: [prefix: string, kind: string][] = [
  ['github_pat_', 'fine-grained token'],
  ['ghp_', 'classic token'],
  ['gho_', 'gh CLI token'],
]
const EXPIRY_WARNING_DAYS = 7

type RepoProbe = {
  nameWithOwner: string
  pullRequests: { nodes: { number: number; commits: { nodes: { commit: { statusCheckRollup: { state: string } | null } }[] } }[] }
} | null

function repoProbeSelection(alias: string, index: number): string {
  return /* GraphQL */ `
    ${alias}: repository(owner: $owner${index}, name: $name${index}) {
      nameWithOwner
      pullRequests(first: 1, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes {
        number
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      } }
    }`
}

/** Plain-words reason a per-repo probe failed, naming the token permission to add. */
function repoProblem(repo: string, error: GraphqlError, fineGrained: boolean): string {
  const path = error.path?.join('.') ?? ''
  if (path.includes('statusCheckRollup'))
    return `GitHub token can't read CI checks on ${repo}: add Commit statuses (read) and Actions (read)`
  if (path.includes('pullRequests')) return `GitHub token can't read pull requests on ${repo}: add Pull requests (read)`
  if (fineGrained)
    return `GitHub token can't see ${repo}: set the token's resource owner to ${repo.split('/')[0]}, select the repo, and check the org approved the token`
  return `GitHub token can't see ${repo} (${error.type ?? error.message}): check the repo name and the token's access`
}

/**
 * Checks once at startup what GITHUB_TOKEN can actually read. GitHub search quietly returns
 * nothing for repos a token can't see, so without this a bad token just looks like "no PRs".
 */
export async function checkGithubToken(): Promise<string[]> {
  if (!env.githubToken) return []
  const kind = TOKEN_KINDS.find(([prefix]) => env.githubToken!.startsWith(prefix))?.[1] ?? 'token'
  const fineGrained = kind === 'fine-grained token'
  const repos = env.githubRepos.map((repo) => {
    const [owner = '', name = ''] = repo.split('/')
    return { repo, owner, name }
  })

  const variableDefs = repos.flatMap((_, i) => [`$owner${i}: String!`, `$name${i}: String!`]).join(', ')
  const selections = repos.map((_, i) => repoProbeSelection(`r${i}`, i)).join('\n')
  const variables = Object.fromEntries(repos.flatMap(({ owner, name }, i) => [[`owner${i}`, owner], [`name${i}`, name]]))
  const query = `query TokenCheck${variableDefs ? `(${variableDefs})` : ''} { viewer { login }\n${selections}\n}`

  let result: GraphqlResult<{ viewer: { login: string } } & Record<string, RepoProbe>>
  try {
    result = await githubGraphqlRaw(query, variables)
  } catch (error) {
    // The HTTP failure is already logged; it's also the only thing worth showing.
    return [error instanceof Error ? error.message : String(error)]
  }

  const problems: string[] = []
  const login = result.data?.viewer?.login ?? 'unknown user'

  const scopes = result.headers.get('x-oauth-scopes')
  if (scopes !== null) {
    const granted = scopes.split(',').map((scope) => scope.trim())
    if (!granted.includes('repo')) problems.push('GitHub token is missing the "repo" scope')
    if (!granted.some((scope) => ['read:org', 'write:org', 'admin:org'].includes(scope)))
      problems.push('GitHub token is missing the "read:org" scope')
  }

  const expiry = result.headers.get('github-authentication-token-expiration')
  if (expiry) {
    const daysLeft = Math.floor((Date.parse(expiry) - Date.now()) / 86_400_000)
    if (daysLeft < EXPIRY_WARNING_DAYS) problems.push(`GitHub token expires in ${Math.max(daysLeft, 0)} days (${expiry})`)
  }

  repos.forEach(({ repo }, i) => {
    const error = result.errors.find((e) => e.path?.[0] === `r${i}`)
    if (error) problems.push(repoProblem(repo, error, fineGrained))
  })
  for (const error of result.errors.filter((e) => !String(e.path?.[0] ?? '').startsWith('r')))
    problems.push(`GitHub token check failed: ${formatGraphqlError(error)}`)

  const readable = repos.filter((_, i) => result.data?.[`r${i}`] && !result.errors.some((e) => e.path?.[0] === `r${i}`))
  console.log(
    `[github] ${kind} for ${login}` +
      (scopes !== null ? `, scopes: ${scopes || 'none'}` : '') +
      (expiry ? `, expires ${expiry}` : ', no expiry') +
      (repos.length ? `; can read ${readable.map((r) => r.repo).join(', ') || 'none of GITHUB_REPOS'}` : '; GITHUB_REPOS is empty, no repo checked'),
  )
  for (const problem of problems) console.warn(`[github] ${problem}`)
  return problems
}

const GITHUB_REST = 'https://api.github.com'

async function githubRest(
  path: string,
  accept = 'application/vnd.github+json',
  { method = 'GET', body }: { method?: string; body?: unknown } = {},
): Promise<Response> {
  if (!env.githubToken) throw new IntegrationNotConfigured('GITHUB_TOKEN is not set in .env.local')
  const response = await fetch(`${GITHUB_REST}${path}`, {
    method,
    headers: {
      authorization: `bearer ${env.githubToken}`,
      accept,
      'x-github-api-version': '2022-11-28',
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    // Asset downloads redirect to signed storage; fetch drops the token on the cross-origin hop.
    redirect: 'follow',
  })
  if (!response.ok) {
    const message = describeHttpFailure(response.status, await response.text(), response.headers)
    console.error(`[github] ${path}: ${message}`)
    throw new Error(message)
  }
  return response
}

export type ReleaseAsset = { id: number; name: string; contentType: string; size: number; downloadUrl: string }

type RawRelease = {
  assets: { id: number; name: string; content_type: string; size: number; browser_download_url: string }[]
}

/**
 * One page of a repo's releases (newest first, drafts included when the token can push), as the
 * assets they hold. Draft releases have no public download URL, so their files can only be
 * fetched through the API by id.
 */
export async function getReleaseAssets(repo: string, page: number): Promise<{ assets: ReleaseAsset[]; more: boolean }> {
  const response = await githubRest(`/repos/${repo}/releases?per_page=100&page=${page}`)
  const releases = (await response.json()) as RawRelease[]
  return {
    assets: releases.flatMap((release) =>
      release.assets.map((asset) => ({
        id: asset.id,
        name: asset.name,
        contentType: asset.content_type,
        size: asset.size,
        downloadUrl: asset.browser_download_url,
      })),
    ),
    more: releases.length === 100,
  }
}

/** The asset's bytes, streamed. */
export async function downloadReleaseAsset(repo: string, id: number): Promise<Response> {
  return githubRest(`/repos/${repo}/releases/assets/${id}`, 'application/octet-stream')
}

/* ---------- Activity ---------- */

export type RawEvent = {
  id: string
  type: string
  created_at: string
  repo: { name: string }
  payload: {
    action?: string
    ref?: string
    ref_type?: string
    number?: number
    pull_request?: { number: number; head?: { ref?: string } }
    review?: { state: string; html_url: string; submitted_at: string }
    comment?: { html_url: string; body?: string; created_at: string }
    issue?: { number: number; title: string; html_url: string; pull_request?: object; user?: { login: string } }
  }
}

const EVENT_PAGES = 3

/**
 * Your own events, newest first: pushes, PR actions, reviews and comments, private repos
 * included because the token is yours. GitHub keeps 300 at most, so this covers days to weeks.
 */
export async function getUserEvents(login: string): Promise<{ events: RawEvent[]; capped: boolean }> {
  const events: RawEvent[] = []
  for (let page = 1; page <= EVENT_PAGES; page++) {
    let batch: RawEvent[]
    try {
      batch = (await (await githubRest(`/users/${login}/events?per_page=100&page=${page}`)).json()) as RawEvent[]
    } catch (error) {
      // Past the last page GitHub answers 422; anything before it is still good.
      if (page > 1 && error instanceof Error && error.message.includes('422')) break
      throw error
    }
    events.push(...batch)
    // GitHub stops near 300 rather than exactly at it, so reaching the last page means the cap
    // was hit; stopping earlier means the feed really ended.
    if (batch.length < 100 && page < EVENT_PAGES) return { events, capped: false }
  }
  return { events, capped: true }
}

export type RawActivityPr = {
  number: number
  title: string
  url: string
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  isDraft: boolean
  createdAt: string
  mergedAt: string | null
  headRefName: string
  body: string
  repository: { nameWithOwner: string }
  author: RawActor | null
}

export type RawActivityReview = {
  state: 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | 'DISMISSED' | 'PENDING'
  submittedAt: string | null
  url: string
  comments: { totalCount: number }
}

const ACTIVITY_PR_FIELDS = /* GraphQL */ `
  number title url state isDraft createdAt mergedAt headRefName body
  repository { nameWithOwner }
  author { login avatarUrl(size: 48) }`

const ACTIVITY_SEARCH_PAGES = 3

/** PRs matching a search, each with the reviews `login` left on it. */
export async function searchActivityPrs(
  query: string,
  login: string,
): Promise<(RawActivityPr & { reviews: { nodes: RawActivityReview[] } })[]> {
  type Page = {
    search: {
      pageInfo: { hasNextPage: boolean; endCursor: string | null }
      nodes: ((RawActivityPr & { reviews: { nodes: RawActivityReview[] } }) | Record<string, never>)[]
    }
  }
  const prs: (RawActivityPr & { reviews: { nodes: RawActivityReview[] } })[] = []
  let after: string | null = null
  for (let page = 0; page < ACTIVITY_SEARCH_PAGES; page++) {
    const { search }: Page = await githubGraphql<Page>(
      `query ActivitySearch($q: String!, $after: String, $login: String!) {
        search(type: ISSUE, query: $q, first: 50, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { ... on PullRequest { ${ACTIVITY_PR_FIELDS}
            reviews(author: $login, first: 30) { nodes { state submittedAt url comments { totalCount } } }
          } }
        }
      }`,
      { q: query, after, login },
    )
    prs.push(...search.nodes.filter((node): node is RawActivityPr & { reviews: { nodes: RawActivityReview[] } } => 'number' in node))
    if (!search.pageInfo.hasNextPage) break
    after = search.pageInfo.endCursor
  }
  return prs
}

const PR_LOOKUP_CHUNK = 25

/** Titles, authors and states for PRs the events feed only names by number. */
export async function getPrsByNumber(refs: { repo: string; number: number }[]): Promise<RawActivityPr[]> {
  const prs: RawActivityPr[] = []
  for (let start = 0; start < refs.length; start += PR_LOOKUP_CHUNK) {
    const chunk = refs.slice(start, start + PR_LOOKUP_CHUNK)
    const selections = chunk
      .map(({ repo, number }, i) => {
        const [owner, name] = repo.split('/')
        if (!Number.isInteger(number)) throw new Error(`Unexpected PR number ${number}`)
        return `p${i}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) {
          pullRequest(number: ${number}) { ${ACTIVITY_PR_FIELDS} }
        }`
      })
      .join('\n')
    const { data, errors } = await githubGraphqlRaw<Record<string, { pullRequest: RawActivityPr | null } | null>>(
      `query PrsByNumber {\n${selections}\n}`,
      {},
    )
    // A PR in a repo the token can't see comes back as a per-alias error; the rest still count.
    for (const error of errors) console.warn(`[github] ${formatGraphqlError(error)}`)
    for (const entry of Object.values(data ?? {})) if (entry?.pullRequest) prs.push(entry.pullRequest)
  }
  return prs
}

/** Posts a comment on a PR's conversation, as you. Returns the comment's link. */
export async function commentOnPr(repo: string, number: number, body: string): Promise<string> {
  const response = await githubRest(`/repos/${repo}/issues/${number}/comments`, 'application/vnd.github+json', {
    method: 'POST',
    body: { body },
  })
  return ((await response.json()) as { html_url: string }).html_url
}


export type RawMember = { login: string; name: string | null; avatarUrl: string }

/** A team's members, child teams included, for naming who to nudge. Needs read:org. */
export async function getTeamMembers(org: string, slug: string): Promise<RawMember[]> {
  const data = await githubGraphql<{ organization: { team: { members: { nodes: RawMember[] } } | null } | null }>(
    `query TeamMembers($org: String!, $slug: String!) {
      organization(login: $org) { team(slug: $slug) { members(first: 100) { nodes { login name avatarUrl(size: 48) } } } }
    }`,
    { org, slug },
  )
  return data.organization?.team?.members.nodes ?? []
}
