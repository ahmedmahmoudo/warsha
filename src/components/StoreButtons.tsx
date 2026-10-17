import { CircleParking, Pin, PinOff, StickyNote } from 'lucide-react'
import { Popover } from 'radix-ui'
import { useEffect, useState } from 'react'
import { usePark, useParking, usePin, usePins, useSaveNote, useNotes, useUnpark, useUnpin } from '../store'
import { Button } from '@/components/ui/button'
import { parkComment, type PostResult, type PostTarget } from '../../shared/store'
import { timeAgo } from '../format'

const iconButton = 'rounded-md p-1 text-faint hover:bg-accent hover:text-foreground disabled:opacity-50'

/** Pins an item to Today's focus, or unpins it. */
export function PinButton({ refId, title, url }: { refId: string; title: string; url: string | null }) {
  const pinned = usePins().has(refId)
  const pin = usePin()
  const unpin = useUnpin()
  const busy = pin.isPending || unpin.isPending
  return (
    <button
      type="button"
      disabled={busy}
      onClick={() => (pinned ? unpin.mutate(refId) : pin.mutate({ ref: refId, title, url }))}
      aria-label={pinned ? 'Unpin from focus' : 'Pin to focus'}
      title={pinned ? 'Unpin from focus' : 'Pin to focus'}
      className={`${iconButton} ${pinned ? 'text-info' : ''}`}
    >
      {pinned ? <PinOff className="size-3.5" /> : <Pin className="size-3.5" />}
    </button>
  )
}

/** A PR an item covers, for posting the park reason to. */
export type PrTarget = { repo: string; number: number }

/** Where a park reason can go for this item: its Linear ticket and its PRs. */
function postTargets(refId: string, prs: PrTarget[]): (PostTarget & { label: string })[] {
  const targets: (PostTarget & { label: string })[] = []
  if (refId.startsWith('ticket:')) {
    const key = refId.slice('ticket:'.length)
    targets.push({ kind: 'linear', key, label: `Linear ${key}` })
  }
  const fromRef = refId.match(/^pr:(.+)#(\d+)$/)
  const all = fromRef ? [{ repo: fromRef[1]!, number: Number(fromRef[2]) }, ...prs] : prs
  const seen = new Set<string>()
  for (const pr of all) {
    const id = `${pr.repo}#${pr.number}`
    if (seen.has(id)) continue
    seen.add(id)
    targets.push({ kind: 'github', repo: pr.repo, number: pr.number, label: `PR #${pr.number}` })
  }
  return targets
}

const targetId = (target: PostTarget) => (target.kind === 'linear' ? `linear:${target.key}` : `github:${target.repo}#${target.number}`)

/**
 * Parks an item (with an optional reason and return date) so it stops asking for attention, and
 * can post the reason as a comment on its Linear ticket and PRs so the team knows.
 */
export function ParkButton({ refId, title, url, prs = [] }: { refId: string; title: string; url: string | null; prs?: PrTarget[] }) {
  const parked = useParking().get(refId)
  const park = usePark()
  const unpark = useUnpark()
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const [until, setUntil] = useState('')
  const targets = postTargets(refId, prs)
  const [chosen, setChosen] = useState<Set<string>>(new Set())
  const [results, setResults] = useState<PostResult[] | null>(null)
  useEffect(() => {
    if (open) {
      setReason(parked?.reason ?? '')
      setUntil(parked?.until ?? '')
      // Posting is on by default when first parking; re-saving an existing park doesn't repost.
      setChosen(new Set(parked ? [] : targets.map(targetId)))
      setResults(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reset only when the popover opens
  }, [open])

  const postTo = reason.trim() ? targets.filter((target) => chosen.has(targetId(target))) : []

  function save() {
    park.mutate(
      { ref: refId, title, url, reason: reason.trim() || null, until: until || null, postTo },
      {
        onSuccess: ({ posted }) => {
          if (posted.length) setResults(posted)
          else setOpen(false)
        },
      },
    )
  }

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button
          type="button"
          aria-label={parked ? `Parked: ${title}` : `Park ${title}`}
          title={parked ? `Parked${parked.reason ? `: ${parked.reason}` : ''}` : 'Park: stop it asking for attention'}
          className={`${iconButton} ${parked ? 'text-info' : ''}`}
        >
          <CircleParking className="size-3.5" />
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="end"
          sideOffset={6}
          collisionPadding={8}
          className="z-50 flex w-80 flex-col gap-2 rounded-lg border border-border bg-popover p-3 text-sm text-popover-foreground shadow-md"
        >
          <p className="text-xs text-muted-foreground">
            {parked ? 'Parked' : 'Park'} <span className="font-medium text-foreground">{title}</span>
            {parked && ` · ${timeAgo(parked.parkedAt)}`}
          </p>

          {results ? (
            <>
              <p className="text-xs text-good">Parked.</p>
              <ul className="flex flex-col gap-1 text-xs">
                {results.map((result) => (
                  <li key={result.label} className={result.error ? 'text-bad' : 'text-muted-foreground'}>
                    {result.error ? (
                      `Couldn't post to ${result.label}: ${result.error}`
                    ) : (
                      <>
                        Posted to{' '}
                        <a href={result.url ?? undefined} target="_blank" rel="noreferrer" className="text-info hover:underline">
                          {result.label}
                        </a>
                      </>
                    )}
                  </li>
                ))}
              </ul>
              <div className="flex justify-end">
                <Button size="sm" onClick={() => setOpen(false)}>
                  Done
                </Button>
              </div>
            </>
          ) : (
            <>
              <p className="text-xs text-faint">Parked items leave Today, the attention counts and the stuck flags until you unpark them.</p>
              <input
                value={reason}
                onChange={(event) => setReason(event.target.value)}
                maxLength={500}
                placeholder="Why? (optional)"
                className="rounded-md border border-input bg-background px-2 py-1 text-sm outline-none focus:border-ring"
              />
              <label className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
                Bring back on
                <input
                  type="date"
                  value={until}
                  onChange={(event) => setUntil(event.target.value)}
                  className="rounded-md border border-input bg-background px-1.5 py-1 text-xs outline-none focus:border-ring"
                />
              </label>

              {targets.length > 0 && (
                <fieldset className={`flex flex-col gap-1.5 rounded-md border border-border p-2 ${reason.trim() ? '' : 'opacity-60'}`}>
                  <legend className="px-1 text-xs text-muted-foreground">Post the reason as a comment on</legend>
                  <div className="flex flex-wrap gap-x-3 gap-y-1">
                    {targets.map((target) => (
                      <label key={targetId(target)} className="flex items-center gap-1.5 text-xs">
                        <input
                          type="checkbox"
                          disabled={!reason.trim()}
                          checked={chosen.has(targetId(target))}
                          onChange={(event) => {
                            const next = new Set(chosen)
                            if (event.target.checked) next.add(targetId(target))
                            else next.delete(targetId(target))
                            setChosen(next)
                          }}
                        />
                        {target.label}
                      </label>
                    ))}
                  </div>
                  {reason.trim() ? (
                    postTo.length > 0 && (
                      <p className="rounded bg-muted px-2 py-1 text-xs whitespace-pre-wrap text-muted-foreground">
                        {parkComment(reason, until || null)}
                      </p>
                    )
                  ) : (
                    <p className="text-xs text-faint">Add a reason to post it.</p>
                  )}
                </fieldset>
              )}

              {(park.error ?? unpark.error) && <p className="text-xs text-bad">{(park.error ?? unpark.error)?.message}</p>}
              <div className="flex justify-end gap-2">
                {parked && (
                  <Button size="sm" variant="outline" disabled={unpark.isPending} onClick={() => unpark.mutate(refId, { onSuccess: () => setOpen(false) })}>
                    Unpark
                  </Button>
                )}
                <Button size="sm" disabled={park.isPending} onClick={save}>
                  {park.isPending ? (postTo.length ? 'Posting…' : 'Saving…') : postTo.length ? `${parked ? 'Update' : 'Park'} & post` : parked ? 'Update' : 'Park'}
                </Button>
              </div>
            </>
          )}
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}

/** A note on a ticket or PR: the icon fills in when there is one; click to read or edit. */
export function NoteButton({ refId, label }: { refId: string; label: string }) {
  const note = useNotes().get(refId)
  const save = useSaveNote()
  const [open, setOpen] = useState(false)
  const [draft, setDraft] = useState(note?.body ?? '')
  useEffect(() => {
    if (open) setDraft(note?.body ?? '')
  }, [open, note?.body])

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button
          type="button"
          aria-label={note ? `Note on ${label}` : `Add a note to ${label}`}
          title={note ? note.body : 'Add a note'}
          className={`${iconButton} ${note ? 'text-warn' : ''}`}
        >
          <StickyNote className={`size-3.5 ${note ? 'fill-warn-soft' : ''}`} />
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="end"
          sideOffset={6}
          collisionPadding={8}
          className="z-50 flex w-80 flex-col gap-2 rounded-lg border border-border bg-popover p-3 text-sm text-popover-foreground shadow-md"
        >
          <p className="text-xs text-muted-foreground">
            Note on <span className="font-medium text-foreground">{label}</span>
            {note && ` · edited ${timeAgo(note.updatedAt)}`}
          </p>
          <textarea
            autoFocus
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
                save.mutate({ ref: refId, body: draft }, { onSuccess: () => setOpen(false) })
              }
            }}
            rows={4}
            maxLength={4000}
            placeholder="What to remember about this…"
            className="w-full resize-y rounded-md border border-input bg-background px-2 py-1.5 text-sm outline-none focus:border-ring"
          />
          {save.error && <p className="text-xs text-bad">{save.error.message}</p>}
          <div className="flex items-center justify-between gap-2">
            <span className="text-[0.65rem] text-faint">⌘↵ to save</span>
            <div className="flex gap-2">
              {note && (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={save.isPending}
                  onClick={() => save.mutate({ ref: refId, body: '' }, { onSuccess: () => setOpen(false) })}
                >
                  Delete
                </Button>
              )}
              <Button
                size="sm"
                disabled={save.isPending || draft.trim() === (note?.body ?? '')}
                onClick={() => save.mutate({ ref: refId, body: draft }, { onSuccess: () => setOpen(false) })}
              >
                {save.isPending ? 'Saving…' : 'Save'}
              </Button>
            </div>
          </div>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}

/** The note on an item, quoted under it so it's read where it matters. */
export function NoteLine({ refId }: { refId: string }) {
  const note = useNotes().get(refId)
  if (!note) return null
  return <p className="mt-1 line-clamp-2 border-l-2 border-warn/50 pl-2 text-xs text-muted-foreground italic">{note.body}</p>
}

/** Pin and note controls, the same on every row. */
export function ItemControls({ refId, title, url, prs }: { refId: string; title: string; url: string | null; prs?: PrTarget[] }) {
  return (
    <span className="flex shrink-0 items-center">
      <PinButton refId={refId} title={title} url={url} />
      <NoteButton refId={refId} label={title} />
      <ParkButton refId={refId} title={title} url={url} prs={prs} />
    </span>
  )
}
