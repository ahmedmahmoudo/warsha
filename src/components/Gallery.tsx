import { ChevronLeft, ChevronRight, ExternalLink, ImageOff, X } from 'lucide-react'
import { Dialog } from 'radix-ui'
import { useState } from 'react'

export type GalleryImage = {
  /** What the page loads: the image itself, or the server proxy for private-repo files. */
  src: string
  /** Where the image lives on GitHub, for "open original". */
  original: string
  caption: string
}

/** Release downloads on github.com need the token, so they go through the API's proxy. */
const PROXIED = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/releases\/download\//
/** Badges and icons stay in the text; they're part of it, not screenshots. */
const INLINE_HOSTS = /(^|\.)(shields\.io|badgen\.net)$/
const MAX_INLINE_HEIGHT = 32

function fileName(url: string): string {
  try {
    return decodeURIComponent(new URL(url).pathname.split('/').at(-1) ?? '') || 'image'
  } catch {
    return 'image'
  }
}

/**
 * Takes the images out of GitHub-rendered HTML so they can be shown together in a gallery,
 * leaving a small labelled reference where each one was. A reference is a button carrying
 * `data-gallery-index`, so the caller can open that image from the text.
 */
export function extractImages(html: string): { html: string; images: GalleryImage[] } {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  const images: GalleryImage[] = []

  for (const img of doc.querySelectorAll('img')) {
    const original = img.getAttribute('data-canonical-src') ?? img.getAttribute('src')
    const src = img.getAttribute('src')
    if (!original || !src) continue
    let host = ''
    try {
      host = new URL(original).hostname
    } catch {
      continue
    }
    const height = Number(img.getAttribute('height'))
    if (INLINE_HOSTS.test(host) || (height > 0 && height <= MAX_INLINE_HEIGHT)) continue

    const name = fileName(original)
    const alt = img.getAttribute('alt')?.trim()
    const caption = alt && alt !== name && alt.toLowerCase() !== 'image' ? alt : name
    const index =
      images.push({ src: PROXIED.test(src) ? `/api/github-image?url=${encodeURIComponent(src)}` : src, original, caption }) - 1

    const ref = doc.createElement('button')
    ref.type = 'button'
    ref.className = 'gallery-ref'
    ref.dataset.galleryIndex = String(index)
    ref.textContent = `🖼 ${caption}`
    // GitHub wraps each image in a link to itself; the reference replaces both.
    const parent = img.parentElement
    const target = parent?.tagName === 'A' && parent.childElementCount === 1 && !parent.textContent?.trim() ? parent : img
    target.replaceWith(ref)
  }
  return { html: doc.body.innerHTML, images }
}

function Thumbnail({ image, onOpen }: { image: GalleryImage; onOpen: () => void }) {
  const [failed, setFailed] = useState(false)
  return (
    <figure className="flex min-w-0 flex-col gap-1">
      {failed ? (
        <a
          href={image.original}
          target="_blank"
          rel="noreferrer"
          className="flex aspect-video flex-col items-center justify-center gap-1 rounded-md border border-dashed border-border bg-muted text-xs text-muted-foreground hover:text-foreground"
        >
          <ImageOff className="size-4" />
          Open on GitHub
        </a>
      ) : (
        <button
          type="button"
          onClick={onOpen}
          className="aspect-video overflow-hidden rounded-md border border-border bg-muted transition hover:border-foreground/40"
          title={`View ${image.caption}`}
        >
          <img
            src={image.src}
            alt={image.caption}
            loading="lazy"
            onError={() => setFailed(true)}
            className="size-full object-contain"
          />
        </button>
      )}
      <figcaption className="truncate text-xs text-muted-foreground" title={image.caption}>
        {image.caption}
      </figcaption>
    </figure>
  )
}

/** Thumbnails in a fixed grid, so the images never push the rest of the page around. */
export function Gallery({ images, onOpen }: { images: GalleryImage[]; onOpen: (index: number) => void }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
      {images.map((image, index) => (
        <Thumbnail key={`${index}-${image.src}`} image={image} onOpen={() => onOpen(index)} />
      ))}
    </div>
  )
}

export function Lightbox({
  images,
  index,
  onIndexChange,
}: {
  images: GalleryImage[]
  /** null when closed. */
  index: number | null
  onIndexChange: (index: number | null) => void
}) {
  const image = index === null ? null : images[index]
  const step = (by: number) => index !== null && onIndexChange((index + by + images.length) % images.length)

  return (
    <Dialog.Root open={image != null} onOpenChange={(open) => !open && onIndexChange(null)}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/80" />
        <Dialog.Content
          className="fixed inset-0 z-50 flex flex-col items-center justify-center gap-3 p-4 outline-none sm:p-8"
          onKeyDown={(event) => {
            if (event.key === 'ArrowRight') step(1)
            if (event.key === 'ArrowLeft') step(-1)
          }}
          onClick={(event) => event.target === event.currentTarget && onIndexChange(null)}
        >
          {image && (
            <>
              <Dialog.Title className="sr-only">{image.caption}</Dialog.Title>
              <Dialog.Description className="sr-only">
                Image {index! + 1} of {images.length} from the pull request description
              </Dialog.Description>
              <img src={image.src} alt={image.caption} className="max-h-[80vh] max-w-full rounded-md bg-white object-contain" />
              <div className="flex w-full max-w-3xl items-center gap-2 text-sm text-white">
                {images.length > 1 && (
                  <button type="button" onClick={() => step(-1)} aria-label="Previous image" className="rounded-md p-1.5 hover:bg-white/15">
                    <ChevronLeft className="size-5" />
                  </button>
                )}
                <span className="min-w-0 flex-1 truncate text-center">
                  {image.caption}
                  {images.length > 1 && <span className="text-white/60"> · {index! + 1} of {images.length}</span>}
                </span>
                {images.length > 1 && (
                  <button type="button" onClick={() => step(1)} aria-label="Next image" className="rounded-md p-1.5 hover:bg-white/15">
                    <ChevronRight className="size-5" />
                  </button>
                )}
                <a
                  href={image.original}
                  target="_blank"
                  rel="noreferrer"
                  aria-label="Open original on GitHub"
                  title="Open original on GitHub"
                  className="rounded-md p-1.5 hover:bg-white/15"
                >
                  <ExternalLink className="size-4" />
                </a>
                <Dialog.Close aria-label="Close" className="rounded-md p-1.5 hover:bg-white/15">
                  <X className="size-5" />
                </Dialog.Close>
              </div>
            </>
          )}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
