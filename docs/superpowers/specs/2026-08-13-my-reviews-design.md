# Reviews increment 5 — `/my/reviews`, admin index, and a domain-generic reviewable contract

Date: 2026-08-13
Supersedes the `### /my/reviews` and `### Admin` sections of
`docs/superpowers/specs/2026-08-09-books-reviews-design.md`, which were written before increments
3 and 4 shipped and before reviews were required to generalise beyond books.

## Context

Increments 1–4 shipped and are live: schema and core services, the legacy migration
(141,869 reviews in production), the book-page read surface, and the write flow. The render-time
markup refactor followed and deployed 2026-08-13.

This increment adds the personal ratings library, the admin index, and the two items increment 4
deferred — the rate limit on the write endpoints, and making admin deletion purge the cached page.

**Standing constraint from the owner: reviews will eventually exist for every domain, not just
books. No generic code may be scoped to books.** This is the main architectural driver below and
the reason the increment is larger than a `/my/reviews` page alone.

## Measurements that drove the design

Taken from the development database, which carries the full migrated corpus.

| Measure | Value |
| --- | --- |
| Users with at least one review | 1,399 |
| Total reviews | 128,848 |
| Reviews per user — median | 17 |
| Reviews per user — p90 | 241 |
| Reviews per user — p99 | 1,201 |
| Reviews per user — max | 2,331 |
| Users with more than 25 | 597 |
| Users with exactly 1 | 214 |
| Users with any written review | 364 |
| Written reviews per user — max | 1,540 |

**This is the measurement that inverts increment 3's conclusion.** There, the most-reviewed book
had 37 written reviews, so pagination was cut as unearned. Here the ceiling is 2,331 and p90 is
241, so pagination, filtering and sorting are all genuinely earned — and sorting must happen in
the database, not in Ruby.

## Domain-generic architecture

Two existing precedents, and they differ:

- `UserList` declares a per-domain contract as class methods (`.listable_class`,
  `.ranking_configuration_class`, `.listable_display_includes`) that raise `NotImplementedError`
  on the base and are overridden by each domain's subclass.
- `Search::ListableAutocomplete` keeps one central `CONFIGS` hash keyed by type string, because
  there is no per-domain subclass to hang methods on.

Reviews have **no per-domain subclass** — `Review` is a single global model, polymorphic through
`reviewable`. So the contract is split by what it describes.

### `Reviewable` concern

`app/models/concerns/reviewable.rb`, included by each reviewable model. Today that is
`Books::Book`; later `Music::Album`, `Music::Song`, `Games::Game`.

It provides the associations the reviewable currently declares by hand:

```ruby
has_many :reviews, as: :reviewable, dependent: :destroy
has_one :review_summary, as: :reviewable, dependent: :destroy
```

and the class-level contract the generic review code needs. Base raises `NotImplementedError`
so a new reviewable cannot silently half-implement it:

| Method | Purpose |
| --- | --- |
| `.review_row_includes` | Associations to eager-load per row, so the list stays N+1-free |
| `.review_title_column` | Qualified column for the A–Z sort |
| `.review_text_search(scope, term)` | Applies the title/creator search to a scope |
| `.ranking_configuration_class` | Supplies `default_primary` for the site-rank sort |

All four raise on the base. An implementation of `.ranking_configuration_class` may itself return
`nil`, which is how a reviewable declares it has no site ranking — that is an explicit answer, not
the absence of one, and the site-rank sort is then not offered.

`Books::Book` supplies four short implementations. `review_row_includes` is
`[:primary_image, {book_authors: :author}]`; `review_text_search` matches the book title or any
author name.

Adding a domain later is an `include Reviewable` plus four methods, with no generic file touched.

### Reviewable registry

`Reviews::Registry` maps a domain to its reviewable types, mirroring
`UserList.subclasses_for(domain)`. That mapping is cross-cutting rather than per-model, so it
lives in one place.

The registry also **replaces the hardcoded `REVIEWABLE_TYPES = ["Books::Book"]` allowlists
currently duplicated in `ReviewsController` and `ReviewStateController`.** Those allowlists are
security-relevant — they stop a visitor attaching a review to an arbitrary class — and having
three separate copies means adding a domain silently half-works. One registry, three readers.

## `/my/reviews`

### Controller

`MyReviewsController`, following `MyListsController`: global route (not inside a domain
constraint), `require_signed_in!`, `prevent_caching`, `PathBasedPagination`, `DomainLayout`.

Reviewable types come from `Reviews::Registry` for `Current.domain`. **A domain with no reviewable
types raises `ActiveRecord::RecordNotFound`**, so `/my/reviews` is not a dead page on the music
and games hosts until those domains actually gain reviews.

**The page scopes to exactly one reviewable type at a time.** A domain with several types renders
a type switcher above the results and carries the choice in a query param, defaulting to the
registry's first type for that domain. Books has one type, so the switcher renders nothing today.

This is the part the generic requirement forces. Music will have both albums and songs; sorting by
title or site rank across two tables would need a UNION that pages badly and counts worse. One
type per query keeps every join single-table, permanently.

### Routes

```
get "my/reviews"                 → my_reviews#index
get "my/reviews/page/:page"      → my_reviews#index   (constraints: {page: /\d+/})
get "reviews"                    → 301 /my/reviews
get "reviews/account_required"   → 301 /my/reviews
```

The `get "reviews"` redirect does not conflict with the existing `post "reviews"`.

### `Reviews::MyReviewsQuery`

Owns filtering and sorting, following `Books::LanguageSearchQuery`. It receives the user, the
reviewable class, and the params, and returns a relation.

**Filters**

- rating 1–5 (driven by the bar chart)
- written / rating-only
- free text against title or creator, via `.review_text_search`

**Sorts**

- recently rated (default) — `created_at DESC, id DESC`
- my rating high / low
- the item's site rank
- title A–Z

**All sorting and searching happens in SQL.** `MyListsController#ranking_sorted` loads every item
and sorts in Ruby, which is fine for a list but not for a history whose ceiling is 2,331 rows. The
query joins the reviewable's own table on the polymorphic pair, and left-joins `ranked_items` for
the reviewable's default primary ranking configuration, ordering `rank` with nulls last. Paging
then happens in the database rather than after loading the user's whole history.

The site-rank sort is offered only when `.ranking_configuration_class` returns a class **and** it
has a `default_primary`; otherwise it is absent from the sort list rather than silently degrading.

25 rows per page.

### The page

A **profile strip** on top: the user's average, their rating spread as a bar chart, and counts of
rated versus written, including "N rated without a review" — the number that pulls a user back
into writing. The bars are the rating filter, so the strip earns its space rather than decorating.

Below it, dense rows: cover thumbnail, title, creator, the user's stars, when they rated it, and a
two-line snippet for written reviews. Rating-only rows collapse to a single line with a
"Write a review" action.

**No Turbo Frame.** The approved spec called for one; it is dropped deliberately. Every row links
off-page to the reviewed item, which is precisely the trapped-link shape documented in CLAUDE.md
and guarded by `assert_no_frame_trapped_links` — a frame would need `target: "_top"` plus opting
the filter, sort and paging links back in individually. The page is sign-in-gated and never
cached, so a frame buys no caching or crawler benefit, and the write flow below already accepts a
full reload. Dropping it removes a bug class for no visible loss; re-rendering the strip costs one
grouped query.

### Writing from the page

Rows dispatch the existing `reviews-modal:open` window event. The dialog is already fully generic
— it ships empty and takes `reviewableType`, `reviewableId`, `review` and `csrfToken` off the
event — so no new dialog is needed.

Because this page is never cached, the token in the page's `<meta>` is valid and `/review_state`
is not involved at all; the row carries the review's own values as data attributes.

**On success the page reloads.** `ReviewsController` answers with Turbo Streams aimed at three
book-page element ids (`review_widget`, `review_summary_line`, `review_card`) which do not exist
here, and Turbo no-ops silently on a missing target — so without a reload an edit would close the
dialog and change nothing on screen. A reload also recomputes the row, the bar chart and the
counts server-side, so nothing can drift.

Accepted consequence: editing a review out of the active filter makes its row disappear on reload.
That is the filter being honest.

## Admin

`Admin::ReviewsBaseController` holds all behaviour; `Admin::Books::ReviewsController` supplies the
policy class, paths and preloads — the same split as `Admin::ListsBaseController` and
`Admin::Books::ListsController`. Per-domain subclasses are required regardless of genericity,
because admin auth is domain-scoped through `Admin::DomainScopedAuth`.

`index` and `destroy` only. No approval queue; nothing gates publishing.

The index **defaults to written reviews** — of 128,848 rows only ~16,000 have text, so an
unfiltered index is mostly noise — with a toggle for all. Search by user or by item, sort by
recent. A `DomainNav` entry.

**`destroy` enqueues `Reviews::PurgeCachedPageJob` itself.** This is the standing cost of purging
explicitly from each write path rather than from a model callback, and `ReviewsController` already
carries a comment naming this as the next write path that would need it.

## Rate limit

20 saves per minute per user, on `create`, `update` and `destroy` in `ReviewsController`.

**Backed by Redis**, via `ActiveSupport::Cache::RedisCacheStore` on the `REDIS_URL` Sidekiq
already uses, passed through `rate_limit`'s `store:` option. The default store is unusable here:
production sets no `cache_store`, so it falls back to Rails' file-store default, which is
per-container and wiped on every deploy.

Two traps, both load-bearing:

- **The response must be an empty Turbo Stream with status 429, via `with:`.** Rails' default
  raises `ActionController::TooManyRequests`, which renders an HTML error body on a non-2xx
  status — and a Turbo-submitted form receiving that replaces the whole page with it. This is the
  same failure `ReviewsController` already routes four other exits around
  (`head`, the inherited `require_signed_in!` redirect, `RecordNotFound`, and
  `InvalidAuthenticityToken`); the rate limit is the fifth door.
- **The test environment's cache is `:null_store`.** `rate_limiting` calls `store.increment` and
  acts only `if count && count > to`; a null store returns `nil`, so the limit never fires. A test
  written against the default store passes without ever tripping it. These tests must inject a
  real store.

`by:` is the signed-in user's id. The limit is declared after `require_signed_in!` so the
unauthenticated case is already resolved before it runs.

## Testing

- **`Reviewable` concern** — the contract raises `NotImplementedError` on a class that does not
  implement it; `Books::Book` satisfies all four.
- **`Reviews::Registry`** — domain lookup, unknown domain returns empty, and the three readers
  (`ReviewsController`, `ReviewStateController`, `MyReviewsController`) all resolve through it.
- **`Reviews::MyReviewsQuery`** — every filter and every sort, including nulls-last on site rank
  and the sort being absent when no default primary ranking configuration exists.
- **Controllers, behaviour only** — the 404 on a domain with no reviewable types, the two 301s,
  ownership 403s on admin destroy, admin destroy enqueuing the purge job, and the rate limit
  returning 429 *as a turbo stream* rather than an HTML body.
- **N+1** — `assert_queries_count` pinning the row preloads. A 25-row page rendering a cover and
  creator each is exactly the shape that bites.
- **E2E (Playwright)** — filter by a rating bar, change the sort, page forward, and edit a review
  from the page and see the row change.

## Out of scope

- Review search through OpenSearch. Filtering here is Postgres-only.
- A public profile showing another user's reviews.
- Any second reviewable type. The contract is built so adding one is additive; adding one is not
  part of this increment.
