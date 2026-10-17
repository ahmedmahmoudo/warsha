/**
 * Workbench's own data, kept in its database. A `ref` names what an item is about:
 * "ticket:MX-2481" or "pr:everlab-au/ev-admin#18820".
 */

export type Ref = string

export const ticketRef = (key: string): Ref => `ticket:${key}`
export const prRef = (repo: string, number: number): Ref => `pr:${repo}#${number}`

/** Something you've chosen to focus on; it stays until you unpin it or it's done. */
export type Pin = { ref: Ref; title: string; url: string | null; pinnedAt: string }

export type Note = { ref: Ref; body: string; updatedAt: string }

export type Todo = {
  id: number
  text: string
  ref: Ref | null
  /** YYYY-MM-DD. */
  dueDate: string | null
  doneAt: string | null
  createdAt: string
}

/**
 * Set aside on purpose: kept out of everything asking for your attention until you unpark it, or
 * until `until` (YYYY-MM-DD) passes. Parking a ticket parks its PRs too.
 */
export type Parked = { ref: Ref; title: string; url: string | null; reason: string | null; until: string | null; parkedAt: string }

export type StoreResponse = { pins: Pin[]; notes: Note[]; todos: Todo[]; parked: Parked[] }

/** Where a park reason can be posted, and how each post went. */
export type PostTarget = { kind: 'linear'; key: string } | { kind: 'github'; repo: string; number: number }
export type PostResult = { label: string; url: string | null; error: string | null }

export type ParkResponse = { parked: Parked; posted: PostResult[] }

/** The comment a park reason becomes on Linear and GitHub; the popover previews exactly this. */
export function parkComment(reason: string, until: string | null): string {
  const back = until
    ? `\n\nPicking this back up on ${new Date(`${until}T12:00:00Z`).toLocaleDateString('en-AU', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' })}.`
    : ''
  return `Parked: ${reason.trim()}${back}`
}

