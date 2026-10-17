import { ChevronDown } from 'lucide-react'
import { useId, useState, type ReactNode } from 'react'

/** Collapsed panels by title, shared across PRs: collapsing "Description" keeps it collapsed everywhere. */
const COLLAPSED_STORAGE_KEY = 'workbench-pr-collapsed-panels'

function readCollapsed(): Set<string> {
  try {
    const stored: unknown = JSON.parse(localStorage.getItem(COLLAPSED_STORAGE_KEY) ?? '[]')
    return new Set(Array.isArray(stored) ? stored.filter((title): title is string => typeof title === 'string') : [])
  } catch {
    return new Set()
  }
}

function writeCollapsed(collapsed: Set<string>) {
  try {
    localStorage.setItem(COLLAPSED_STORAGE_KEY, JSON.stringify([...collapsed]))
  } catch {
    // Storage blocked: the panel still collapses for this page load.
  }
}

export function Panel({
  title,
  aside,
  actions,
  children,
}: {
  title: string
  aside?: ReactNode
  /** Controls beside the header, outside the collapse toggle (a button can't hold buttons). */
  actions?: ReactNode
  children: ReactNode
}) {
  const [open, setOpen] = useState(() => !readCollapsed().has(title))
  const bodyId = useId()

  function toggle() {
    const collapsed = readCollapsed()
    if (open) collapsed.add(title)
    else collapsed.delete(title)
    writeCollapsed(collapsed)
    setOpen(!open)
  }

  return (
    <section className="rounded-lg border border-border bg-card">
      <div className={`flex items-center ${open ? 'border-b border-border' : ''}`}>
        <button
          type="button"
          onClick={toggle}
          aria-expanded={open}
          aria-controls={bodyId}
          className={`flex min-w-0 flex-1 items-center justify-between gap-3 py-2.5 pl-4 text-left hover:bg-accent/50 ${
            actions ? 'pr-2' : 'pr-4'
          } ${open ? 'rounded-tl-lg' : 'rounded-l-lg'} ${actions ? '' : open ? 'rounded-tr-lg' : 'rounded-r-lg'}`}
        >
          <h2 className="flex items-center gap-1.5 text-sm font-semibold">
            <ChevronDown className={`size-4 text-muted-foreground transition-transform ${open ? '' : '-rotate-90'}`} />
            {title}
          </h2>
          {aside && <div className="text-xs text-muted-foreground">{aside}</div>}
        </button>
        {actions && <div className="flex shrink-0 items-center pr-2">{actions}</div>}
      </div>
      <div id={bodyId} hidden={!open} className="px-4 py-3">
        {children}
      </div>
    </section>
  )
}
