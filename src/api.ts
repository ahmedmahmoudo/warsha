import type { PrScope, PrsResponse } from '../shared/prs'

export class ApiError extends Error {
  constructor(
    message: string,
    readonly setup: boolean,
  ) {
    super(message)
  }
}

export async function fetchPrs(scope: PrScope, fresh = false): Promise<PrsResponse> {
  const response = await fetch(`/api/prs?scope=${scope}${fresh ? '&fresh=1' : ''}`)
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string; setup?: boolean }
    throw new ApiError(body.error ?? `Request failed (${response.status})`, body.setup ?? false)
  }
  return response.json() as Promise<PrsResponse>
}
