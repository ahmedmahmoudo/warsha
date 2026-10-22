import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo } from 'react'
import type { Pr } from '../shared/prs'
import {
  prRef,
  ticketRef,
  type Note,
  type ParkResponse,
  type Parked,
  type Pin,
  type PostTarget,
  type StoreResponse,
  type Todo,
} from '../shared/store'
import { ApiError } from './api'

/** Pins, notes and todos: one query for all of them, and mutations that refresh it. */

const STORE_KEY = ['store']

async function send<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`/api/store${path}`, {
    method,
    headers: { 'content-type': 'application/json', 'x-warsha-action': '1' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const result = (await response.json().catch(() => ({}))) as T & { error?: string }
  if (!response.ok) throw new ApiError(result.error ?? `Request failed (${response.status})`, false)
  return result
}

export function useStore() {
  return useQuery({
    queryKey: STORE_KEY,
    queryFn: async (): Promise<StoreResponse> => {
      const response = await fetch('/api/store')
      if (!response.ok) throw new ApiError(`Couldn't load pins and notes (${response.status})`, false)
      return response.json() as Promise<StoreResponse>
    },
    staleTime: 30_000,
  })
}

/** Notes keyed by ref, for showing a note wherever its ticket or PR appears. */
export function useNotes(): Map<string, Note> {
  const { data } = useStore()
  return new Map((data?.notes ?? []).map((note) => [note.ref, note]))
}

export function usePins(): Map<string, Pin> {
  const { data } = useStore()
  return new Map((data?.pins ?? []).map((pin) => [pin.ref, pin]))
}

function useStoreMutation<V, R>(run: (variables: V) => Promise<R>) {
  const queryClient = useQueryClient()
  return useMutation({ mutationFn: run, onSuccess: () => queryClient.invalidateQueries({ queryKey: STORE_KEY }) })
}

export const usePin = () => useStoreMutation((pin: { ref: string; title: string; url: string | null }) => send<Pin>('POST', '/pins', pin))
export const useUnpin = () =>
  useStoreMutation((ref: string) => send<{ removed: boolean }>('DELETE', `/pins?ref=${encodeURIComponent(ref)}`))
export const useSaveNote = () =>
  useStoreMutation((note: { ref: string; body: string }) => send<{ note: Note | null }>('PUT', '/notes', note))
export const useAddTodo = () =>
  useStoreMutation((todo: { text: string; ref?: string | null; dueDate?: string | null }) => send<Todo>('POST', '/todos', todo))
export const useUpdateTodo = () =>
  useStoreMutation(({ id, ...change }: { id: number; text?: string; done?: boolean; dueDate?: string | null }) =>
    send<Todo>('PATCH', `/todos/${id}`, change),
  )
export const useDeleteTodo = () => useStoreMutation((id: number) => send<{ removed: boolean }>('DELETE', `/todos/${id}`))

export const usePark = () =>
  useStoreMutation(
    (item: { ref: string; title: string; url: string | null; reason?: string | null; until?: string | null; postTo?: PostTarget[] }) =>
      send<ParkResponse>('POST', '/parked', item),
  )
export const useUnpark = () =>
  useStoreMutation((ref: string) => send<{ removed: boolean }>('DELETE', `/parked?ref=${encodeURIComponent(ref)}`))

function localToday(): string {
  const now = new Date()
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`
}

/**
 * What's parked right now: an item whose "until" date has passed is back in play. A PR counts as
 * parked when it or any of its tickets is.
 */
export function useParking() {
  const { data } = useStore()
  const today = localToday()
  // Stable between renders until the parked list changes, so pages filtering with it don't redo the work.
  return useMemo(() => {
    const active = new Map((data?.parked ?? []).filter((item) => !item.until || item.until >= today).map((item) => [item.ref, item]))
    const forPr = (pr: Pick<Pr, 'repo' | 'number' | 'tickets'>): Parked | undefined =>
      active.get(prRef(pr.repo, pr.number)) ?? pr.tickets.map((ticket) => active.get(ticketRef(ticket.key))).find(Boolean)
    return {
      all: [...active.values()],
      get: (ref: string) => active.get(ref),
      isParked: (ref: string) => active.has(ref),
      forPr,
      forTicket: (key: string) => active.get(ticketRef(key)),
    }
  }, [data?.parked, today])
}

