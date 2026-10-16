/**
 * Stale-while-revalidate: a cached value is served immediately and, once older than
 * `staleAfterMs`, refreshed in the background. Upstream APIs are seconds away from here,
 * so nothing user-facing should wait on them except the very first load.
 */
export function createSwrCache<K, V>({ load, staleAfterMs }: { load: (key: K) => Promise<V>; staleAfterMs: number }) {
  const entries = new Map<K, { at: number; value: V }>()
  const inflight = new Map<K, Promise<V>>()

  function refresh(key: K): Promise<V> {
    const running = inflight.get(key)
    if (running) return running
    const promise = load(key)
      .then((value) => {
        entries.set(key, { at: Date.now(), value })
        return value
      })
      .finally(() => inflight.delete(key))
    inflight.set(key, promise)
    return promise
  }

  return {
    async get(key: K, { force = false } = {}): Promise<V> {
      const entry = entries.get(key)
      if (!entry || force) return refresh(key)
      if (Date.now() - entry.at > staleAfterMs)
        refresh(key).catch((error: unknown) => console.error('Background refresh failed', error))
      return entry.value
    },
    warm(key: K) {
      refresh(key).catch((error: unknown) => console.error('Warm-up failed', error))
    },
  }
}
