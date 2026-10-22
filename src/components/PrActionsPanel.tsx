import { useQueryClient } from '@tanstack/react-query'
import { Check, Copy, GitMerge, RefreshCw, Sparkles, TriangleAlert } from 'lucide-react'
import { useState } from 'react'
import type { PrActions, PrDetail } from '../../shared/prDetail'
import { Button } from '@/components/ui/button'
import { runPrAction } from '../api'
import { Panel } from './Panel'

const COPIED_MS = 2000

function CopyButton({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <Button
      variant="outline"
      size="sm"
      onClick={async () => {
        await navigator.clipboard.writeText(text)
        setCopied(true)
        setTimeout(() => setCopied(false), COPIED_MS)
      }}
    >
      {copied ? <Check /> : <Copy />}
      {copied ? 'Copied' : label}
    </Button>
  )
}

/** What happened when an action ran, shown under its buttons. */
type Outcome = { tone: 'good' | 'bad'; text: string } | null

function OutcomeLine({ outcome }: { outcome: Outcome }) {
  if (!outcome) return null
  return <p className={`mt-2 text-xs ${outcome.tone === 'good' ? 'text-good' : 'text-bad'}`}>{outcome.text}</p>
}

function ConflictAction({ detail, conflicts }: { detail: PrDetail; conflicts: NonNullable<PrActions['conflicts']> }) {
  const [launching, setLaunching] = useState(false)
  const [outcome, setOutcome] = useState<Outcome>(null)
  const { pr } = detail

  async function launch() {
    setLaunching(true)
    setOutcome(null)
    try {
      const { path } = await runPrAction(pr.repo, pr.number, 'resolve-conflicts')
      setOutcome({ tone: 'good', text: `Opened a Claude Code session at ${path}. Confirm the folder, then press send.` })
    } catch (error) {
      setOutcome({ tone: 'bad', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setLaunching(false)
    }
  }

  return (
    <div>
      <p className="flex items-center gap-2 text-sm font-medium">
        <TriangleAlert className="size-4 text-bad" />
        Merge conflicts with {pr.baseRef}
      </p>
      <p className="mt-1 text-xs text-muted-foreground">
        Opens a new Claude Code session in the Claude app with the prompt ready: it merges {pr.baseRef} into the branch, resolves
        the conflicts, runs the checks and pushes. You confirm the folder and press send.
      </p>
      {conflicts.checkout ? (
        <p className="mt-1.5 text-xs text-muted-foreground">
          Runs in{' '}
          <span className="font-mono text-foreground">{conflicts.checkout.path}</span>
          {conflicts.checkout.kind === 'worktree'
            ? ', the branch’s worktree.'
            : '; the branch has no worktree yet, so Claude makes one beside it and leaves this checkout alone.'}
        </p>
      ) : (
        <p className="mt-1.5 text-xs text-warn">
          No local clone of {pr.repo} found next to Warsha. Set <code>LOCAL_REPOS</code> in <code>.env.local</code> to
          run it from here, or copy the prompt.
        </p>
      )}
      <div className="mt-2.5 flex flex-wrap gap-2">
        {conflicts.canLaunch && (
          <Button size="sm" onClick={launch} disabled={launching}>
            <Sparkles />
            {launching ? 'Opening…' : 'Open in Claude'}
          </Button>
        )}
        <CopyButton text={conflicts.prompt} label="Copy prompt" />
        {conflicts.command && <CopyButton text={conflicts.command} label="Copy terminal command" />}
      </div>
      <OutcomeLine outcome={outcome} />
      <details className="mt-2 text-xs">
        <summary className="cursor-pointer text-info">Show prompt</summary>
        <pre className="mt-1.5 max-h-64 overflow-auto rounded-md bg-muted p-2.5 whitespace-pre-wrap">{conflicts.prompt}</pre>
      </details>
    </div>
  )
}

function UpdateBranchAction({ detail, update }: { detail: PrDetail; update: NonNullable<PrActions['updateBranch']> }) {
  const queryClient = useQueryClient()
  const [confirming, setConfirming] = useState(false)
  const [running, setRunning] = useState(false)
  const [outcome, setOutcome] = useState<Outcome>(null)
  /** The head this component updated from; once the page shows a newer head, the update has landed. */
  const [updatedFrom, setUpdatedFrom] = useState<string | null>(null)
  const { pr } = detail
  const waitingForGitHub = updatedFrom === update.headOid

  async function updateBranch() {
    setRunning(true)
    setOutcome(null)
    try {
      const { settled } = await runPrAction(pr.repo, pr.number, 'update-branch', { expectedHeadOid: update.headOid })
      setConfirming(false)
      setUpdatedFrom(update.headOid)
      setOutcome({
        tone: 'good',
        text: settled
          ? `Merged ${update.base} into the branch on GitHub. CI will run again.`
          : `GitHub accepted the update and is still applying it; this page catches up on its next refresh.`,
      })
      // Today and the PR list show this PR's status too; have them catch up.
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['pr', pr.repo, String(pr.number)] }),
        queryClient.invalidateQueries({ queryKey: ['prs'] }),
        queryClient.invalidateQueries({ queryKey: ['today'] }),
      ])
    } catch (error) {
      setOutcome({ tone: 'bad', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setRunning(false)
    }
  }

  return (
    <div>
      <p className="flex items-center gap-2 text-sm font-medium">
        <GitMerge className="size-4 text-warn" />
        {update.behindBy} commit{update.behindBy === 1 ? '' : 's'} behind {update.base}
      </p>
      <p className="mt-1 text-xs text-muted-foreground">
        Updating merges {update.base} into <span className="font-mono">{pr.headRef}</span> on GitHub
      </p>
      {update.reason && <p className="mt-1.5 text-xs text-warn">{update.reason}</p>}
      {waitingForGitHub ? null : confirming ? (
        <div className="mt-2.5 rounded-md border border-warn/40 bg-warn-soft/50 p-2.5 text-xs">
          <p>This pushes a merge commit to the PR branch. CI runs again, and branches that dismiss stale reviews lose their approvals.</p>
          <div className="mt-2 flex gap-2">
            <Button size="sm" onClick={updateBranch} disabled={running}>
              {running ? 'Updating…' : 'Update branch'}
            </Button>
            <Button size="sm" variant="outline" onClick={() => setConfirming(false)} disabled={running}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <div className="mt-2.5">
          <Button size="sm" variant="outline" onClick={() => setConfirming(true)} disabled={!update.canUpdate}>
            <RefreshCw />
            Update with {update.base}
          </Button>
        </div>
      )}
      <OutcomeLine outcome={outcome} />
    </div>
  )
}

/** Shown only when there's something to do about the branch. */
export function PrActionsPanel({ detail }: { detail: PrDetail }) {
  const { conflicts, updateBranch } = detail.actions
  if (!conflicts && !updateBranch) return null
  return (
    <Panel title="Actions">
      <div className="flex flex-col gap-4 divide-y divide-border [&>*:not(:first-child)]:pt-4">
        {conflicts && <ConflictAction detail={detail} conflicts={conflicts} />}
        {updateBranch && <UpdateBranchAction detail={detail} update={updateBranch} />}
      </div>
    </Panel>
  )
}
