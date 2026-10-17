import { createRootRoute, createRoute, createRouter } from '@tanstack/react-router'
import type { ActivityView } from '../shared/activity'
import type { PrScope, WaitingOn } from '../shared/prs'
import { AppShell } from './components/AppShell'
import { ActivityPage } from './routes/ActivityPage'
import { CalendarPage } from './routes/CalendarPage'
import { PrDetailPage } from './routes/PrDetailPage'
import { PullRequestsPage } from './routes/PullRequestsPage'
import { TodayPage } from './routes/TodayPage'
import { SettingsPage } from './routes/SettingsPage'

const rootRoute = createRootRoute({ component: AppShell })

const indexRoute = createRoute({ getParentRoute: () => rootRoute, path: '/', component: TodayPage })

const SCOPES: readonly PrScope[] = ['mine', 'reviewing', 'team']

/** A summary card the list is filtered to; absent means everything. */
export type PrView = WaitingOn | 'mismatches'
const VIEWS: readonly PrView[] = ['you', 'merge', 'ci', 'reviewer', 'draft', 'mismatches']

const prsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/prs',
  validateSearch: (search: Record<string, unknown>): { scope: PrScope; view?: PrView } => ({
    scope: SCOPES.find((scope) => scope === search.scope) ?? 'mine',
    view: VIEWS.find((view) => view === search.view),
  }),
  component: PullRequestsPage,
})

const prDetailRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/prs/$owner/$repo/$number',
  // The list's tab, so "back" returns to the same view.
  validateSearch: (search: Record<string, unknown>): { scope: PrScope } => ({
    scope: SCOPES.find((scope) => scope === search.scope) ?? 'mine',
  }),
  component: PrDetailPage,
})

const ACTIVITY_VIEWS: readonly ActivityView[] = ['day', 'week', 'month']

const activityRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/activity',
  // `date` is any day in the range; absent means today.
  validateSearch: (search: Record<string, unknown>): { view?: ActivityView; date?: string } => ({
    view: ACTIVITY_VIEWS.find((view) => view === search.view),
    date: typeof search.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(search.date) ? search.date : undefined,
  }),
  component: ActivityPage,
})

const calendarRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/calendar',
  // `date` is any day in the range; absent means today.
  validateSearch: (search: Record<string, unknown>): { view?: ActivityView; date?: string } => ({
    view: ACTIVITY_VIEWS.find((view) => view === search.view),
    date: typeof search.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(search.date) ? search.date : undefined,
  }),
  component: CalendarPage,
})

const settingsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/settings',
  // `google` is how a Google sign-in went: "connected", or what went wrong.
  validateSearch: (search: Record<string, unknown>): { google?: string } => ({
    google: typeof search.google === 'string' ? search.google : undefined,
  }),
  component: SettingsPage,
})

export const router = createRouter({ routeTree: rootRoute.addChildren([indexRoute, prsRoute, prDetailRoute, activityRoute, calendarRoute, settingsRoute]) })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}
