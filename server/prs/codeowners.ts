/**
 * Reads a CODEOWNERS file the way GitHub does: gitignore-style patterns, and the last
 * matching line wins. A line with a pattern but no owners removes ownership for those paths.
 */

type Rule = { pattern: RegExp; owners: string[] }

export type Codeowners = { ownersOf(path: string): string[] }

function escapeRegex(text: string): string {
  return text.replace(/[.+^${}()|[\]\\]/g, '\\$&')
}

function globToRegex(glob: string): string {
  let out = ''
  for (let i = 0; i < glob.length; i++) {
    const char = glob[i]!
    if (char === '*' && glob[i + 1] === '*') {
      // "**/" matches zero or more directories; a bare "**" matches anything.
      if (glob[i + 2] === '/') {
        out += '(?:.*/)?'
        i += 2
      } else {
        out += '.*'
        i += 1
      }
    } else if (char === '*') out += '[^/]*'
    else if (char === '?') out += '[^/]'
    else out += escapeRegex(char)
  }
  return out
}

export function patternToRegex(raw: string): RegExp {
  const directoryOnly = raw.endsWith('/')
  let pattern = directoryOnly ? raw.slice(0, -1) : raw
  // A slash anywhere but the end anchors the pattern to the repo root, as in .gitignore.
  const anchored = pattern.startsWith('/') || pattern.includes('/')
  if (pattern.startsWith('/')) pattern = pattern.slice(1)

  const prefix = anchored ? '^' : '^(?:.*/)?'
  // A directory pattern matches everything inside it; a plain one matches the path itself or, if
  // it names a directory, everything inside that. Unlike .gitignore, GitHub doesn't let a trailing
  // "*" reach into subdirectories: "docs/*" owns docs/a.md but not docs/build/b.md.
  const trailingStar = pattern.endsWith('*') && !pattern.endsWith('**')
  const suffix = directoryOnly ? '/.*$' : trailingStar ? '$' : '(?:/.*)?$'
  return new RegExp(prefix + globToRegex(pattern) + suffix)
}

export function parseCodeowners(text: string): Codeowners {
  const rules: Rule[] = []
  for (const line of text.split('\n')) {
    const content = line.replace(/(^|\s)#.*$/, '').trim()
    if (!content) continue
    const [pattern, ...owners] = content.split(/\s+/)
    rules.push({ pattern: patternToRegex(pattern!), owners: owners.filter((owner) => owner.startsWith('@')) })
  }
  return {
    ownersOf(path) {
      for (let i = rules.length - 1; i >= 0; i--) if (rules[i]!.pattern.test(path)) return rules[i]!.owners
      return []
    },
  }
}
