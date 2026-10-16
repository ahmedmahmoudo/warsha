import { env } from '../env'
import { IntegrationNotConfigured } from './errors'

const GITHUB_GRAPHQL = 'https://api.github.com/graphql'
const SEARCH_PAGE_SIZE = 100
const MAX_SEARCH_PAGES = 3
const DETAIL_CHUNK = 8
/** GitHub's secondary rate limit drops heavy queries fired all at once. */
const DETAIL_CONCURRENCY = 4

async function githubGraphql<T>(query: string, variables: Record<string, unknown>): Promise<T> {
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
  if (!response.ok) throw new Error(`GitHub ${response.status}: ${text.slice(0, 300) || response.statusText}`)

  const json = JSON.parse(text) as { data?: T; errors?: { message: string }[] }
  if (json.errors?.length) throw new Error(`GitHub: ${json.errors.map((e) => e.message).join('; ')}`)
  if (!json.data) throw new Error('GitHub returned no data')
  return json.data
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
  author: { login: string } | null
  repository: { nameWithOwner: string }
  commits: { nodes: { commit: { statusCheckRollup: { state: string; contexts: { nodes: RawCheckContext[] } } | null } }[] }
  reviewThreads: { nodes: { isResolved: boolean; comments: { nodes: { author: { login: string } | null }[] } }[] }
  latestOpinionatedReviews: { nodes: { state: string; author: { login: string } | null }[] }
  reviewRequests: { nodes: { requestedReviewer: { login?: string; name?: string } | null }[] }
}

/**
 * `isRequired` takes the PR number as an argument, so each PR gets its own selection with
 * the number inlined rather than sharing a fragment.
 */
function prSelection(alias: string, idVariable: string, number: number): string {
  if (!Number.isInteger(number)) throw new Error(`Unexpected PR number ${number}`)
  return /* GraphQL */ `
    ${alias}: node(id: ${idVariable}) { ... on PullRequest {
      id number title url body isDraft createdAt updatedAt mergedAt
      headRefName baseRefName additions deletions mergeStateStatus reviewDecision
      author { login }
      repository { nameWithOwner }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber: ${number}) }
          ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: ${number}) }
        } } } } }
      }
      reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { author { login } } } } }
      latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
      reviewRequests(first: 10) { nodes { requestedReviewer {
        ... on User { login }
        ... on Team { name }
        ... on Bot { login }
      } } }
    } }`
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
