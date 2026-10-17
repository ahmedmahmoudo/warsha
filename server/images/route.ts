import { Hono } from 'hono'
import { env } from '../env'
import { downloadReleaseAsset, getReleaseAssets, type ReleaseAsset } from '../integrations/github'

/**
 * Serves images from PR descriptions that the browser can't load itself: files attached to a
 * private repo's releases (often a draft release used to host PR screenshots) need the token.
 * Only release downloads on github.com are proxied, and only for GITHUB_REPOS or repos whose PRs
 * this server has already shown, so it can't be used to read anything else the token can see.
 */

const RELEASE_DOWNLOAD = /^\/([\w.-]+)\/([\w.-]+)\/releases\/download\/[^/]+\/[^/]+$/
const MAX_BYTES = 10 * 1024 * 1024
const MAX_PAGES = 20
const RESCAN_AFTER_MS = 60_000

/** GITHUB_REPOS counts from the start, so an open page still loads its images after a restart. */
const allowedRepos = new Set<string>(env.githubRepos.map((repo) => repo.toLowerCase()))

/** Called when a PR's details are served, so its description's images can be fetched. */
export function allowImagesFrom(repo: string) {
  allowedRepos.add(repo.toLowerCase())
}

/**
 * Assets seen so far for a repo. Releases are read a page at a time and only as far as needed;
 * a later miss carries on from `nextPage`, and once every page is read a miss starts over at
 * most every RESCAN_AFTER_MS (new uploads land on page one).
 */
type AssetIndex = {
  byUrl: Map<string, ReleaseAsset>
  nextPage: number
  complete: boolean
  scannedAt: number
  /** One scan at a time, so a page full of images doesn't race to read the same releases. */
  scanning: Promise<void> | null
}
const indexes = new Map<string, AssetIndex>()

async function scanUntilFound(repo: string, index: AssetIndex, url: string) {
  while (!index.byUrl.has(url) && !index.complete) {
    const { assets, more } = await getReleaseAssets(repo, index.nextPage)
    for (const asset of assets) index.byUrl.set(asset.downloadUrl, asset)
    index.nextPage++
    if (!more || index.nextPage > MAX_PAGES) index.complete = true
  }
  index.scannedAt = Date.now()
}

async function findAsset(repo: string, url: string): Promise<ReleaseAsset | null> {
  let index = indexes.get(repo)
  if (!index) {
    index = { byUrl: new Map(), nextPage: 1, complete: false, scannedAt: 0, scanning: null }
    indexes.set(repo, index)
  }
  while (index.scanning) await index.scanning.catch(() => undefined)
  if (index.byUrl.has(url)) return index.byUrl.get(url)!

  if (index.complete) {
    if (Date.now() - index.scannedAt < RESCAN_AFTER_MS) return null
    index.nextPage = 1
    index.complete = false
  }
  const current = index
  current.scanning = scanUntilFound(repo, current, url).finally(() => {
    current.scanning = null
  })
  await current.scanning
  return current.byUrl.get(url) ?? null
}

export const imagesRoute = new Hono().get('/', async (c) => {
  let url: URL
  try {
    url = new URL(c.req.query('url') ?? '')
  } catch {
    return c.json({ error: 'Not a URL' }, 400)
  }
  const match = url.protocol === 'https:' && url.hostname === 'github.com' ? url.pathname.match(RELEASE_DOWNLOAD) : null
  if (!match) return c.json({ error: 'Only GitHub release downloads can be proxied' }, 400)

  const repo = `${match[1]}/${match[2]}`.toLowerCase()
  if (!allowedRepos.has(repo)) return c.json({ error: `Open a ${repo} PR first` }, 403)

  const asset = await findAsset(repo, `${url.origin}${url.pathname}`)
  if (!asset) {
    console.warn(`[images] No release asset at ${url.pathname}`)
    return c.json({ error: 'Image not found' }, 404)
  }
  if (!asset.contentType.startsWith('image/') || asset.size > MAX_BYTES)
    return c.json({ error: 'Not an image, or too large' }, 415)

  const download = await downloadReleaseAsset(repo, asset.id)
  return new Response(download.body, {
    headers: {
      'content-type': asset.contentType,
      'content-length': String(asset.size),
      'cache-control': 'private, max-age=3600',
      // An SVG opened directly must not run script on the app's origin.
      'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'",
      'x-content-type-options': 'nosniff',
    },
  })
})
