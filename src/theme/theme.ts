export type ThemePreference = 'light' | 'dark' | 'system'
export type ResolvedTheme = 'light' | 'dark'

/** Also read by the inline script in index.html, which applies the theme before first paint. */
export const THEME_STORAGE_KEY = 'warsha-theme'

const PREFERENCES: readonly ThemePreference[] = ['light', 'dark', 'system']

export const darkSchemeQuery = () => window.matchMedia('(prefers-color-scheme: dark)')

export function readPreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY)
    return PREFERENCES.find((preference) => preference === stored) ?? 'system'
  } catch {
    return 'system'
  }
}

export function writePreference(preference: ThemePreference) {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, preference)
  } catch {
    // Storage blocked: the choice still applies for this page load.
  }
}

export function resolveTheme(preference: ThemePreference): ResolvedTheme {
  if (preference !== 'system') return preference
  return darkSchemeQuery().matches ? 'dark' : 'light'
}

export function applyTheme(theme: ResolvedTheme) {
  document.documentElement.classList.toggle('dark', theme === 'dark')
}
