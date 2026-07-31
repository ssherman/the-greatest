# Descriptions (d) — Public Read Paths — Design

Increment (d) of the descriptions subsystem. Parent spec:
`docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md`.
Sibling: `docs/superpowers/specs/2026-07-29-descriptions-c-write-paths-admin-design.md`.

Increments (a), (b1), (b2) are merged. (c1) and (c2) are on `descriptions-integration` via PRs #183
and #184. This is the last increment before (e) drops the columns.

## Goal

Flip the public games and music views from the `description` column to `primary_description`, so reads
and writes both live in the `descriptions` table and the eleven columns become dead weight.

## Scope

**In:**

- Four entity show views: `games/games/show`, `music/albums/show`, `music/artists/show`,
  `music/songs/show`.
- The per-row blurb in `music/albums/lists/show`, plus the `:descriptions` preload that keeps it from
  becoming an N+1.
- `admin/games/series/_table.html.erb` — the one admin site increment (c2) did not cover.

**Out:**

- **`Descriptions::AttributionComponent`.** Owner's call, 2026-07-30. See D-1.
- **The nine admin show pages.** Already done: (c2) removed their legacy column blocks, and the
  descriptions panel renders there instead. Only the index-table partial above remains.
- **Books public views.** They do not exist. The books public UI is a separate parked initiative
  (`docs/superpowers/specs/2026-07-27-books-public-ui-carryover.md`).
- **Dropping the columns** — increment (e), its own PR, after a–d run in production.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D-1 | The CC BY-SA credit line defers to the books public UI | Measured 2026-07-30: **every** `cc_by_sa_4` row (18,597) and **every** `source_url` (27,569) belongs to `Books::Book` or `Books::Author`. Games and music descriptions are exclusively `ai_generated` (9,117), `igdb` (2,260) and `manual` (5), all with `license: nil` and `source_url: nil` — none carries a CC BY-SA credit obligation. A component keyed on `license == :cc_by_sa_4` + `source_url` would therefore render on zero pages in this increment, could not be verified against real rows, and would likely need reshaping to fit a book page design that does not exist yet. The attribution gap it closes is real but is entirely a **books** gap, and books have no public pages, so (d) cannot close it either way. |
| D-2 | Only `music/albums/lists/show` gets an `includes(:descriptions)` | It renders a blurb per row and paginates at 100, so `primary_description` would fire 100 extra queries. The four entity show pages load a single record — one query either way, so preloading buys nothing. |
| D-3 | The rewire keeps each view's existing presence guard and markup | `primary_description` returns `nil` when nothing qualifies, so `if (description = @album.primary_description)` is a direct swap for `if @album.description.present?`. No layout, class or copy changes — this increment changes where text comes from, not how it looks. |

## The rewire

The four entity views are structurally identical today:

```erb
<% if @album.description.present? %>
  <div class="prose max-w-none">
    <p class="text-base-content/70"><%= @album.description %></p>
  </div>
<% end %>
```

becomes

```erb
<% if (description = @album.primary_description) %>
  <div class="prose max-w-none">
    <p class="text-base-content/70"><%= description.content %></p>
  </div>
<% end %>
```

`primary_description` returns the `preferred` row if one exists, otherwise the first surviving row by
`Descriptions::SourcePriority::ORDER`. In current data that means albums and artists render their
`ai_generated` text and games their `igdb` text — the same strings as today.

`Music::Song` has **0** description rows. Its view is rewired anyway for consistency; it renders
nothing before and after.

## The N+1

`Music::Albums::ListsController#show` already eager-loads:

```ruby
list_items_query = @list.list_items.includes(
  listable: [:artists, :categories, {primary_image: {...}}]
).order(:position)
```

`:descriptions` joins that array. Pagination is 100 per page, so this is the one place where missing
the preload is a measurable regression rather than a rounding error. Pinned by an
`assert_queries_count` test — `DescribableTest` already uses
`ActiveRecord::Assertions::QueryAssertions`, so the helper is established.

## Testing

- Existing controller/integration tests for the five public pages keep passing unchanged; they assert
  status codes rather than copy, per the project convention.
- One test per domain asserting a record with a description still renders it, and one asserting a
  record without one renders no description block — behaviour, not markup.
- A query-count test on `music/albums/lists/show` proving the preload works.
- **No new Playwright.** These are existing pages being rewired, not new user-facing flows. Existing
  E2E over those pages must keep passing.

Gate: `bin/rails test`, `bundle exec standardrb`. Note `test:system` is currently red on `main` for an
unrelated reason — `page.set_rack_session` needs the `rack_session_access` gem, which is absent from
the Gemfile — so it is not a usable gate for this increment.

## Deploy ordering

(d) is what makes the c1/c2/d chain deployable. Until it ships, descriptions written after c1 —
newly imported IGDB games and companies, and every AI regeneration — are stored but not displayed,
because the public views still read the column.

`main` auto-deploys, so this chain lands on `descriptions-integration` and reaches `main` as one
deliberate PR. Before that PR merges, the production backfill must have run:
`data_migration:description_columns` (b1) and `data_migration:descriptions` (b2). Without it the admin
panel is empty and, after (d), public pages lose their descriptions entirely.

Two prerequisites for the b2 half of that production run remain unverified: that production can reach
the `legacy_books` database, and that it has any `Books::Book` rows at all. b1 is independent of both
and can run regardless. If the books data is absent, `BookDescriptionMigrator` fails loud on batch one
with zero rows written and aborts the chain before the safety net runs.
