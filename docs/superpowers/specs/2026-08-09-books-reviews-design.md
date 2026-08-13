# Books Reviews — Design

**Date:** 2026-08-09
**Branch:** `worktree-books-reviews`
**Status:** Approved, ready for planning

Port the reviews feature from the legacy TheGreatestBooks app (`/home/shane/dev/the-greatest-books/admin`)
to the new app: migrate the data, display ratings and text reviews on the book page, add the write
flow, and replace the legacy `/reviews` page with a genuinely useful personal ratings library.

## Goals

- Migrate all 128,969 legacy reviews with ids, users and books preserved.
- Show an aggregate rating (average, count, per-star histogram) on the book page — legacy stores
  ratings for 53,630 books and displays none of it.
- List text reviews on the book page, and only text reviews.
- Let signed-in users rate and review a book, and edit or delete their own.
- Replace `/reviews` with `/my/reviews`: a filterable, sortable, paginated ratings library.
- Give the admin a way to find and delete a bad review.

## Non-goals

- **Recommendations.** Review ratings feed the legacy recommendations feature. That feature is not
  ported and is not part of this work. The schema simply keeps ratings queryable in SQL for when it is.
- **Goodreads importer.** Many legacy reviews arrived through it. It is not implemented in the new
  app and is out of scope here.
- **Music, movies and games reviews.** The model is polymorphic so those are cheap later, but only
  `Books::Book` is wired up now.
- **Ratings on the ranked grid / list pages.** Deliberately excluded: rendering a rating per card
  across collection views is an N+1 shape, and nothing asks for it yet.
- **Bare-URL autolinking.** Legacy runs `Rinku.auto_link` over review bodies. Not carried over —
  one more gem for a cosmetic touch. Existing `<a>` tags (119 rows) survive the sanitizer allowlist.
- **Review search / OpenSearch indexing.** Filtering on `/my/reviews` is Postgres-only.

## What the legacy app does today

| | |
|---|---|
| Table | `reviews` — `user_id`, `book_id`, `title`, `body`, `rating`, timestamps. No unique constraint. |
| Book page | Lazy Turbo Frame tab "Reviews (N)" → `/books/:book_id/reviews`, text reviews only, sorted by rating desc, unpaginated. |
| `/reviews` | Sign-in required. "Books you have reviewed" — every review you ever wrote, with cover images, sorted by rating desc. No pagination, no filters, no search. The heaviest user has 2,331 rows on that one page. |
| Write flow | "Review" button on a book → `POST find_by_book` → Turbo Stream renders a Bootstrap modal with a star-rating form. |
| Policy | `index/create/edit/update/destroy` all require only a signed-in user; `Scope` resolves to `where(user:)`. |

### Legacy data shape (measured 2026-08-09)

| Metric | Value |
|---|---|
| Total reviews | 128,969 |
| `body IS NULL` | 107,523 |
| `body = ''` (empty string) | 5,177 |
| Genuine text reviews (after sanitizing) | **16,267** |
| Rows with a title | 404 |
| Distinct raters | 1,399 (364 wrote text) |
| Distinct books rated | 53,630 (11,663 with text) |
| Rating distribution | 1:2,458 · 2:9,593 · 3:32,627 · 4:49,087 · 5:35,204 · null:0 |
| Orphaned `user_id` / `book_id` | 0 / 0 |
| Duplicate `(user_id, book_id)` pairs | 123 (max 2 rows each) |
| Longest body | 462,047 chars (review 101561); next longest 20,030 |
| Date range | 2022-12-10 → 2026-07-03 |

All 1,399 raters and all 53,630 books already exist in the new database with their legacy ids
preserved, verified against the new DB. The migration needs no id remapping and has no orphans.

### Two legacy defects this port fixes

**1. Blank reviews render as empty blocks.** Legacy's scope is
`scope :with_body, -> { where.not(body: nil) }`, but 5,177 rows hold an empty *string* rather than
`NULL`. They pass the scope and render as empty review cards. Legacy's `with_body` returns 21,446
rows, of which **5,177 are blank** — nearly a quarter of every review shown on a book page.

Two further rows (27794, 121405) contain only an `<img>` tag and no text. They are not blank on
input but are blank *after* sanitizing, since `img` is not in the allowlist. **The rule this port
applies is therefore rendered text, not the markup string: a body normalizes to `NULL` whenever the
sanitized fragment has no visible text, not merely when the markup string itself is empty** —
`<br>`, `<p></p>`, an empty `<a href>`, and an `&nbsp;`-only body all sanitize to non-empty markup
that renders as nothing, and all must be caught the same way as the `<img>`-only case. Measured
against the legacy data: of the 16,269 bodies that are non-blank on input, exactly 2 have no
visible text, and both are the `<img>`-only rows above — there are zero `<br>`-only rows. The
"16,267 genuine text reviews" figure above is therefore confirmed correct, and increment 2's import
is unaffected. Total importing as `NULL` body: **5,179**.

Thirteen rows are near-blank once markup is stripped — `"I"`, `"/"`, `"no"`, `"M"`, `"Eh"`, `"?"`.
These are kept. They are terse but genuine; any heuristic that strips them is guessing at intent.

**2. One XSS fuzz payload sits in the data.** Review **101561** (user 66778, 462,047 chars) is a
paste of a public XSS polyglot cheat sheet — `"-prompt(8)-"`, `<image/src/onerror=prompt(8)>`,
`<svg/onload=…>`. It is a single row from a single user and accounts for essentially every alarming
tag in the table.

Per-row tag counts, with that row excluded: `<script>` **0**, `<style>` **0**, `<input>` **0**,
`<svg>` **0**, `<iframe>` 1, `<img>` 19. Everything else is benign pasted formatting — `<br>` 7,769,
`<i>` 857, `<a>` 119, `<spoiler>` 118, `<strong>` 99, `<blockquote>` 82, `<p>` 81.

**The legacy site is not vulnerable.** Both render paths sanitize: `format_review_content` runs
Rails `sanitize` with an allowlist (and autolinks *before* sanitizing, which is the correct order),
and `ReviewDetailsComponent` uses `simple_format`, which sanitizes by default. There is no `raw` or
`html_safe` anywhere near reviews. The payload is inert text and renders as inert text. This port
still sanitizes on write as well as on render, so the payload is not carried across verbatim.

## Architecture

### Data model

Both models are global (root namespace), matching `List`, `Description`, `ExternalLink` and
`UserListItem`. `Review` is polymorphic on `reviewable`, so music and games are a new
`has_many … as: :reviewable` rather than a new table.

```
reviews
  id                 bigint  PK          # legacy ids preserved
  user_id            bigint  not null    FK -> users
  reviewable_type    varchar not null
  reviewable_id      bigint  not null
  title              varchar
  body               text
  rating             integer not null    # 1..5
  created_at / updated_at

  unique [user_id, reviewable_type, reviewable_id]
  index  [reviewable_type, reviewable_id] WHERE body IS NOT NULL   # book page lists text only
  index  [user_id, created_at]                                     # /my/reviews default sort
  check  body IS NULL OR btrim(body) <> ''                         # blank can only be NULL

review_summaries
  id                  bigint  PK
  reviewable_type     varchar not null
  reviewable_id       bigint  not null
  ratings_count       integer not null default 0
  ratings_sum         integer not null default 0
  text_reviews_count  integer not null default 0
  rating_1_count      integer not null default 0
  rating_2_count      integer not null default 0
  rating_3_count      integer not null default 0
  rating_4_count      integer not null default 0
  rating_5_count      integer not null default 0
  created_at / updated_at

  unique [reviewable_type, reviewable_id]
```

`Books::Book has_many :reviews, as: :reviewable` and `has_one :review_summary, as: :reviewable`.

The average is **not stored** — it is `ratings_sum.to_f / ratings_count`, so it can never drift from
the counts it summarizes. Both are available in SQL for the future recommendations work.

`Review` validations: `rating` present and in `1..5`; `body` at most 25,000 characters; uniqueness of
`user_id` scoped to `reviewable`. Scopes: `with_body` (`where.not(body: nil)`, now honest),
`by_rating`, `recent`.

### Body handling

`Services::Reviews::BodySanitizer` is the single implementation, called from `Review`'s
`before_validation` **and** directly by the migrator, which bulk-inserts and so bypasses callbacks.

> **Revised 2026-08-11, after increment 4 shipped.** The original design converted markup on
> **write** — `<spoiler>` became `<span class="review-spoiler">`, and blank lines became `<p>`.
> Both conversions produced markup that `call`'s own allowlist rejects, so `call` was **not
> idempotent**, and every edit path had to un-convert first. That produced **three separate
> production-class bugs** in one increment: editing a review destroyed its spoiler and published it
> in the clear; a `PATCH` omitting the body did the same; and paragraph conversion stopped working
> after the first edit. Each fix defended the round trip rather than removing it.
>
> **The rule now: `call` sanitizes and never transforms. All markup generation happens at render.**
> Storing exactly what the author typed makes `call` idempotent, and an idempotent write path makes
> the entire class of round-trip bug unrepresentable rather than defended against.

**Write — `call`:** `Rails::HTML5::SafeListSanitizer`, allowlist `p br a i b em strong blockquote`,
attributes `href title`. Then `.presence` on rendered text, so a body that sanitizes down to nothing
becomes `NULL` (the `<img>`-only case). **No conversions.** `call(call(x)) == call(x)` is the
property the tests pin, and it is what retires `for_editing` entirely.

**Read — `render`:** parse the sanitized fragment once, then

1. if the body contains no block-level element, wrap its loose text into paragraphs (blank lines
   separate paragraphs, single newlines become `<br>`). Migrated bodies already carry `<p>`/`<br>`
   from the legacy import, so the guard skips them and ~16,000 reviews render exactly as before
2. walk **text nodes only**, replacing `||spoiler||` with `<span class="review-spoiler">`
3. harden every `<a>` with `rel="nofollow ugc noopener"` and `target="_blank"`

**Text nodes only is the safety property.** An attribute value is not a text node, so
`<a href="||evil||">` can never receive a spliced span — the same failure the original
string-substitution attempt produced, avoided the same way.

Spoiler syntax is `||…||`. Measured against the corpus: **0 bodies contain `||`, 7 contain `>!`**,
so the Discord delimiter is collision-free here and the Reddit one is not. A reader who types `||`
twice in prose gets a spoiler, exactly as Discord behaves; there is no escape hatch until one is
needed. `<spoiler>` as *input* stops working — it is no longer in the allowlist — and the dialog's
hint teaches `||` instead.

Because `span` and `class` leave the render allowlist with this change, `scrub_classes` is deleted
too: no stored body legitimately contains a `span` any more, so the blanket-`class` hole that pass
existed to narrow closes by construction.

**Two data paths this revision must not miss:**

- **119 stored rows carry `<span class="review-spoiler">`** and convert to `||…||` via a Rails
  migration that runs automatically before the app boots — `bin/docker-entrypoint` calls `db:prepare`
  first, so there is no separate rake task to remember after deploy, a deliberate departure from
  increments 2 and 3. Not optional — the moment `span` leaves the render allowlist, any row still
  holding one prints its spoiler in the clear.
- **`ReviewMigrator` calls `call`**, so at the eventual legacy cutover, when everything re-imports
  from scratch, legacy `<spoiler>` tags would be stripped to bare text. The migrator gains an
  explicit parser-based pre-pass converting them to `||`, since `call` no longer knows the tag.

Bodies over **25,000 characters** after sanitizing import as rating-only, with the body dropped and
the id logged. The cap clears the longest legitimate legacy review (20,030) and catches only review
101561.

### Aggregates

`Services::Reviews::SummaryRecalculator` owns both paths and is the only writer of
`review_summaries`:

- `.recalculate(reviewable)` — a single-row `INSERT … ON CONFLICT DO UPDATE` computed from a grouped
  subquery, fired from `Review`'s `after_commit` on create, update and destroy.
- `.backfill_all!` — one set-based SQL statement rebuilding every row, used after the migration and
  exposed as a rake task so the truth can always be re-derived.

Because both paths derive from the same query, an incremental update and a full rebuild are
required to agree; a test asserts they do.

### Migration

`Services::BooksMigration::ReviewMigrator < InsertOnlyMigrator`, plus a `LegacyBooks::Review`
read-only model and a `data_migration:reviews` rake task that runs the migrator then
`SummaryRecalculator.backfill_all!`.

`insert_all` with `ON CONFLICT DO NOTHING`, ids preserved, sequence reset in `finalize`.

> **Landmine — `unique_by` must be `nil` here.** `InsertOnlyMigrator` passes `unique_by` straight to
> `insert_all` as the `ON CONFLICT` arbiter. This table has *two* unique constraints a re-run
> collides with: the preserved-id primary key and the natural key
> `[user_id, reviewable_type, reviewable_id]`. An arbiter naming only the natural key does **not**
> suppress the primary-key violation — Postgres raises and aborts the batch, which is the same class
> of failure documented in `InsertOnlyMigrator`'s own comment. Returning `nil` produces an
> untargeted `ON CONFLICT DO NOTHING` that absorbs conflicts on *any* constraint, which is what
> idempotency requires here.

Transforms:

- `reviewable_type` = `"Books::Book"`, `reviewable_id` = legacy `book_id`
- body sanitized, then blank → `NULL` (5,179 rows); over-cap → `NULL` (1 row)
- blank titles → `NULL`
- duplicates pre-filtered with `DISTINCT ON (user_id, book_id) … ORDER BY user_id, book_id, id DESC`,
  keeping the newer row. Safe because no duplicate pair has body text on either side and 82 of the
  123 share a rating.

Idempotent and re-runnable, consistent with every other migrator in `app/lib/services/books_migration/`.

## Surfaces

### Book page — `/book/:slug`

Two additions to `Books::BooksController#show`, which preloads `review_summary`:

- **Summary line** under the rank: `★★★★☆ 4.0 · 450 ratings · 37 reviews`, anchoring to the reviews card.
- **`Ratings & Reviews` card** at the bottom of the right column, after *Appears on N lists*:
  the histogram, then the text-review list. Only `body IS NOT NULL` rows are listed; the remaining
  ratings feed the numbers only, as legacy did.

Decisions settled when increment 3 was planned, measured against the migrated data:

> **No pagination.** The most-reviewed book in the corpus — *The Great Gatsby*, book 38 — has **37**
> written reviews. Twelve books exceed 20; **none** exceeds 50. Legacy accumulated 16,267 text
> reviews over 3.5 years across 11,663 books, so the list grows by roughly one review per book per
> decade. Every written review renders; a paged route would be machinery for a case that does not
> exist, and would mint crawler-facing URLs that today would never have a page 2.

> **Newest first**, not legacy's rating-desc. Rating-desc puts the most flattering reviews at the
> top of every book and buries a new critical one; it also means a review written through
> increment 4's flow lands out of sight instead of where its author expects it.

> **No attribution**, matching what the legacy book page renders today: stars, relative time,
> optional title, body — no author. Only 56 of the 364 people who have written a review ever set a
> display name, so a name line would read "A reader" on 85% of rows. It would also newly publish
> those 56 real names against 141,869 already-migrated rows whose authors never agreed to it, and it
> keeps the row free of any association, so no per-row user load exists to become an N+1.

Three states, by measured population:

| Book has | Books | Renders |
|---|---|---|
| no ratings | 72,659 | nothing — page identical to today |
| ratings, no text | 41,967 | summary line, histogram, "No written reviews yet." |
| text reviews | 11,663 | full card |

**Stars are drawn by clipping, not by rounding.** `Reviews::StarsComponent` lays a filled five-star
row over an outline five-star row and clips the fill to `rating / 5 × 100%`. An average of 3.96
clips at 79.2% — proportional rather than rounded to 4 — and an integer rating of 4 clips at exactly
80%, landing on a star boundary, so one component serves both the average and the per-review stars.
Fill is a single colour; the histogram bars likewise. No hue scale carries meaning anywhere on this
surface.

**Rendering a body must not re-run `BodySanitizer.call`.** Stored bodies carried
`<span class="review-spoiler">` wrappers (118 rows), and `span` is deliberately absent from the
write-time allowlist — so a second `.call` stripped every wrapper and printed those spoilers in the
clear. Render-time sanitizing is therefore a separate `BodySanitizer.render`, kept in the same file
as `call` so the two allowlists cannot drift, and pinned by a test asserting the failure mode.

> **Superseded 2026-08-11 by the `Body handling` revision above, which removes the root cause.**
> `call` no longer generates a `span` at all — spoilers are stored as `||…||` and converted at
> render — so the two allowlists are once again the same set, `span` and `class` leave the render
> list, and `scrub_classes` is deleted. The separation of `call` and `render` remains; what goes
> away is the asymmetry that made re-running `call` destructive. The test asserting that failure
> mode is replaced by a stronger one: **`call` is idempotent.**

The spoiler reveal mounts **on the card, not on the spans**: the sanitizer strips `data-action`, so a
span can never carry its own. The Stimulus controller delegates clicks through
`closest(".review-spoiler")` and, on connect, gives each span `tabindex="0"` and `role="button"` so
it is reachable by keyboard.

### Write flow

The book page is edge-cached via `Cacheable#cache_for_show_page`, so **nothing user-specific can be
server-rendered into it.** `Reviews::WidgetComponent` emits identical HTML for every visitor and
hydrates client-side from a `ReviewStateController`, the same pattern
`UserLists::CardWidgetComponent` and `UserListStateController` already use. It sits beside
*Add to list* in the same row, so the codebase has one hydration story rather than two. Signed out,
it opens the existing auth modal.

`GET /review_state?reviewable_type=Books::Book&reviewable_id=:id` — `prevent_caching`,
`require_signed_in!` — returns the signed-in user's own review of that item (`review_id`, `rating`,
`title`, `body`) or null.

> **It must also return a fresh `csrf_token`,** exactly as `UserListStateController` does. The
> cached page's `<meta name="csrf-token">` belongs to whoever populated the cache, or to nobody, so
> a write posted from a cached page fails authenticity verification unless the client sends a token
> obtained from this uncached endpoint via `X-CSRF-Token`. This is not optional and is easy to miss
> until the first save silently 422s in production.

Unlike `user_list_state`, which returns every membership the user has, this endpoint takes the
polymorphic pair and returns one record. The heaviest user has 2,331 ratings, and shipping all of
them to render a single book page would be pure waste.

Clicking the widget opens a DaisyUI modal: five star buttons, optional title, optional body. Save
posts to `ReviewsController#create` / `#update`, which respond with a Turbo Stream swapping the
widget and the summary line. **A rating with no text is valid** — that is 87% of all rows.
**Removing a review lives inside that modal**, shown only when one already exists, rather than as a
separate affordance on the page.

The modal holds everything — stars, title and body together — rather than saving a rating on a
single star click. One place where writing happens is simpler to build and to test, and the extra
clicks for a bare rating were judged an acceptable trade.

`ReviewPolicy` mirrors the legacy one: any signed-in user may create; `edit`/`update`/`destroy`
require ownership; `Scope` resolves to `where(user:)`.

#### Keeping the cached page honest

Increment 3's summary line and reviews card are **server-rendered into a page Cloudflare holds for
24 hours**, so a newly written review would otherwise be invisible — to everyone, including its own
author on reload — until that copy expired. Two shapes were weighed:

A **lazy, never-cached Turbo Frame** holding the whole reviews card would be self-correcting, and
would delete the state endpoint, the client-side hydration and the CSRF-token problem outright,
because uncached HTML can be server-rendered with the viewer's own rating already in it. It was
**rejected on traffic**: the book page is the site's highest-volume page type across ~156k indexed
URLs and is crawler-heavy, and a frame that is never cached puts an origin request on every single
view. It would also drop review text out of the indexed HTML.

The decision is therefore to **purge the single book page on write**:

- `Cloudflare::PurgeService` gains `purge_urls(domain, urls)`. Purge-by-URL is available on the
  **Pro** plan — Cloudflare moved every purge method to every plan — with limits (5 requests/second,
  1,500 URLs/second) orders of magnitude above this feature's ~13 writes/day.
- A Sidekiq job resolves a reviewable to its canonical URL and purges just that one.

**Only the canonical `/book/:slug` is purged.** Book pages are also reachable at
`/rc/:ranking_configuration_id/book/:slug`; those copies stay stale until they expire. They are a
minority of traffic and carry no crawler weight, and purging them would mean either enumerating
every ranking configuration or relying on purge-by-prefix.

> **The purge is invoked explicitly from each write path — never from a model callback.** An
> `after_commit` that makes an external HTTP call is a side effect invisible to its callers, and it
> would fire on paths that have no business purging: a rake task, a future importer, a bulk
> backfill, or any test that happens to create a review. `ReviewsController`'s create, update and
> destroy each enqueue the job themselves, through one small service so the rule lives in a single
> place. The cost of being explicit is that a new write path must remember to call it — increment
> 5's admin destroy is the next one that will need to — which is the right trade against a hidden
> callback firing on every write in the system.

> **Landmine — `Cloudflare::Configuration#initialize` raises when `CLOUDFLARE_CACHE_PURGE_TOKEN` is
> blank**, which is every development machine and CI. Unguarded, this turns *every* review write in
> development into an exception. The job must check for configuration and no-op quietly without it.

**Saving shows a toast**: the review is saved and will appear on the page shortly, emitted through
the `toast:show` event `Toast::RegionComponent` already listens for. That sentence is what makes an
asynchronous purge safe — a slow or failed purge then reads as the behaviour the user was promised
rather than as a bug, and the worst case degrades to the old 24-hour wait rather than to data
appearing lost.

### `/my/reviews`

`MyReviewsController`, following `MyListsController`: `require_signed_in!`, `prevent_caching`,
`PathBasedPagination` for `/my/reviews/page/N`.

A **profile strip** on top — your average, your rating spread as a histogram, and counts of rated vs
written (including "N rated without a review", the number that pulls a user back into writing). The
histogram bars are the rating filter, so the strip earns its space rather than decorating.

Below it, dense rows: cover thumbnail, title and author, your stars, when you rated it, and a
two-line snippet for written reviews. Rating-only entries collapse to a single line with a
"Write a review" affordance.

`Reviews::MyReviewsQuery` owns filtering and sorting:

- **filters** — rating 1–5 (from the histogram), `written` / `rating-only`, title/author text search
- **sorts** — recently rated (default), my rating high, my rating low, book's site rank, title A–Z

Filter and sort state lives in query params; results render inside a Turbo Frame carrying
**`target: "_top"`**, because book titles inside link off-page and would otherwise render
"Content missing" (the trap documented in CLAUDE.md and guarded by `assert_no_frame_trapped_links`).

Preloading is explicit — `includes(reviewable: [:primary_image, {book_authors: :author}])` — and
pinned by `assert_queries_count`, since a 25-row page rendering a cover and author per row is exactly
the N+1 shape that bites here.

`/reviews` and `/reviews/account_required` 301 to `/my/reviews`.

### Admin

`Admin::Books::ReviewsController` — `index` and `destroy` only, in the shared admin shell with a
`DomainNav` entry. Filter to text reviews, search by user or book, sort by recent. No approval queue;
nothing gates publishing.

## Testing

- **Models** — validations, uniqueness, the blank/sanitize normalization including the `<img>`-only
  case, and the check constraint.
- **`BodySanitizer`** — script/iframe/style stripping, spoiler round-trip, the class-injection
  attempt, the 25,000-char cap.
- **`SummaryRecalculator`** — incremental `after_commit` and full backfill produce identical rows.
- **`ReviewMigrator`** — `legacy_each` stubbed so no legacy database is required; covers dedup,
  blank normalization, over-cap bodies, and idempotency.
- **Controllers** — behavior only: status codes, ownership 403s, redirect targets. No HTML or copy.
  Includes a test that `ReviewStateController` returns a usable `csrf_token` and never caches.
- **N+1** — `assert_queries_count` pinning the `/my/reviews` preloads.
- **E2E (Playwright)** — rate a book, write a review, edit it, delete it, and the `/my/reviews`
  filter/sort round-trip.

## Increments

Each is independently shippable.

1. **Schema and core** — `Review`, `ReviewSummary`, `BodySanitizer`, `SummaryRecalculator`. Models
   and services only, no UI.
2. **Migration** — `LegacyBooks::Review`, `ReviewMigrator`, `data_migration:reviews`, backfill. Data
   lands but is still invisible.
3. **Book page read surface** — summary line, histogram, full (unpaginated) text-review list,
   `BodySanitizer.render`, spoiler CSS and reveal controller.
4. **Write flow** — cacheable widget, `ReviewStateController`, modal, `ReviewsController`,
   `ReviewPolicy`, single-URL cache purge on write, and the "appears shortly" toast.
5. **`/my/reviews`** — profile strip, filters, sorts, pagination, `/reviews` 301s, admin index.

Increment 2 adds 128,846 rows to the development database. Snapshot first:
`bin/snapshot-dev-db.sh --label pre-reviews`.

## Open risks

- **`after_commit` on `Review`** recalculates one summary row per write. Fine at this volume
  (~16k lifetime writes), but the migration deliberately bypasses it via `insert_all` and relies on
  `backfill_all!` instead.
- **Never resolve spoilers by string substitution.** Two revisions of this spec got it wrong before
  the Task 1 review caught it, and both failures are worth recording. A NUL-byte sentinel silently
  vanishes, because Nokogiri strips NUL bytes while sanitizing. Switching to a random alphanumeric
  token fixes that but opens an injection hole: any marker robust enough to survive sanitizing also
  survives *inside an attribute value*, so the substitution splices raw markup into a quoted string —
  `<a href="<spoiler>evil</spoiler>">click</a>` produced
  `<a href="<span class="review-spoiler">evil</span>">click</a>`, which a browser re-parses into a
  bogus `href` and visible link text of `evil">click`. Allowlisting `spoiler` as a tag and renaming
  the resulting nodes closes the hole at its root, because the parser decides what is an element.
  Regression tests cover the `href` and `title` nesting cases and an event-handler smuggle attempt.
- **Production data** — the legacy production DB is larger than dev (see the descriptions-subsystem
  notes). Row counts here are dev measurements; the production run will differ and should be
  verified against the invariants, not the absolute numbers.
