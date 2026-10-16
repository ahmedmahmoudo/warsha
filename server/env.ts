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

export const env = {
  githubToken: process.env.GITHUB_TOKEN || null,
  githubRepos: list(process.env.GITHUB_REPOS),
  githubTeam: list(process.env.GITHUB_TEAM),
  linearApiKey: process.env.LINEAR_API_KEY || null,
}
