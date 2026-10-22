import { Link, Outlet } from '@tanstack/react-router'
import { Settings } from 'lucide-react'

export function AppShell() {
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-10 border-b border-border bg-card/90 backdrop-blur">
        <div className="mx-auto flex h-12 max-w-6xl items-center gap-6 px-4">
          <span className="text-sm font-semibold tracking-tight">Warsha</span>
          <nav className="flex items-center gap-1 text-sm">
            <Link
              to="/"
              className="rounded-md px-2.5 py-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              activeProps={{ className: 'bg-muted text-foreground!' }}
              activeOptions={{ exact: true }}
            >
              Today
            </Link>
            <Link
              to="/prs"
              search={{ scope: 'mine' }}
              className="rounded-md px-2.5 py-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              activeProps={{ className: 'bg-muted text-foreground!' }}
            >
              Pull requests
            </Link>
            <Link
              to="/activity"
              search={{}}
              className="rounded-md px-2.5 py-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              activeProps={{ className: 'bg-muted text-foreground!' }}
            >
              Activity
            </Link>
            <Link
              to="/calendar"
              search={{}}
              className="rounded-md px-2.5 py-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              activeProps={{ className: 'bg-muted text-foreground!' }}
            >
              Calendar
            </Link>
          </nav>
          <Link
            to="/settings"
            aria-label="Settings"
            title="Settings"
            className="ml-auto rounded-md p-1.5 text-muted-foreground hover:bg-accent hover:text-foreground"
            activeProps={{ className: 'bg-muted text-foreground!' }}
          >
            <Settings className="size-4" />
          </Link>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">
        <Outlet />
      </main>
    </div>
  )
}
