# Sitemaps for books, music and games

Status: design, awaiting approval (2026-11-12)

## Why

None of the three sites has a sitemap. The legacy books app never had one either. Search engines
find our pages by following links, and the pages that matter most are reached only through deep
pagination: about 24k ranked books sit behind 243 pages of `/page/N`. A sitemap tells crawlers
directly which URLs we want them to know about, and when each one last changed.

This came up because a sitemap made scraping a publisher's new books trivial in another project.
That cuts both ways. Our pages are public anyway, so a sitemap makes them no easier to take than
they already are.

Books gains the most, because the domain cutover means Google has to re-find everything quickly.
Music and games are smaller, but they are live today and get the benefit now.

## Goals

- Every app host serves `/sitemap.xml`, a sitemap index that points to one or more child sitemap
  files for that host.
- A sitemap lists only **canonical, indexable URLs that return 200**, and for item pages only
  **ranked** items.
- It stays current without anyone running anything: a new ranked book shows up within about a day.
- The books sitemap follows the existing `Books::PublicIndexing` switch: off until cutover, then on
  with no further change.
- `robots.txt` on each host carries a `Sitemap:` line for that host.

## Non-goals

- **Changing what is indexable.** Music marks every page indexable unless told otherwise, so about
  82k unranked song pages are currently indexable. The sitemap leaves them out. Adding `noindex` to
  them is a separate decision on a live site and is out of scope.
- **Any Cloudflare change.** Already checked: each zone's cache rule for the app hosts lets the
  origin's `Cache-Control` header decide, so responses using `Cacheable` are edge-cached as they
  are. Zone details live in the private Cloudflare repo and stay there.
- Image, video or news sitemap extensions; `hreflang`; pinging search engines (Google retired its
  ping endpoint).
- Year-range ranking pages (`/the-greatest-books/since/1950`, `/the-greatest/<cat>/books/of/1984`)
  and multi-category or multi-country pages. They are combinatorial and mostly reorder pages
  already listed. Thin 1+1 filter pages below the thresholds (see below) are also left out.
- Movies.

## Anti-goals (what would make this a failure even if it works)

- **The sitemap lists a URL the page itself marks `noindex`**, or one that redirects or 404s. That
  wastes crawl budget and tells Google the sitemap is unreliable, and nothing would show it.
  The sitemap and the page must not be able to disagree.
- **A provisional book or author appears in it.** `docs/features/books-provisional-records.md`
  already requires sitemaps to read through the `catalog` scope.
- **Any `/rc/:id` URL appears in it.** Those are always `noindex`.
- **Moving `robots.txt` changes any existing rule.** A past Cloudflare rule that blocked bots
  destroyed organic traffic that never recovered. The dynamic `robots.txt` must produce the
  current rules byte for byte, plus the `Sitemap:` line.
- Sitemap requests reaching Postgres on every crawl. They must be edge-cached.

## Approaches considered

1. **Generated on request, cached at the edge (chosen).** A Rails controller builds each file from
   one query when it is requested, and `Cacheable` sends a 24-hour public `Cache-Control`. The
   database sees about one query per file per day, however often crawlers fetch it. No scheduled
   job, no stored files, nothing to sync across our app servers, and it uses the same rules as the
   pages it lists. Shane picked this.
2. **A nightly Sidekiq job writes static XML** (the `sitemap_generator` gem). This is the standard
   approach for millions of URLs, which we don't have. It needs shared storage (R2) so every app
   server serves the same files, adds a scheduled job to watch, and is always up to a day stale.
3. **Update entries when records change.** Hooks on every write, the most moving parts, for
   freshness Google does not need.

## What goes in each sitemap

Item pages list **ranked items only**, meaning items with a `RankedItem` in that type's primary
(default) ranking configuration, at their canonical non-`/rc/` URL.

| Site | Child sitemaps |
|---|---|
| Books | ranked books (`catalog` scope, so never provisional) · ranked authors (`catalog`) · ranked lists · pages · filtered ranking pages |
| Music | ranked albums · ranked songs · ranked artists · ranked lists · pages · categories |
| Games | ranked games · ranked lists · pages · categories |

- **Ranked lists**: lists that have a ranked list in the primary configuration, which is the rule
  `Books::ListsController` and `Games::ListsController` already use for `@indexable`. Music's list
  pages have no rule (every active list is indexable). The music sitemap still lists only ranked
  lists, and the music list pages are **not** changed.
- **Pages**: the fixed hub pages of each site that are **already indexable today**: the home page,
  the lists index, the news index and news posts, music's ranked albums/songs/artists index pages,
  `/rankings` on music and games, and books' `/categories`, `/countries` and ranked-authors index.
  Books' `/rankings` currently renders `noindex`. *My call:* leave it out rather than change its
  indexing. The builder confirms each page renders `index` on its host before listing it (the
  consistency test enforces this anyway).
- **Filtered ranking pages (genres, subjects, locations, countries)**: decided with Shane. Books
  already indexes any ranking page with at most one category and at most one country
  (`Books::FilterPath.indexable?`); two or more of either is `noindex` and disallowed in
  `robots.txt`. The sitemap lists a subset of the 1+1 pages, chosen by how many ranked books the
  page shows, so that thin pages are left out:
  - single category (`/the-greatest/:category_id/books`, any `category_type`) with **≥ 10** ranked
    books: about 1,760 in dev;
  - single country (`/the-greatest-books/written-by/:country_id/authors`) with **≥ 10**: about 72;
  - category + country (`/the-greatest/:category_id/books/written-by/:country_id/authors`) with
    **≥ 25**: about 1,700. The bar is higher because these overlap heavily with their parent pages.
  - **No year or date-range pages** (`/of/`, `/since/`, `/to/`, `/from/…/to/`) and no
    collection-prefixed variants. Decade pages are a possible follow-up.

  Music category pages (`/categories/:id`, `/albums/categories/:id`) and games `/categories/:id`
  are listed when they show **≥ 10** ranked items. The thresholds are constants in one place, to be
  tuned once Search Console shows how these pages do. Pages below a threshold keep their current
  indexing; they are only left out of the sitemap. Counts come from the dev database on 2026-11-12
  (21,260 ranked books in the primary configuration). The count must use the same relation the
  page renders (`Books::RankedBooksQuery` with that category/country), or an equivalent grouped
  query the builder shows agrees with it.

Sizes, from the dev database (a restore of production): music has about 5k ranked songs,
3.9k ranked albums and 3.6k ranked artists; games about 1.5k ranked games; books about 24k ranked
books in the primary configuration. Every type fits in one 50,000-URL file today, but chunking is
built in from the start (below), so growth needs no change.

## Design

### Routes and files

- `GET /sitemap.xml` returns a sitemap index (`<sitemapindex>`) for the current host.
- `GET /sitemaps/:type-:page.xml` (for example `/sitemaps/songs-1.xml`) returns one `<urlset>` of at
  most 50,000 URLs and at most 50 MB uncompressed.
- The index lists only the types valid for the host, and for each type as many pages as its count
  needs (`ceil(count / 50_000)`, at least 1).
- An unknown type, a type from another site, or a page past the end returns 404.
- Paging is keyset or ordered-by-id offset, at the builder's discretion. Order must be stable (by
  id) so a URL doesn't move between files from one day to the next.
- Responses are `application/xml`, built with plain `xml.builder` or string building. No new gem is
  needed.

The controller and any per-site query objects are created with Rails generators, per
`AGENTS.md`. Whether this is one host-aware controller plus a per-site registry of "sitemap
sources", or one controller per domain namespace, is left to the builder. The existing
`DomainLayout`/`CurrentDomain` concerns show how other host-aware controllers are structured.

### The sitemap is a subset of what's indexable

The rule is one-directional: **every URL in a sitemap must render `index` on its page**. The
reverse doesn't hold. Music and games pages that set no `@indexable` (song, album, artist and game
pages, music lists, music and games categories) stay indexable whether ranked or not, and the
sitemap lists only the ranked ones. No music or games controller changes its indexing in this work.

*Revised during planning:* an earlier draft also moved each page's rule into a predicate shared
with the sitemap. That does not fit the code. Controllers judge "ranked" against whichever ranking
configuration the URL selects (including `/rc/` alternates), and views lean on `@indexable` beyond
the robots tag. The sitemap only ever uses the primary configuration. So controllers are left
alone, and the **consistency test** (see Testing) is the guard: it requests every URL every sitemap
lists and asserts the page renders `index`.

### `lastmod`

Each `<url>` carries `<lastmod>` from the record's `updated_at`. Google uses `lastmod` only if it
proves accurate, so **the builder must first check whether ranking recalculations or other bulk
jobs touch `updated_at` on every item**. If they do, every record looks changed every week and the
dates become noise. In that case, use a better-behaved column if one exists, otherwise omit
`lastmod` for that type. (Checked during planning: recalculation upserts `ranked_items` only, so
item `updated_at` is honest.) The child files in the index carry their source's max `lastmod`,
which is exact while each source fits in one file, as all do today.
`priority` and `changefreq` are omitted, because Google ignores them.

### Hosts and canonical URLs

URLs are absolute and built from `Api::Host.base_url(domain)`, the first host in
`config.domains`, which is the same source the routes constrain on. `request.host` is never used
to build a URL (`CurrentDomain` says so explicitly). *Revised during planning:* an earlier draft
said `request.base_url`. Books pre-cutover runs on `new.thegreatestbooks.org`; at cutover the
apex moves to the new app and the same code serves it.

### Books gate

While `Books::PublicIndexing.enabled?` is false, `/sitemap.xml` and every books child sitemap
return 404, and books' `robots.txt` carries no `Sitemap:` line. Flipping the switch at cutover
turns it all on.

### `robots.txt`

`public/robots.txt` is a single static file served on every host, so it can't name a per-host
sitemap. It becomes a Rails route (`GET /robots.txt`) that renders the existing rules unchanged
and appends `Sitemap: <request.base_url>/sitemap.xml` when that host's sitemap is enabled. The
static file is deleted. A test pins the rule body to the current file's content so a later edit
cannot silently drop a `Disallow`. The response is cached with `Cacheable` like the sitemap.

### Caching

Sitemap, index and robots actions use `cache_for_show_page` (24h public, session skipped so
Cloudflare doesn't bypass on `Set-Cookie`). No Cloudflare change is needed. After deploy, check
for `cf-cache-status: HIT` on a second fetch of `/sitemap.xml` and one child file on music and
games.

### Performance

Each child file is one query selecting only the columns the URL and `lastmod` need (`slug` or
`id`, `updated_at`), joined to `ranked_items` for the primary configuration. No model
instantiation per row (`pluck` or equivalent) and no N+1 queries. A 50k-row file should build in
well under a second.

## Testing

- Integration tests per host: `/sitemap.xml` lists the right child files; each child file returns
  valid XML containing a ranked fixture and **not** an unranked, provisional or `/rc/` one;
  another site's type 404s; a page past the end 404s; books sitemap 404s with the gate off and
  works with it on (stub `Books::PublicIndexing.enabled?`, never the env var).
- **Consistency test:** for each listed type, every URL in the fixture-built sitemap, when
  requested, renders `meta[name=robots]` with `index`. This is the guard against the main
  anti-goal.
- `robots.txt` test: the body equals the current rules, plus the `Sitemap:` line per host, minus it
  for books while gated.
- Cache headers asserted (`public`, max-age, no `Set-Cookie`).
- A small Playwright check per domain fetches `/sitemap.xml` and one child file and asserts a 200
  with XML. *My call:* this is not a user-facing page, but `AGENTS.md` asks for E2E on new public
  surfaces, and it's cheap.

## Rollout

- Music and games: after deploy, submit `/sitemap.xml` in Google Search Console (and Bing Webmaster
  Tools if used) for each site. This is a manual step for Shane.
- Books: add a line to `docs/launch-todo.md`: after `BOOKS_PUBLIC_INDEXING` is on, check
  `/sitemap.xml` returns 200 and submit it in Search Console.
- Afterwards, the Search Console "Sitemaps" report shows submitted vs indexed. A large gap is
  worth reading but is not a bug in this work.

## Docs

- New `docs/features/sitemaps.md`: what is listed, the shared indexability rule, the books gate,
  and how to add a page type.
- `docs/features/books-provisional-records.md`: replace "none exist yet" in the Sitemaps row with a
  pointer to the new doc.

## Left to the builder

Controller structure, how paging is implemented, and the exact shape of the shared indexability
scopes/predicates, all within the rules above.
