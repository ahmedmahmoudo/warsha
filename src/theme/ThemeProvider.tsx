import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import {
  THEME_STORAGE_KEY,
  applyTheme,
  darkSchemeQuery,
  readPreference,
  resolveTheme,
  writePreference,
  type ResolvedTheme,
  type ThemePreference,
} from './theme'

type ThemeContextValue = {
  preference: ThemePreference
  resolved: ResolvedTheme
  setPreference: (preference: ThemePreference) => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [preference, setPreferenceState] = useState(readPreference)
  const [resolved, setResolved] = useState(() => resolveTheme(preference))

  useEffect(() => {
    const update = () => setResolved(resolveTheme(preference))
    update()
    if (preference !== 'system') return
    // Follows the OS live, e.g. macOS switching appearance at sunset or from Control Centre.
    const query = darkSchemeQuery()
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [preference])

  useEffect(() => applyTheme(resolved), [resolved])

  // Keeps other open Workbench tabs in step when the choice changes in one of them.
  useEffect(() => {
    const onStorage = (event: StorageEvent) => {
      if (event.key === THEME_STORAGE_KEY) setPreferenceState(readPreference())
    }
    window.addEventListener('storage', onStorage)
    return () => window.removeEventListener('storage', onStorage)
  }, [])

  function setPreference(next: ThemePreference) {
    writePreference(next)
    setPreferenceState(next)
  }

  return <ThemeContext.Provider value={{ preference, resolved, setPreference }}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext)
  if (!context) throw new Error('useTheme must be used inside ThemeProvider')
  return context
}
