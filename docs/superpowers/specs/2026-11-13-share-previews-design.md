# Small link previews with covers for books and games

Status: approved (2026-11-13). Small change.

## Why

When someone pastes a book or game link into Discord (or Slack, iMessage and so on), the preview is
text only. Shane wants the cover to show, and he wants the preview **small**: "everyone hates HUGE
preview tags."

## Goals

- Book and game show pages give link previews the cover as `og:image`.
- Every page on every site asks for the small-thumbnail card (`twitter:card` = `summary`), never the
  large one.

## Non-goals

- Music (albums, songs, artists). Album covers average 771 KB and reach 110 MB, and the only stored
  variants top out at 250px, so music needs a resized-variant decision first. That's later work.
- Authors, lists, category pages, generated 1200×630 card images.

## Anti-goals

- A tiny or broken preview image. Covers under 200px on either side get no `og:image`. That covers
  the ~310 books with ~85px GIFs, and 200×200 is Facebook's minimum.
- Any page asking for a large card.

## Approaches

1. **Use the cover each page already displays, plus the summary card everywhere (chosen).** Book
   covers average 340×494 at 33 KB and game covers 814×1080 at 124 KB, so they need no processing.
2. A resized share variant per image. Only needed for large cards or for music's huge originals.
   Deferred with music.
3. Generated 1200×630 card images. Built for large previews, which Shane doesn't want.

## Design

- **Layouts (books, music, games):** `twitter:card` is always `summary`. The
  `summary_large_image` branch goes, and news posts move to the thumbnail too. Each layout renders
  `og:image:alt` when the page provides `content_for :og_image_alt`.
- **Book show (`app/views/books/books/show.html.erb`) and game show
  (`app/views/games/games/show.html.erb`):**
  - When the cover is attached and its blob metadata has width and height both ≥ 200, set
    `content_for :og_image, rails_public_blob_url(<the cover blob>)`. This is the same URL the page
    already renders, on the per-domain images host.
  - Set `og_image_alt` to the title.
  - Unknown or missing dimensions mean no image.
  - The dimension rule lives in one shared helper (builder's choice of name and place), so books
    and games can't drift.
- **Card title:** `og_title` on both pages is the title without the "| The Greatest …" suffix,
  because the card shows `og:site_name` above it. For books that's "1984 by George Orwell". For games
  it's the title plus the existing developer text, minus the suffix.
- No change to `og:description`. It keeps falling back to the page's meta description.

## Tests

- Layout/controller test: `twitter:card` is `summary` on a book, a game, a music page and a news post
  that has a share image.
- Books and games show tests:
  - A cover with sufficient dimensions gives `og:image` equal to the rendered cover URL, plus
    `og:image:alt`.
  - No cover gives no `og:image`.
  - A cover with a dimension under 200, or no metadata, gives no `og:image`.
  - `og:title` has no site suffix.
- E2E: a book page and a game page with covers expose `og:image` and `twitter:card=summary`.

## Left to the builder

The helper's name and location, and how each test attaches a cover blob with metadata.
