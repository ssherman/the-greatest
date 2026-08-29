# Category reindex callbacks

**Date:** 2026-08-28
**Status:** Approved, ready for an implementation plan
**Branch:** `worktree-category-reindex-callbacks`

## Problem

`Category` has no callbacks that requeue its items for search indexing.

`CategoryItem` has them — `after_save` and `after_destroy` both create a
`SearchIndexRequest` — so adding or removing a book from a category reindexes that
book correctly. Editing the **category itself** requeues nothing. Change a category's
`category_type`, or call `soft_delete!`, and every item carrying that category keeps
its stale indexed document indefinitely, until something unrelated happens to reindex
it.

Codex flagged this on PR #270 and it was deferred. The Similar Books work in #271/#272
made it load-bearing: `Books::Book#as_indexed_json` now derives four fields from
category state — `genre_category_ids`, `subject_category_ids` and
`location_category_ids` are split by `category_type`, and `similarity_category_count`
is the denominator the similarity query divides by. A retype silently corrupts both
similarity filtering and similarity scoring, and a retype made mid-tuning-pass is
invisible to `bin/rails books:similar:compare`.

## Scope

The hole is wider than books. All six indexed models embed `category_ids` filtered by
`deleted == false`:

| Model | Reads from Category |
|---|---|
| `Books::Book` | `deleted`, `category_type`, `name` (via `BOOK_TYPE_CATEGORY_NAMES`) |
| `Books::Author` | `deleted` |
| `Music::Album` | `deleted` |
| `Music::Artist` | `deleted` |
| `Music::Song` | `deleted` |
| `Games::Game` | `deleted` |

So a `soft_delete!` leaves stale documents in every domain, not just books. This design
covers all of them, with a per-domain list of which fields matter.

### Measurements (dev, 2026-08-28)

Categories by STI type: `Books::Category` 73,969 · `Music::Category` 2,619 ·
`Games::Category` 98.

Largest per domain: Books "Fiction" 68,333 items · Music "United States" 3,658 ·
Games "Single player" 1,533.

`category_items` by item type: `Books::Book` 1,834,555 · `Music::Artist` 26,938 ·
`Music::Album` 14,790 · `Games::Game` 11,319. **`Books::Author` and `Music::Song` have
zero.** No category spans two indexed models in practice, so the item-type filter below
is a safety net rather than a real branch.

Worst-case cost, measured against Fiction inside a rolled-back transaction: plucking
68,333 item ids takes **31ms**; inserting 68,333 `SearchIndexRequest` rows in 1000-row
`insert_all` slices takes **3.2s**.

## Design

### Control flow

```
Category#update!  (admin edit · soft_delete! · Categories::Deleter)
  └─ after_update_commit :queue_items_for_reindexing
       └─ return unless search_relevant_change?
            └─ Categories::ItemReindexer.call(category:)  → Result
                 └─ insert_all SearchIndexRequest rows, 1000 at a time
                      └─ Search::IndexerJob drains them, unchanged
```

No intermediate Sidekiq job. 3.2s is the ceiling for the single worst category in the
app, and since the work runs in `after_update_commit` the category's own transaction is
already closed — it is a slower admin response, not a long-held lock. A job would buy
nothing and would add a commit/enqueue race, a job file and a job test.

`after_update_commit`, not `after_save`, for two reasons: a create has no items yet
(importers call `find_or_create_by!` on categories constantly), and running after commit
keeps the inserts out of the update's transaction.

Only `index_item` is ever queued. Soft-deleting a category does not unindex its books;
it re-renders them without that category.

### What counts as a search-relevant change

An overridable predicate per STI subclass, mirroring exactly what that domain's
`as_indexed_json` reads:

```ruby
# Category — Music::Category and Games::Category inherit this unchanged
def search_relevant_change?
  saved_change_to_deleted?
end

# Books::Category
def search_relevant_change?
  super || saved_change_to_category_type? || book_type_membership_changed?
end
```

`book_type_membership_changed?` is the precise form of "name matters". Name reaches
`as_indexed_json` only through `BOOK_TYPE_CATEGORY_NAMES.include?(c.name)`, so the
predicate compares membership before versus after rather than comparing the string.
Consequence: fixing a typo on a 30,000-item category requeues nothing, while renaming a
category into or out of Fiction/Nonfiction requeues everything it holds.

Requeues nothing: `description`, `slug`, `alternative_names`, `parent_id`,
`import_source`, and the `item_count` counter cache (which uses `update_counters` and
skips callbacks regardless).

The callback body stays two lines; the predicate is the only model-level addition, and
it belongs on the model because it mirrors `as_indexed_json`, which also lives there.

### `Categories::ItemReindexer`

New service at `app/lib/categories/item_reindexer.rb`, beside the existing `merger.rb`,
`deleter.rb` and `updater.rb`. `Category` is a shared global model with no domain, so
this follows local precedent rather than CLAUDE.md's `app/lib/services/<domain>/` path.
Result pattern — the callback ignores the Result; a console or rake caller can read it.

Behaviour:

1. Pluck `category_items` item ids in batches of 1000.
2. Filter `item_type` to the models `Search::IndexerJob` actually drains.
3. `insert_all` the `SearchIndexRequest` rows. Rails 8.1's `insert_all` honours
   `record_timestamps` and populates `created_at`/`updated_at` itself — verified against
   this app's schema, not assumed. That matters because `Search::IndexerJob` orders
   `oldest_first`, so a row with a null `created_at` would sort unpredictably.

`Search::IndexerJob`'s hardcoded `%w[Music::Artist Music::Album Music::Song Games::Game
Books::Book Books::Author]` array becomes a constant on that class, so the service
references one list instead of a second copy that can drift.

**Honours migration suppression.** `app/models/concerns/SearchIndexable` — included by
`Books::Book`, `Books::Author`, `Music::Album`, `Music::Artist`, `Music::Song` and
`Games::Game` — returns early when
`Services::BooksMigration.search_indexing_suppressed?`, a thread-local set by
`Services::BooksMigration.without_search_indexing`. Every books migrator runs inside that
block. `Categories::ItemReindexer` returns an early success Result under the same flag,
for the same reason: a bulk migration must not queue one request per row. Discovered
during planning; not in the original design.

(`CategoryItem`'s own callbacks do *not* check the flag. That is pre-existing and works
only because `CategoryItemMigrator` uses `upsert_all`, which fires no callbacks. Out of
scope here.)

**No dedupe against already-pending requests.** `Search::IndexerJob` already dedupes by
`[parent_type, parent_id, action]` within each batch and deletes every processed row
including duplicates. Duplicates cost only queue rows that drain within the hour, and
the right place to fix that is the consumer, not the producer.

### `Categories::Deleter` fix

`Categories::Deleter#soft_delete` currently writes `update_column(:deleted, true)`,
which fires no callbacks at all — the new callback would be silently bypassed there.
Change it to `update!(deleted: true)`.

The service is orphaned today (tests only, no app callers), but leaving a
callback-bypassing writer next to a callback-dependent fix is how this defect comes
back.

Noted, not fixed: `soft_delete` then calls `category_items.destroy_all`, which fires one
`SearchIndexRequest.create!` per row — 68,333 individual inserts for Fiction, far slower
than the one batched pass, and now redundant with it. Pre-existing behaviour in code
with no app callers.

## Operational behaviour

Retyping Fiction queues 68,333 rows. `Search::IndexerJob` runs every 30s via
sidekiq-cron, taking `.limit(1000)` **per model type** — `process_requests_for_type` is
called once per entry in the model list, each with its own limit. So a books flood
delays `Books::Book` reindexes only; the `Music::*` and `Games::Game` buckets take their
own 1000 rows per pass and are untouched.

Drain time for the worst case is roughly 35 minutes, during which a `Books::Book`
reindex arriving from any other source waits behind the flood, because the scope is
`oldest_first`. Books is pre-launch, so this is accepted and documented rather than
mitigated with priority lanes.

### An interrupted requeue leaves no signal

The insert runs synchronously in `after_update_commit`, outside any transaction, so it
is not atomic with anything. If a deploy restarts the Puma worker partway through, or a
slice raises (the exception propagates out of the commit and 500s the admin request
*after* the category update has already committed), some items are requeued and the rest
stay stale with nothing recording which is which.

Accepted, not fixed. The window is 3.2 seconds at the absolute worst case and under
200ms for anything in a live domain, and recovery is a full reindex
(`bin/rails search:books:recreate_and_reindex_all`). Building a progress ledger, or
moving to a job purely to get retries, would cost more than the failure it prevents.
**If a large category retype ever 500s or coincides with a deploy, re-run the reindex —
the queue will not tell you it was truncated.**

The indexer does **not** use the serial Sidekiq capsule; that capsule is for
external-API jobs. It runs on the default queue at concurrency 5.

## Out of scope

- **Fiction/Nonfiction rename divergence.** `Search::Books::Search::BookSimilar`
  memoizes `name → id` per process, so after a rename the index and the running query
  processes would briefly disagree. Owner's call, 2026-08-28: those two rows never
  change, this is not a real risk. Not guarded, not re-raised.
- Priority lanes or throttling in `Search::IndexerJob`.
- Any backfill reindex. Books was fully reindexed 2026-08-27 after PR #272.

## Testing

Gate is `bin/rails test` plus `bundle exec standardrb`. No brakeman. No E2E — there is
no new user-facing page or flow.

- `test/models/category_test.rb` — flipping `deleted` queues requests; editing
  `description`, `slug` or `parent_id` queues none; creating a category queues none.
- `test/models/books/category_test.rb` — a `category_type` change queues; a rename into
  or out of Fiction/Nonfiction queues; an unrelated rename does not.
- `test/models/music/category_test.rb` — a `category_type` change queues **nothing**.
  This test is what proves the per-domain split is deliberate rather than incidental.
- `test/lib/categories/item_reindexer_test.rb` — batching across the 1000-row boundary,
  the item-type filter, the correct `action`, and the Result shape.
- `test/lib/categories/deleter_test.rb` — extend to assert requests appear after a soft
  delete.
- Suppression: a `deleted` flip inside `Services::BooksMigration.without_search_indexing`
  queues nothing.

For every new test, delete the line under test and confirm the test goes red before
trusting it (`assert_empty` and friends have passed against deleted code in this repo
before).

Sweep during implementation: every existing test that flips a category's `deleted` or
`category_type` now inserts `SearchIndexRequest` rows synchronously. Watch for
`assert_queries_count` assertions and for tests that count rows in that table.
