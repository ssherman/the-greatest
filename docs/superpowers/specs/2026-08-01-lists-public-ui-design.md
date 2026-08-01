# Public Lists UI — Books and Games — Design

**Status:** Design approved by owner 2026-08-01. Spec pending owner review.
**Goal:** Ship `/lists` and `/lists/:id` for books, bring games to parity, and add sorting, search,
and penalty filtering to both.
**Why now:** Books increment 1 (ranked grid, `/book/:slug`, legacy 301s) merged as PR #187, and
path-based pagination became a shared concern in PR #190. `/lists` was increment 2 of the
[books public UI design](2026-07-31-books-public-ui-design.md) and is the next piece.

This supersedes that document's "Increment 2 — lists" section, which assumed a games-style card grid,
no sorting, no search, no pagination on the index, and `Lists::SimplePenaltySummaryComponent` on the
show page. Where the two disagree, this document wins.

## Scope

**In:** `/lists` and `/lists/:id` for books; the same treatment retrofitted onto the existing games
pages; sorting by weight or recency; full-text search over name, source and url; a penalty filter
modal; an `activated_at` column that makes "recently added" mean what users expect; the full weight
and penalty breakdown on both show pages; legacy books 301s; the book detail page's list names
becoming links; Playwright coverage for each increment.

**Out:** music (songs and albums are two ranking configurations against one nav, which is a different
design problem); user-list wiring, which stays increment 3 of the books public UI design; the
list-submission flow (`/lists/help`, `/lists/pending_lists`); the condensed and specialized-edit
views; grid/table view toggles; public user-list viewing.

## Current state (verified 2026-08-01 against dev)

### Books

- `Books::RankingConfiguration.default_primary` is RC **#8 "May 2026"**. 624 `ranked_lists`, **622**
  whose list is `active`. All 624 have `calculated_weight_details` populated (recalculated
  2026-07-23).
- 1,044 `Books::List` total: 759 active, 266 unapproved, 14 approved, 5 rejected.
- Of the 622: 861 of all books lists have a description, 1,030 a url, 1,028 a source.
- 58,691 `list_items` on those lists, **all** `Books::Book`, **zero** pointing at a book unranked in
  RC #8. Item counts min 1, p50 53, p90 121, max 6,933; 113 lists exceed 100 items.
- **34,050 of 58,691 list_items have a NULL position, and 389 of the 622 lists have no positions at
  all.**
- No public list controller, views, or routes exist. `Books::List` is a bare STI subclass.

### Games

- `Games::RankingConfiguration.default_primary` is RC **#4 "2026 Rankings"**. 19 `ranked_lists`, all
  active, all with `calculated_weight_details`.
- 152 `Games::List`: 19 active, 133 unapproved. All 19 have a description, source and url.
- 2,706 `list_items`, min 16 / p50 100 / max 1,002; 6 lists exceed 100 items. 1,002 have a NULL
  position. One row has a NULL `listable_type` — an orphan the view already guards with
  `next unless list_item.item`.
- `Games::ListsController#index` does `.order(weight: :desc).limit(50)` with **no pagination**. It
  works only because there are 19 lists; it truncates silently at 51.
- `Games::ListsController#show` orders `position ASC NULLS LAST` with **no tiebreak**, so the 1,002
  position-less rows have no stable order across requests.
- The games layout has **no `robots` meta tag at all**.

### Penalties

Applied penalties are recorded per `ranked_list` in `calculated_weight_details["penalties"]`, an
array of `{penalty_id, penalty_name, penalty_class, source, value, …}` where `source` is one of
`static`, `dynamic_voter_count`, `dynamic_attribute`.

| | books (622 lists) | games (19 lists) |
|---|---|---|
| Penalty rows | 1,751 | 47 |
| — static | 948 | 16 |
| — dynamic | 803 | 31 |
| Distinct penalties appearing | 38 | 8 |
| Lists with zero penalties | 3 | 1 |
| `penalty_applications` on the RC | 41 | 15 |

`ListPenalty` validates `penalty_must_be_static`, so `list.penalties` is structurally incapable of
returning a dynamic penalty. On books it covers 34 of 38 penalties and 948 of 1,751 rows — **54%**.
The four it cannot see are the most-used penalties on the site:

| Penalty | `dynamic_type` | Books lists | Rank |
|---|---|---|---|
| Voters: Voter Count | `number_of_voters` | 326 | 1st |
| Voters: Unknown Names | `voter_names_unknown` | 202 | 3rd |
| List: only covers 1 specific genre | `category_specific` | 146 | 4th |
| Voters: Unknown Count | `voter_count_unknown` | 129 | 5th |

For static penalties the join and the JSONB agree exactly (948 == 948), and zero `list_penalties` on
these lists reference a penalty unapplied in RC #8.

### There is no historical activation date

Users want to see recently *activated* lists. Neither existing column means that: `created_at` is
when the list was submitted (lists sit pending for months, and curated additions can be over a year
old), and `updated_at` is bumped by any edit. Every alternative source was checked and rejected:

| Source | Finding |
|---|---|
| Legacy `ranked_lists.created_at` | RC 68 spans 4 days (2026-05-16 → 06-07). Records the RC rebuild, not the addition. |
| Legacy `changesets` | 448 rows, all `changeable_type = "Book"`. Nothing for lists. |
| Legacy PaperTrail `versions` | 847 List versions, but they begin 2025-06-28 — the same window `updated_at` already covers, plus a cross-database dependency. |

Books `updated_at` on the 622 active lists spans 2025-06-09 → 2026-07-03 across only **45 distinct
days**, with 469 of 622 sharing 2025 timestamps from a bulk touch. `created_at` spans 2014 → 2026
across 272 days. So `updated_at` is the best available *approximation* of activation, and nothing
better exists retroactively.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Sort and search ride as **query params**; canonical is `/lists` | `PathBuilder` already carries query params through path-based pagination, so this is zero new plumbing. Legacy `/lists/sorted-by/*` 301s in. |
| D2 | Show page orders `position ASC NULLS LAST, list_items.id ASC`; the card badge shows the book's **overall rank in the RC** | Legacy parity, including for the 389 position-less lists. Legacy renders "The 42nd Greatest Book of All Time" on list pages, not a per-list position. |
| D3 | The index is the **2-column card grid games already uses**, 50 per page, extracted into a shared component | Games' design works and is already built. Accepted tradeoff: descriptions clamp to two lines, so the 861 books lists with a description show a preview rather than the full text on the index — the full description is on the show page. |
| D4 | The show page renders the **full weight arithmetic** — base, each penalty, quality bonus, final weight | All of it reads from `calculated_weight_details`, so it costs zero extra queries, and it answers "why is this list weighted this way" directly. |
| D5 | Add `lists.activated_at`, stamped on transition into `active`, backfilled from `updated_at` | Accurate from now on and immune to later edits. The backfill is exactly what sorting on `updated_at` would give today, so nothing regresses. |
| D6 | Games gets **full parity**, and its card design becomes the shared one both domains use | Games' index already looks right; the work there is the missing functionality, not a redesign. One set of shared components serves both. |
| D7 | The penalty filter queries the **JSONB**, not `list_penalties` | Covers static and dynamic uniformly, is RC-scoped for free because it lives on `ranked_lists`, and can never disagree with the breakdown rendered beside it. The join would silently omit the four most-used penalties. |
| D8 | Multi-select penalties are **OR** | Standard convention for multi-select within one facet. Adding a penalty broadens rather than collapsing to zero. |
| D9 | `show` serves only `active` lists; everything else 404s | 266 unapproved and 5 rejected books rows are user submissions, not content. Legacy leaked them. |
| D10 | Search and penalty filtering set `noindex` and bypass the edge cache | Otherwise every query string mints its own six-hour Cloudflare entry, and near-duplicate filtered views compete with `/lists`. |

## Increments

| # | Contents |
|---|---|
| 1 | Shared foundation — `activated_at` + backfill, `List.search_text`, `Lists::WeightBreakdownComponent`, `Lists::CardComponent`, `games_robots_content` |
| 2 | Books `/lists` and `/lists/:id`, legacy 301s, book-page list links, nav entry |
| 3 | Games `/lists` and `/lists/:id` conversion |
| 4 | Penalty filter modal on both domains |

Playwright specs are written inside each increment.

---

## Increment 1 — shared foundation

### `lists.activated_at`

```ruby
add_column :lists, :activated_at, :datetime
add_index  :lists, :activated_at
execute "UPDATE lists SET activated_at = updated_at WHERE status = 3"
```

On `List`:

```ruby
before_save :stamp_activated_at, if: -> { status_changed? && active? }

def stamp_activated_at
  self.activated_at = Time.current
end
```

Restamps on every transition *into* active, so a list deactivated and re-activated reads as newly
added. All four domains inherit the column and callback; only books and games surface it.

`status = 3` is the `active` enum value. The backfill runs inside the migration, not a `rails runner`
one-off — the destructive-DB hook inspects Bash commands and `db:migrate` is not blocked, but
snapshot first with `bin/snapshot-dev-db.sh --label pre-activated-at` regardless.

### `List.search_text`

```ruby
scope :search_text, ->(query) {
  return all if query.blank?
  sanitized = "%" + sanitize_sql_like(query.to_s.strip) + "%"
  where("name ILIKE :q OR source ILIKE :q OR url ILIKE :q", q: sanitized)
}
```

Legacy's three fields. A **new** scope rather than widening `search_by_name`, which
`Admin::ListsBaseController#apply_search_filter` uses — admin search semantics should not change as a
side effect of a public feature. 1,044 books lists and 152 games lists make `ILIKE` free; there is no
`List` OpenSearch index in this app and this does not need one.

### `Lists::WeightBreakdownComponent`

`initialize(ranked_list:)`. Reads `calculated_weight_details` and renders:

```
How good is this list?

      Weight  62%

Base weight                       100%

What lowers this list's weight:
  Voters: not critics or experts   −60%
  List: only covers 1 language     −20%
  Voters: Unknown Names             −5%
                                  ──────
  Total penalty                    −85%
  High quality source bonus        +33%

Final weight                       62%
```

Values come from `base_values.base_weight`, the `penalties` array (`penalty_name`, `value`),
`quality_bonus` (rendered only when `applied` is true, using `penalty_before - penalty_after`), and
`final_calculation.final_weight`. Weight is always rendered as a percentage.

Renders "Weight calculation details not available" when the JSONB is absent, and "This list is not
used for any active rankings" when there is no `ranked_list` at all.

`Lists::SimplePenaltySummaryComponent` is **not** deleted. Games drops it in increment 3, but
`music/songs/lists/show` and `music/albums/lists/show` still render it and music is out of scope.
Its test stays green.

### `Lists::CardComponent`

The games list card, extracted from `games/lists/index.html.erb` into a shared component and used by
both domains. `initialize(ranked_list:, item_count:, path:, noun:)` where `noun` is `"books"` or
`"games"`.

```
┌────────────────────────────────┐
│ Weight 100%          103 books │
│                                │
│ The Top 10: The Greatest       │
│ Books of All Time              │
│                                │
│ The Top 10 (Book) · 2007       │
│                                │
│ J. Peder Zane asked 125        │
│ writers to name their…         │
│                                │
│ added 2 years ago              │
└────────────────────────────────┘
```

Grid stays games' `grid grid-cols-1 md:grid-cols-2 gap-4`. Two changes from the current games markup:

- **"added X ago" from `activated_at`** in the card footer. Without it the `newest` sort orders on a
  value the user cannot see.
- **Stretched-link instead of a whole-card `link_to`.** Games wraps the entire card in an anchor, so
  the link's accessible name becomes every word in the card — weight, count, name, source and the
  whole description read as one link. The title carries the link and `after:absolute after:inset-0`
  makes the card clickable, which is what `Books::CardComponent` already does.

Descriptions are **escaped**, not `simple_format(sanitize: false)`. Books list descriptions are
curator-authored rather than OpenLibrary-sourced, but increment 1 shipped a stored-XSS finding on
exactly this pattern and there is no reason to reintroduce it.

### `games_robots_content`

Mirrors `books_robots_content` minus the `Books::PublicIndexing` kill switch — games is live and
should stay indexed:

```ruby
def games_robots_content
  return "noindex, follow" if params[:ranking_configuration_id].present?
  @indexable == false ? "noindex, follow" : "index, follow"
end
```

Added to the games layout `<head>`. Defaulting to indexable preserves today's behavior on every
games page that does not set `@indexable`.

---

## Increment 2 — books `/lists`

### Routes

Inside the existing books `DomainConstraint` block:

```ruby
get "lists",                to: "books/lists#index", as: :books_lists
get "lists/page/:page",     to: "books/lists#index", as: :books_lists_page, constraints: {page: /\d+/}
get "lists/:id",            to: "books/lists#show",  as: :books_list, constraints: {id: /\d+/}
get "lists/:id/page/:page", to: "books/lists#show",  as: :books_list_page, constraints: {id: /\d+/, page: /\d+/}
```

plus four `rc/:ranking_configuration_id/lists…` equivalents, always `noindex` per books-public-UI D4.
Books declares its RC routes explicitly (`books_rc`, `books_rc_page`) rather than wrapping them in a
`scope "(/rc/…)"` — the one `scope` block that does exist there is the legacy `/books/:id` 301
namespace, which these must not join.

List ids were preserved by the migration, so `/lists/:id` and `/lists/page/:n` are byte-identical to
the legacy shapes and need no redirect. The `\d+` constraint on `:id` is what keeps
`/lists/condensed` from being parsed as a list id.

**301s** for legacy variants this work does not implement:

| Legacy | → |
|---|---|
| `/lists/sorted-by/weight(/page/:n)` | `/lists` |
| `/lists/sorted-by/created_at(/page/:n)` | `/lists?sort=newest` |
| `/lists/search_results` | `/lists` |
| `/lists/condensed`, `/lists/help`, `/lists/pending_lists`, `/lists/specialized_edit` | `/lists` |
| `/v/:view_type/lists/…` | the same path without the `/v/:view_type` prefix |

`Books::List` does **not** use friendly_id, so `.find(params[:id])` is safe here. The numeric-slug
footgun documented in the books public UI design is a `Books::Book` problem only.

### `Books::ListsQuery`

One object, following `Books::RankedBooksQuery`:

```ruby
Books::ListsQuery.call(ranking_configuration:, sort: "weight", query: nil, penalty_ids: [])
```

- Base: `ranked_lists` joined to `lists` where `lists.type = "Books::List"` and `lists.status = :active`,
  `includes(:list)`.
- Sort whitelist `%w[weight newest]`, anything else falls back to `weight`.
  `weight` → `ORDER BY ranked_lists.weight DESC`.
  `newest` → `ORDER BY lists.activated_at DESC NULLS LAST`.
- Search: `where(list_id: List.search_text(query).select(:id))` when present.
- Penalties: see increment 4.

Both orderings take `lists.id ASC` as a tiebreak so pagination is stable — 273 books lists share a
weight in the 0–10 bucket alone, and without a tiebreak the same list can appear on two pages.

Paginated at **50** via `pagy_path`, which already bounds-checks past the last page.

**Item counts** come from one grouped query over the 50 lists on the page:

```ruby
ListItem.where(list_id: page_list_ids).group(:list_id).count
```

Not `includes(list: :list_items)` — that is what games does today, and on books it would load all
58,691 `list_items` into memory to call `.size`.

### `Books::ListsController`

```ruby
class Books::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :load_ranking_configuration
  before_action :apply_caching
end
```

`apply_caching` calls `prevent_caching` when a search or penalty filter is active and
`cache_for_index_page` / `cache_for_show_page` otherwise. `@indexable` is set false under the same
condition, which `books_robots_content` already consumes.

`show` loads `Books::List.where(status: :active).find_by!(id: params[:id])`, so non-active lists 404.
`@ranked_list` is `@ranking_configuration.ranked_lists.find_by(list: @list)` and may be nil for the
137 active lists outside RC #8 — those render with the "not used for any active rankings" branch and
`@indexable = false`.

List items paginate at **100**:

```ruby
@list.list_items
     .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
     .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC"))
```

`{file_attachment: :blob}` is **not optional**. Omitting it is precisely the N+1 that shipped in
increment 1 — 200 extra queries per grid page.

Ranks come from one lookup over the page's book ids:

```ruby
@ranks = RankedItem.where(ranking_configuration: @ranking_configuration,
                          item_type: "Books::Book", item_id: page_book_ids)
                   .pluck(:item_id, :rank).to_h
```

### Views and components

`Books::CardComponent` changes from `initialize(ranked_item:, index:)` to
`initialize(book:, rank:, index:)`. The ranked index passes `ranked_item.item` and
`ranked_item.rank`; the list show page passes the book and its rank from `@ranks`. `rank` is nullable
and the badge is omitted when nil — today that is zero books, but the component should not depend on
that holding.

`index.html.erb` opens at `<div class="space-y-8">` with no second container (books-public-UI B7),
renders the search form, the two sort links, the `Lists::CardComponent` grid, and `series_nav`.
`show.html.erb` renders the list header, `Lists::WeightBreakdownComponent`, then the same
`grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6` ladder
as the ranked index, with `series_nav` above and below.

Pagination is **full-page navigation**, not a Turbo Frame. The games show page frames it, which is
why its URL never advances; sidestepping the frame sidesteps the bug.

The book detail page's "Appears on these lists" list items become links to `books_list_path`, and
both the desktop and mobile nav in the books layout gain a Lists entry.

---

## Increment 3 — games `/lists`

One new route, inside the existing `scope "(/rc/:ranking_configuration_id)"`:

```ruby
get "lists/page/:page", to: "games/lists#index", as: :games_lists_page, constraints: {page: /\d+/}
```

`/lists`, `/lists/:id`, `/lists/:id/page/:n` and every `/rc/…` variant already exist. `:id` gains a
`/\d+/` constraint for symmetry. Games has no legacy URLs, so no redirects.

`Games::ListsQuery` mirrors `Books::ListsQuery` with `lists.type = "Games::List"` and
`Games::Game`. `Games::ListsController` gains `PathBasedPagination`, `pagy_path` at 50 on the index
in place of `.limit(50)`, the sort and search params, `apply_caching`, and `@indexable`.

`index` swaps its inline card markup for the shared `Lists::CardComponent` extracted in increment 1 —
visually the same design, now with the "added X ago" footer and the stretched-link fix — and gains
the search form, sort links and pager above it. Item counts move to the grouped
`ListItem.where(list_id: …).group(:list_id).count` query, replacing `includes(list: :list_items)` and
`list.list_items.size`.

`show` keeps `Games::CardComponent` and its existing grid but gains the `list_items.id ASC` tiebreak,
swaps `Lists::SimplePenaltySummaryComponent` for `Lists::WeightBreakdownComponent`, and drops the
Turbo Frame in favour of full-page pagination. Both views lose their inner
`<div class="container mx-auto px-4 py-8">`, which double-pads against the layout's own container.

Sorting by `newest` is near-meaningless for games today — `created_at` spans 2 days and `updated_at`
7 — but `activated_at` makes it correct from the next activation onward.

---

## Increment 4 — penalty filter

A button beside the search box opens a DaisyUI `<dialog>` listing every penalty that appears on any
list in the current RC, grouped by the `List:` / `Voters:` prefix in the penalty name, each with a
facet count. Checkboxes submit as `penalties[]` on a plain GET form. `showModal()` is the only
JavaScript, matching how the login modal already works in these layouts — no Stimulus controller.

Selected penalties also render as removable chips above the results, so the active filter is visible
without reopening the modal.

### Query

OR across the selected ids:

```ruby
clauses = ids.map { "ranked_lists.calculated_weight_details -> 'penalties' @> ?" }
relation.where(clauses.join(" OR "), *ids.map { |id| [{penalty_id: id}].to_json })
```

Ids are cast through `Integer()` and silently discarded if unparseable, so nothing user-supplied
reaches the JSON literal. Verified against dev: penalty 14 alone returns 130 rows; 14 and 12 together
under AND containment return 129 — the operator behaves as documented.

### Facet counts

One query, computed against the **unfiltered** set so users can see what else is available:

```sql
SELECT e->>'penalty_id' AS penalty_id, COUNT(*)
  FROM ranked_lists rl
  JOIN lists l ON l.id = rl.list_id
  CROSS JOIN LATERAL jsonb_array_elements(rl.calculated_weight_details->'penalties') e
 WHERE rl.ranking_configuration_id = :rc AND l.status = 3 AND l.type = :type
 GROUP BY 1
```

Names join from `Penalty.where(id: ids)`. A GIN index on
`ranked_lists (calculated_weight_details jsonb_path_ops)` is cheap insurance; at 622 and 19 rows the
planner will seq-scan either way.

### Known limitation

`calculated_weight_details` is a snapshot from the last weight calculation. Changing a list's
penalties without recalculating leaves the filter and the displayed breakdown stale **together** —
consistent, which is the reason to filter from it rather than from `list_penalties`.

---

## Testing

| Layer | Coverage |
|---|---|
| Model | `activated_at` stamps on transition into active, restamps on re-activation, leaves non-active rows untouched; `search_text` matches name, source and url and escapes `%` and `_` |
| Query objects | sort whitelist rejects junk, search, penalty OR filter, facet counts, active-only, type-scoped, stable tiebreak |
| Controllers | status codes and params only — 404 for a non-active list, 404 past the last page, `@indexable` false under search or filter, no-store headers when filtered |
| Components | breakdown with and without `calculated_weight_details`, with and without the quality bonus, with no `ranked_list`; card with and without description, url, year, `activated_at`, and for both `noun` values |
| Query counts | `assert_queries_count` pins on both indexes and both show pages |
| E2E | books lists index (sort, search, paginate, click through), books list show (grid, paginate, breakdown), the games equivalents, the penalty modal round-trip |

Each `assert_queries_count` block **must render a cover image**. Increment 1's pin passed while
missing 200 image queries because its block never touched the association.

Controller tests assert behavior, never HTML or copy.

## Landmines

1. **`{file_attachment: :blob}`** on every `primary_image` preload, and a query-count pin that
   actually renders the image. This exact N+1 shipped once already.
2. **Escape list descriptions.** `simple_format(…, sanitize: false)` was a stored-XSS finding in
   increment 1.
3. **`\d+` constraint on `/lists/:id`** before the legacy 301 paths, or `/lists/condensed` parses as
   a list id.
4. **`lists.id ASC` tiebreak** on both index sorts. 273 books lists share the 0–10 weight bucket;
   without it a list can appear on two pages and vanish from a third.
5. **`list_items.id ASC` tiebreak** on both show pages. 389 books lists and 1,002 games list_items
   have no position at all.
6. **`prevent_caching` under search and filter**, or Cloudflare stores a six-hour entry per query
   string.
7. **Do not use `prose`** — `@tailwindcss/typography` is not installed; the class is a no-op.
8. **`Books::List` has no friendly_id**, so `.find` is safe here. Do not copy that habit back to
   `Books::Book`, where 124 numeric slugs collide with real ids.
9. **Snapshot the dev DB** before running the `activated_at` migration. Books data exists only in
   development.
