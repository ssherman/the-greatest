# Sitemaps

Every app host serves `/sitemap.xml`, a sitemap index for that host, and its child files at
`/sitemaps/<source>-<page>.xml` (for example `/sitemaps/album_lists-1.xml`). `/robots.txt` names
the index with a `Sitemap:` line. The files are built on request and cached at the edge, so there
is no scheduled job and nothing to regenerate. Design: `docs/superpowers/specs/2026-11-12-sitemaps-design.md`.

## What each site lists

The rule is one-directional: every URL in a sitemap renders `index` on its own page, but not every
indexable page is in the sitemap. Item pages are listed only when the item is **ranked**: it has a
`RankedItem` with a non-null `rank` in the primary (`default_primary`) ranking configuration of its
type. Unranked items keep whatever indexing their page already has; they are only left out of the
sitemap. URLs are the canonical ones, never `/rc/:id`.

| Site | Source keys |
|---|---|
| Books | `pages`, `news`, `books`, `authors`, `lists`, `filters` |
| Music | `pages`, `news`, `albums`, `songs`, `artists`, `album_lists`, `song_lists`, `categories`, `album_categories` |
| Games | `pages`, `news`, `games`, `lists`, `categories` |

- **pages**: fixed hub pages that are already indexable (`Sitemaps::Registry::STATIC_PATHS`).
  Books' `/rankings` is left out because it renders `noindex`.
- **news**: the `/news` hub followed by the published news posts for that site. A site with no
  published post has no `news` file and no `/news` entry, because `/news` renders `noindex` then.
- **Items**: books and authors read through the `catalog` scope, so a provisional record is never
  listed (`docs/features/books-provisional-records.md`).
- **Lists**: `active` lists with a `ranked_lists` row in the primary configuration. Music lists
  follow the same rule even though their pages index every active list.
- **Categories** (music and games) and books **filters**: listed only when the page shows enough
  ranked items, so thin pages stay out. `Sitemaps::Thresholds.filter_single` (10) covers music
  categories, music album categories, games categories, and books single-category and
  single-country pages. `filter_pair` (25) covers books category plus country pages, which overlap
  heavily with their parents. Books counts come from `Books::RankedBooksQuery`, the query the page
  itself renders from. Categories must be `active` (not soft-deleted).
- Never listed: year and date-range pages, collection-prefixed pages, pages with more than one
  category or country, `/video-games` (a duplicate of the games home page), and anything under
  `/rc/`.

Each file holds at most 50,000 URLs (`Sitemaps::Registry::PAGE_SIZE`). A source past that size
spans several files, and every source is ordered by id so a URL stays in the same file from day to
day. Items, lists and news posts carry `<lastmod>` from `updated_at`; ranking recalculation only
touches `ranked_items`, so those dates are honest. Static, category and filter pages carry none.
The index gives each child file its source's latest `updated_at`.

## The books gate

While `Books::PublicIndexing.enabled?` (`BOOKS_PUBLIC_INDEXING=true`) is false, books has no
sources: `/sitemap.xml` and every child file return 404, and books' `robots.txt` has no `Sitemap:`
line. Turning the switch on at cutover turns all of it on; nothing else changes. Music and games
are not affected by the switch.

## Caching and the edge

`SitemapsController` and `RobotsController` use `Cacheable#cache_for_show_page`: public, 24-hour
`Cache-Control`, and no session cookie (a `Set-Cookie` header would make the edge skip the cache).
No edge rule change was needed, because the cache rule for the app hosts honours the origin's
`Cache-Control`. The database sees roughly once per file per day at each edge location, however often crawlers fetch.

`robots.txt` is a Rails route on every host (movies included), rendered from
`app/views/robots/show.text.erb`. Its rules are pinned byte for byte by
`test/fixtures/files/robots_rules.txt`; the only addition is the `Sitemap:` line.

## The guard: the consistency test

`test/integration/sitemap_consistency_test.rb` requests `/sitemap.xml` on each host, every child
file, and every URL listed, and requires each page to return 200 and render
`meta[name=robots]` starting with `index`. It also fails if any source lists nothing, so a source
cannot pass by being empty. When it fails, the source is wrong (a bad path or rule), not the test.

The fixtures deliberately leave the books primaries, music albums and artists unranked, and hold
no active ranked books or games list and no games news post; other tests pin those gaps. The
consistency test creates those rows in its own setup, and stubs both thresholds to 1 so fixture
categories qualify.

## Adding a source

1. Write a class in `app/lib/sitemaps/` with the source interface: `key` (unique per site,
   `/\A[a-z_]+\z/`), `count`, `entries(offset:, limit:)` returning `Sitemaps::Entry` values in a
   stable order, and `lastmod` (a time or nil). The generic `RankedItems`, `RankedLists` and
   `RankedCategories` cover most cases.
2. Register it for its site in `Sitemaps::Registry`.
3. Add its key to `EXPECTED_KEYS` in the consistency test and make sure the test has data that
   puts at least one URL in it, from fixtures or the test's setup.

## Search Console

Submitting `/sitemap.xml` in Google Search Console is manual, once per site. Music and games are
submitted after deploy; books after the switch is on (`docs/launch-todo.md`, section 7). Search
engines are not pinged (Google retired its ping endpoint).
