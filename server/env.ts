try {
  process.loadEnvFile('.env.local')
} catch {
  // No .env.local: each integration reports itself as unconfigured instead.
}

function list(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
}

/** "owner/repo=/path/to/clone" pairs, keyed by lower-case repo. */
function repoPaths(value: string | undefined): Map<string, string> {
  return new Map(
    list(value).flatMap((pair) => {
      const [repo, path] = pair.split('=').map((part) => part.trim())
      return repo && path ? [[repo.toLowerCase(), path] as [string, string]] : []
    }),
  )
}

export const env = {
  githubToken: process.env.GITHUB_TOKEN || null,
  githubRepos: list(process.env.GITHUB_REPOS),
  githubTeam: list(process.env.GITHUB_TEAM),
  linearApiKey: process.env.LINEAR_API_KEY || null,
  /** OAuth Desktop client for Google Calendar; you connect your account from Settings. */
  googleClientId: process.env.GOOGLE_CLIENT_ID || null,
  googleClientSecret: process.env.GOOGLE_CLIENT_SECRET || null,
  /** Where each repo is cloned on this machine; unset repos are looked for next to this project. */
  localRepos: repoPaths(process.env.LOCAL_REPOS),
  /** Where "a day" and "a week" start for the Activity page. */
  timeZone: process.env.TIMEZONE || 'Australia/Sydney',
  /** Workbench's own data (pins, notes, todos). */
  dbPath: process.env.DB_PATH || 'data/workbench.sqlite',
}
