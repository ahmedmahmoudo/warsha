import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RouterProvider } from '@tanstack/react-router'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { router } from './router'
import { ThemeProvider } from './theme/ThemeProvider'
import './styles.css'

/**
 * Opening a page or coming back to the window refetches in the background: what's on screen stays
 * while the new answer loads, so a PR fixed elsewhere updates without the page blanking.
 */
const queryClient = new QueryClient({
  defaultOptions: { queries: { refetchOnWindowFocus: 'always', refetchOnMount: 'always', retry: 1 } },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
)
