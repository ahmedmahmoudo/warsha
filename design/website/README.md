# Website brand kit

Everything the Warsha download site needs, from the v2 board icon. `public/` drops straight into
the site's web root; `brand/` holds logos and artwork for pages, the README and press.

## public/ (web root)

| File | Use |
| --- | --- |
| `favicon.svg` | Browser tab icon (all current browsers) |
| `favicon.ico` | Fallback for older browsers and tools that only look for `/favicon.ico` (16, 32, 48) |
| `favicon-16.png`, `favicon-32.png` | PNG fallbacks |
| `apple-touch-icon.png` | iOS home screen and Safari bookmarks (180, square: iOS rounds it) |
| `icon-192.png`, `icon-512.png` | Web manifest icons |
| `icon-maskable-512.png` | Android adaptive icon; the board stays inside the 80% safe zone |
| `site.webmanifest` | Name, colours and icons |
| `og-image.png` | Link previews on Slack, X, LinkedIn, iMessage (1200×630), rendered from `og-image.html` |

```html
<link rel="icon" href="/favicon.ico" sizes="32x32" />
<link rel="icon" href="/favicon.svg" type="image/svg+xml" />
<link rel="apple-touch-icon" href="/apple-touch-icon.png" />
<link rel="manifest" href="/site.webmanifest" />
<meta name="theme-color" content="#0e1420" />

<meta property="og:title" content="Warsha" />
<meta property="og:description" content="PRs, meetings, Linear tickets and notes in one place." />
<meta property="og:image" content="https://warshahq.app/og-image.png" />
<meta property="og:image:width" content="1200" />
<meta property="og:image:height" content="630" />
<meta name="twitter:card" content="summary_large_image" />
```

`og:image` must be an absolute URL: the site is https://warshahq.app (GitHub Pages, from `website/`).

## brand/

| File | Use |
| --- | --- |
| `logo-light.svg` / `-64.png` / `-128.png` | Mark + wordmark on light backgrounds |
| `logo-dark.svg` / `-64.png` / `-128.png` | Mark + wordmark on dark backgrounds |
| `wordmark-light.svg`, `wordmark-dark.svg` | "Warsha" alone |
| `logo-mark.svg`, `logo-mark-512.png` | The board icon alone, rounded tile |
| `icon-square.svg` | Full-bleed square, for places that crop or round it themselves (avatars, OAuth) |
| `macos-app-icon.svg` / `-512.png` / `-1024.png` | The Mac app icon as it looks in the Dock, for the download hero |
| `google-oauth-logo-120.png` | Google OAuth consent screen logo |

The wordmark is Inter SemiBold (SIL Open Font License) at −2% tracking, converted to outlines, so
it looks the same without the font installed. If the site sets text in Inter too, headings will match.

Colours: tile `#1d2738` → `#0e1420`, text on dark `#e4e9f1`, text on light `#1c1c1a`, muted `#9aa7bb`;
tiles `#5cc79a` (PRs), `#e8b45a` (meetings), `#8fb0f5` (tickets), `#e4e9f1` (notes).

Sources: `design/icon-v2/c-board.svg` (web/favicon) and `design/icon-v2/c-board-macos.svg` (Mac app).

The Mac app also draws the icon in code, from `c-board-macos.svg`'s numbers, so it can animate it
(Get started builds it tile by tile and draws each glyph): `macos/Sources/Warsha/BrandIcon.swift`.
When the icon changes, change that file with it.
