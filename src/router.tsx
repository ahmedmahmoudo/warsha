import { createRootRoute, createRoute, createRouter, redirect } from '@tanstack/react-router'
import type { PrScope } from '../shared/prs'
import { AppShell } from './components/AppShell'
import { PullRequestsPage } from './routes/PullRequestsPage'
import { SettingsPage } from './routes/SettingsPage'

const rootRoute = createRootRoute({ component: AppShell })

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  beforeLoad: () => {
    throw redirect({ to: '/prs', search: { scope: 'mine' } })
  },
})

const SCOPES: readonly PrScope[] = ['mine', 'reviewing', 'team']

const prsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/prs',
  validateSearch: (search: Record<string, unknown>): { scope: PrScope } => ({
    scope: SCOPES.find((scope) => scope === search.scope) ?? 'mine',
  }),
  component: PullRequestsPage,
})

const settingsRoute = createRoute({ getParentRoute: () => rootRoute, path: '/settings', component: SettingsPage })

export const router = createRouter({ routeTree: rootRoute.addChildren([indexRoute, prsRoute, settingsRoute]) })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}
