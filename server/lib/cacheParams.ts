/** Never rebuild more often than this, however small a maxAge a page asks for. */
const MIN_MAX_AGE_MS = 5_000

/**
 * Reads `?fresh=1` (rebuild now) and `?maxAge=<seconds>` (take nothing older) from a request,
 * for passing to a cache's get().
 */
export function cacheOptions(query: (name: string) => string | undefined): { force: boolean; maxAgeMs?: number } {
  const seconds = Number(query('maxAge'))
  return {
    force: query('fresh') === '1',
    maxAgeMs: Number.isFinite(seconds) && seconds > 0 ? Math.max(seconds * 1000, MIN_MAX_AGE_MS) : undefined,
  }
}
